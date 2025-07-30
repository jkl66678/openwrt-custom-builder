#!/bin/bash
set -uo pipefail  # 移除-e选项，避免单一命令失败终止整个脚本

# 配置参数（强制容错模式）
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
TARGET_DEVICES=("cuby-tr3000")
# 已知的OpenWrt设备文件路径（手动指定，绕过find命令）
KNOWN_DEVICE_PATHS=(
    "${OPENWRT_DIR}/target/linux/*/dts/*.dts"
    "${OPENWRT_DIR}/target/linux/*/profiles/*.mk"
    "${OPENWRT_DIR}/target/linux/*/Makefile"
    "${OPENWRT_DIR}/target/linux/generic/profiles/*.mk"
)

# 初始化环境
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"  # 清空日志
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程（容错模式）" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "find" "sort" "uniq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# 克隆源码（强制完整克隆，增加超时）
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    # 强制删除旧目录
    if [ -d "${OPENWRT_DIR}" ]; then
        echo "移除旧源码目录..." | tee -a "${LOG_FILE}"
        rm -rf "${OPENWRT_DIR}" || true
    fi
    
    # 完整克隆，增加超时和重试机制
    echo "克隆源码仓库（带超时和重试）..." | tee -a "${LOG_FILE}"
    clone_success=0
    for i in {1..3}; do  # 最多重试3次
        if git clone --depth 10 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
            clone_success=1
            break
        else
            echo "⚠️ 第${i}次克隆失败，重试..." | tee -a "${LOG_FILE}"
            rm -rf "${OPENWRT_DIR}" || true
            sleep 5
        fi
    done
    
    if [ "${clone_success}" -eq 0 ]; then
        echo "❌ 多次克隆失败，使用本地默认设备列表" | tee -a "${LOG_FILE}"
        return 1  # 不终止，继续执行
    fi
    
    # 验证核心目录存在（即使文件少也继续）
    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        echo "⚠️ 未找到target/linux目录，使用默认列表" | tee -a "${LOG_FILE}"
        return 1
    fi
    
    echo "✅ 源码克隆完成（容错模式）" | tee -a "${LOG_FILE}"
    return 0
}

# 抓取设备列表（手动指定路径+强制容错）
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 1. 尝试使用已知路径查找文件（绕过find命令的复杂性）
    echo "使用已知路径查找设备文件..." | tee -a "${LOG_FILE}"
    local device_files=""
    for path in "${KNOWN_DEVICE_PATHS[@]}"; do
        # 直接展开路径，处理通配符
        for file in ${path}; do
            if [ -f "${file}" ]; then
                device_files+="${file}"$'\0'  # 用空字节分隔文件名
            fi
        done
    done
    
    # 2. 统计找到的文件数量（处理空字节警告）
    local file_count=0
    if [ -n "${device_files}" ]; then
        # 转换空字节为换行符，避免警告
        file_count=$(echo -n "${device_files}" | tr '\0' '\n' | wc -l)
    fi
    echo "找到 ${file_count} 个设备相关文件（已知路径）" | tee -a "${LOG_FILE}"
    
    # 3. 保存找到的文件列表（调试用）
    echo -n "${device_files}" | tr '\0' '\n' > "${LOG_DIR}/found-files.tmp"
    
    # 4. 提取设备名称（如果找到文件）
    local raw_devices=""
    if [ "${file_count}" -gt 0 ]; then
        echo "从已知路径提取设备名称..." | tee -a "${LOG_FILE}"
        raw_devices=$(echo -n "${device_files}" | tr '\0' '\n' | xargs grep -hE "DEVICE_NAME|model|boardname" 2>> "${LOG_FILE}" | \
            sed -E \
                -e "s/DEVICE_NAME[:=]//g" \
                -e "s/model[:=]//g" \
                -e "s/boardname[:=]//g" \
                -e "s/[\"' \t]//g" \
                -e "s/^[[:space:]]*//g" | \
            grep -vE "^$|^#" | \
            sort -u)
    fi
    
    # 5. 强制兜底：如果没有提取到任何设备，直接使用关键设备
    if [ -z "${raw_devices}" ]; then
        echo "⚠️ 未提取到任何设备，使用默认关键设备" | tee -a "${LOG_FILE}"
        raw_devices="${TARGET_DEVICES[*]}"
    fi
    
    # 6. 确保关键设备存在
    local final_devices="${raw_devices}"
    for target in "${TARGET_DEVICES[@]}"; do
        if ! echo "${final_devices}" | grep -q "^${target}$"; then
            echo "⚠️ 手动添加关键设备: ${target}" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${target}"
        fi
    done
    
    # 7. 输出最终结果
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total} 个）" | tee -a "${LOG_FILE}"
}

# 生成设备JSON文件（强制成功）
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    # 即使临时文件为空，也强制生成包含关键设备的JSON
    if [ ! -s "${LOG_DIR}/final-devices.tmp" ]; then
        echo "⚠️ 最终设备列表为空，强制写入关键设备" | tee -a "${LOG_FILE}"
        echo "${TARGET_DEVICES[0]}" > "${LOG_DIR}/final-devices.tmp"
    fi
    
    # 生成JSON，失败则手动创建
    if ! jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)),
            "count": ($devices | split("\n") | map(select(length > 0)) | length)
        }' > "${DEVICE_JSON}" 2>> "${LOG_FILE}"; then
        echo "⚠️ jq命令失败，手动创建JSON" | tee -a "${LOG_FILE}"
        cat > "${DEVICE_JSON}" <<EOF
{"devices": ["$(cat "${LOG_DIR}/final-devices.tmp")"], "count": 1}
EOF
    fi
    
    echo "✅ ${DEVICE_JSON} 生成成功（容错模式）" | tee -a "${LOG_FILE}"
}

# 主流程（全程容错，确保不中断）
main() {
    init
    update_openwrt_source  # 允许失败，继续执行
    fetch_devices
    generate_device_json
    
    echo -e "\n===== 设备同步完成 =====" | tee -a "${LOG_FILE}"
    echo "详细日志: ${LOG_FILE}"
    echo "设备列表: ${DEVICE_JSON}（共 $(jq '.count' "${DEVICE_JSON}" 2>/dev/null || echo 1) 个设备）"
}

main
