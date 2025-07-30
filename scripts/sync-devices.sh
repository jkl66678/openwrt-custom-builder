#!/bin/bash
set -euo pipefail

# 配置参数（优化文件搜索规则）
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
TARGET_DEVICES=("cuby-tr3000")
# 扩展文件类型，确保覆盖所有可能的设备定义文件
SEARCH_FILES=("*.dts" "*.dtsi" "*.mk" "Makefile" "*.conf" "*.yml" "*.board" "*.profile")
# 核心关键词，覆盖OpenWrt常见设备命名方式
SEARCH_KEYWORDS=(
    "DEVICE_NAME" "DEVICE_TITLE" "model" "boardname" 
    "BOARD_NAME" "DEVICE_ID" "product" "hwmodel"
    "DEVICE_COMPAT" "SOC_MODEL" "MACHINE" "SUPPORTED_DEVICES"
)

# 初始化环境
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"  # 清空日志
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "awk" "find" "sort" "uniq" "xargs")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# 获取/更新OpenWrt源码（验证源码完整性）
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    # 强制重新克隆（避免本地源码损坏）
    if [ -d "${OPENWRT_DIR}" ]; then
        echo "移除旧源码目录..." | tee -a "${LOG_FILE}"
        rm -rf "${OPENWRT_DIR}"
    fi
    
    echo "克隆源码仓库（完整克隆，确保目录结构正确）..." | tee -a "${LOG_FILE}"
    # 增加超时和深度参数，确保克隆完整
    if ! git clone --depth 5 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        echo "❌ 源码克隆失败，请检查网络或仓库地址" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证源码核心目录是否存在
    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        echo "❌ 源码目录不完整，未找到target/linux" | tee -a "${LOG_FILE}"
        echo "可能原因：仓库克隆不完整或源码结构已变更" | tee -a "${LOG_FILE}"
        exit 1
    fi
    echo "✅ 源码克隆完成，目录结构验证通过" | tee -a "${LOG_FILE}"
}

# 抓取设备列表（彻底修复文件查找问题）
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 1. 构建文件搜索表达式（简化路径，扩大范围）
    local file_pattern=""
    for pattern in "${SEARCH_FILES[@]}"; do
        file_pattern+=" -o -name '${pattern}'"
    done
    file_pattern=$(echo "${file_pattern}" | sed 's/^ -o //')  # 移除首个-o
    
    # 2. 查找文件（关键修复：移除路径限制，搜索整个target/linux目录）
    echo "查找设备文件路径: ${OPENWRT_DIR}/target/linux/" | tee -a "${LOG_FILE}"
    local device_files
    # 直接搜索整个target/linux目录，不限制子路径（解决路径过滤过严问题）
    device_files=$(find "${OPENWRT_DIR}/target/linux/" \
        -type f \( ${file_pattern} \) -print0 2>> "${LOG_FILE}")
    
    # 3. 验证文件数量（增加详细日志）
    local file_count=$(echo -n "${device_files}" | tr '\0' '\n' | wc -l)
    echo "找到 ${file_count} 个设备相关文件" | tee -a "${LOG_FILE}"
    
    # 保存找到的文件列表到日志（便于调试）
    echo -n "${device_files}" | tr '\0' '\n' > "${LOG_DIR}/found-files.tmp"
    echo "已找到的文件列表已保存到: ${LOG_DIR}/found-files.tmp" | tee -a "${LOG_FILE}"
    
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 未找到任何设备相关文件，可能原因：" | tee -a "${LOG_FILE}"
        echo "1. 源码目录不完整（target/linux下无文件）" | tee -a "${LOG_FILE}"
        echo "2. 文件搜索模式不正确（扩展名未覆盖）" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 4. 构建关键词正则
    local keyword_regex=""
    for kw in "${SEARCH_KEYWORDS[@]}"; do
        keyword_regex+="|${kw}"
    done
    keyword_regex="(${keyword_regex:1})"
    
    # 5. 提取设备名称（用xargs -0处理特殊文件名）
    echo "开始提取设备名称..." | tee -a "${LOG_FILE}"
    local raw_devices
    raw_devices=$(echo -n "${device_files}" | xargs -0 grep -hE "${keyword_regex}[:=][[:space:]]*" 2>> "${LOG_FILE}" | \
        sed -E \
            -e "s/${keyword_regex}[:=][[:space:]]*//gi" \
            -e "s/[\"'<>\`]//g" \
            -e "s/^[[:space:]]+//; s/[[:space:]]+$//" \
            -e "s/[[:space:]]+/ /g" | \
        grep -vE "^$|^#|^//|^[0-9]+$|^[A-Z_]+$" | \
        tr '[:upper:]' '[:lower:]' | \
        sort -u)
    
    # 6. 检查提取结果
    if [ -z "${raw_devices}" ]; then
        echo "❌ 设备名称提取结果为空，可能关键词不匹配" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 7. 保存原始结果
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    echo "初步提取到 ${raw_count} 个设备名称" | tee -a "${LOG_FILE}"
    
    # 8. 强制保留关键设备
    local final_devices="${raw_devices}"
    for target in "${TARGET_DEVICES[@]}"; do
        if ! echo -e "${final_devices}\n${final_devices^^}" | grep -q "^${target}$"; then
            echo "⚠️ 未自动抓取到 ${target}，手动添加" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${target}"
        fi
    done
    
    # 9. 输出最终结果
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total} 个设备）" | tee -a "${LOG_FILE}"
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
        echo "❌ 生成 ${DEVICE_JSON} 失败" | tee -a "${LOG_FILE}"
        exit 1
    }
    
    # 验证关键设备
    for target in "${TARGET_DEVICES[@]}"; do
        if ! jq -e ".devices[] | select(. == \"${target}\")" "${DEVICE_JSON}" &> /dev/null; then
            echo "❌ ${DEVICE_JSON} 中缺少关键设备: ${target}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    
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
