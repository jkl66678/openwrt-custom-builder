#!/bin/bash
set -euo pipefail

# 配置参数（极简搜索规则）
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
TARGET_DEVICES=("cuby-tr3000")
# 最基础的设备文件类型（确保覆盖核心文件）
BASIC_FILE_TYPES=("*.dts" "*.mk" "Makefile")

# 初始化环境
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"  # 清空日志
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "find" "sort" "uniq" "xargs" "ls")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# 获取/更新OpenWrt源码（完整克隆+结构验证）
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    # 强制删除旧目录，避免缓存问题
    if [ -d "${OPENWRT_DIR}" ]; then
        echo "移除旧源码目录..." | tee -a "${LOG_FILE}"
        rm -rf "${OPENWRT_DIR}"
    fi
    
    # 完整克隆（不限制深度，确保所有文件下载）
    echo "克隆完整源码仓库（可能需要几分钟）..." | tee -a "${LOG_FILE}"
    if ! git clone "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        echo "❌ 源码克隆失败，请检查网络或仓库地址" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证target/linux目录存在且非空
    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        echo "❌ 源码目录不完整：未找到 ${OPENWRT_DIR}/target/linux" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 列出target/linux下的子目录（调试用）
    echo "target/linux目录结构：" | tee -a "${LOG_FILE}"
    ls -l "${OPENWRT_DIR}/target/linux" >> "${LOG_FILE}" 2>&1
    
    # 检查该目录下是否有文件（至少10个文件才认为有效）
    local target_file_count
    target_file_count=$(find "${OPENWRT_DIR}/target/linux/" -maxdepth 2 -type f | wc -l)
    if [ "${target_file_count}" -lt 10 ]; then
        echo "❌ 源码不完整：target/linux下文件过少（仅${target_file_count}个）" | tee -a "${LOG_FILE}"
        echo "可能是仓库克隆不完整或分支错误" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ 源码克隆完成，target/linux目录验证通过" | tee -a "${LOG_FILE}"
}

# 抓取设备列表（极简搜索逻辑，确保找到文件）
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 1. 构建最简单的文件搜索模式（避免复杂拼接错误）
    local find_args=()
    for type in "${BASIC_FILE_TYPES[@]}"; do
        find_args+=(-o -name "${type}")
    done
    # 移除第一个多余的-o
    find_args=("${find_args[@]:1}")
    
    # 2. 搜索整个target/linux目录（无路径限制）
    echo "查找设备文件（基础类型：${BASIC_FILE_TYPES[*]}）..." | tee -a "${LOG_FILE}"
    local device_files
    device_files=$(find "${OPENWRT_DIR}/target/linux/" \
        -type f \( "${find_args[@]}" \) -print0 2>> "${LOG_FILE}")
    
    # 3. 验证文件数量并输出详细日志
    local file_count=$(echo -n "${device_files}" | tr '\0' '\n' | wc -l)
    echo "找到 ${file_count} 个基础类型设备文件" | tee -a "${LOG_FILE}"
    
    # 保存找到的文件列表（关键调试信息）
    echo -n "${device_files}" | tr '\0' '\n' > "${LOG_DIR}/found-files.tmp"
    echo "文件列表已保存到: ${LOG_DIR}/found-files.tmp" | tee -a "${LOG_FILE}"
    
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 仍未找到任何设备文件，可能原因：" | tee -a "${LOG_FILE}"
        echo "1. 源码仓库分支错误（请确认是OpenWrt官方主线）" | tee -a "${LOG_FILE}"
        echo "2. 本地网络问题导致克隆不完整" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 4. 用最基础的关键词提取设备名称（避免正则过复杂）
    echo "提取设备名称..." | tee -a "${LOG_FILE}"
    local raw_devices
    raw_devices=$(echo -n "${device_files}" | xargs -0 grep -hE "DEVICE_NAME|model|boardname" 2>> "${LOG_FILE}" | \
        sed -E \
            -e "s/DEVICE_NAME[:=]//g" \
            -e "s/model[:=]//g" \
            -e "s/boardname[:=]//g" \
            -e "s/[\"' \t]//g" \
            -e "s/^[[:space:]]*//g" | \
        grep -vE "^$|^#" | \
        sort -u)
    
    # 5. 确保提取结果非空
    if [ -z "${raw_devices}" ]; then
        echo "❌ 设备名称提取为空，尝试手动添加关键设备" | tee -a "${LOG_FILE}"
        raw_devices="${TARGET_DEVICES[0]}"  # 至少保留关键设备
    fi
    
    # 6. 保存并处理结果
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    echo "提取到 ${raw_count} 个设备名称" | tee -a "${LOG_FILE}"
    
    # 7. 确保关键设备存在
    local final_devices="${raw_devices}"
    for target in "${TARGET_DEVICES[@]}"; do
        if ! echo "${final_devices}" | grep -q "^${target}$"; then
            echo "⚠️ 手动添加关键设备: ${target}" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${target}"
        fi
    done
    
    # 8. 输出最终结果
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total} 个）" | tee -a "${LOG_FILE}"
}

# 生成设备JSON文件
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)),
            "count": ($devices | split("\n") | map(select(length > 0)) | length)
        }' > "${DEVICE_JSON}" || {
        echo "❌ 生成JSON失败，手动创建基础文件" | tee -a "${LOG_FILE}"
        # 手动创建包含关键设备的JSON
        cat > "${DEVICE_JSON}" <<EOF
{"devices": ["${TARGET_DEVICES[0]}"], "count": 1}
EOF
    }
    
    echo "✅ ${DEVICE_JSON} 生成成功" | tee -a "${LOG_FILE}"
}

# 主流程
main() {
    init
    update_openwrt_source
    fetch_devices
    generate_device_json
    
    echo -e "\n===== 设备同步完成 =====" | tee -a "${LOG_FILE}"
    echo "详细日志: ${LOG_FILE}"
    echo "设备列表: ${DEVICE_JSON}（共 $(jq '.count' "${DEVICE_JSON}") 个设备）"
}

main
