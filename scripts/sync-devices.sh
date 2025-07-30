#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数（增强提取范围）
# ==============================================
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
TARGET_DEVICES=("cuby-tr3000")  # 关键设备
# 扩展设备定义文件类型和关键词
SEARCH_FILES=("*.dts" "*.dtsi" "*.mk" "Makefile" "*.conf" "*.yml")
SEARCH_KEYWORDS=(
    "DEVICE_NAME" "DEVICE_TITLE" "model" "boardname" 
    "BOARD_NAME" "DEVICE_ID" "product" "hwmodel"
    "DEVICE_COMPAT" "SOC_MODEL" "MACHINE"
)

# ==============================================
# 初始化环境
# ==============================================
init() {
    echo "===== 初始化同步环境 ====="
    
    mkdir -p "${LOG_DIR}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" > "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "awk" "find" "sort" "uniq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# ==============================================
# 获取/更新OpenWrt源码
# ==============================================
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    if [ -d "${OPENWRT_DIR}" ]; then
        echo "更新现有源码仓库..." | tee -a "${LOG_FILE}"
        cd "${OPENWRT_DIR}" || {
            echo "❌ 无法进入源码目录: ${OPENWRT_DIR}" | tee -a "${LOG_FILE}"
            exit 1
        }
        git pull --rebase origin main >> "${LOG_FILE}" 2>&1 || {
            echo "⚠️ 源码更新失败，尝试重新克隆" | tee -a "${LOG_FILE}"
            cd .. && rm -rf "${OPENWRT_DIR}"
            clone_openwrt_source
        }
        cd ..
    else
        clone_openwrt_source
    fi
}

clone_openwrt_source() {
    echo "克隆源码仓库..." | tee -a "${LOG_FILE}"
    git clone --depth 1 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1 || {
        echo "❌ 源码克隆失败，请检查网络或仓库地址" | tee -a "${LOG_FILE}"
        exit 1
    }
}

# ==============================================
# 抓取设备列表（增强版：扩大范围+精准提取）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 1. 构建文件搜索表达式（扩展文件类型）
    local file_pattern=""
    for pattern in "${SEARCH_FILES[@]}"; do
        file_pattern+=" -o -name '${pattern}'"
    done
    file_pattern=$(echo "${file_pattern}" | sed 's/^ -o //')  # 移除首个-o
    
    # 2. 查找所有相关文件（覆盖更多目录）
    local device_files
    device_files=$(find "${OPENWRT_DIR}/target/linux/" \
        -path "${OPENWRT_DIR}/target/linux/*/dts" \
        -o -path "${OPENWRT_DIR}/target/linux/*/profiles" \
        -o -path "${OPENWRT_DIR}/target/linux/*/image" \
        -type f \( ${file_pattern} \) 2>> "${LOG_FILE}")
    
    echo "找到 $(echo "${device_files}" | wc -l) 个设备相关文件（扩展搜索）" | tee -a "${LOG_FILE}"
    
    # 3. 构建关键词正则（覆盖更多设备定义字段）
    local keyword_regex=""
    for kw in "${SEARCH_KEYWORDS[@]}"; do
        keyword_regex+="|${kw}"
    done
    keyword_regex="(${keyword_regex:1})"  # 移除首个|
    
    # 4. 提取设备名称（优化过滤规则，保留更多有效名称）
    local raw_devices
    raw_devices=$(grep -hE "${keyword_regex}[:=][[:space:]]*" ${device_files} 2>> "${LOG_FILE}" | \
        # 提取字段值（支持=/:分隔，保留连字符/下划线）
        sed -E \
            -e "s/${keyword_regex}[:=][[:space:]]*//gi" \
            -e "s/[\"'<>\`]//g"  # 仅移除危险符号，保留-/_等合法字符
            -e "s/^[[:space:]]+//; s/[[:space:]]+$//" \
            -e "s/[[:space:]]+/ /g" | \
        # 过滤无效值（保留带数字/字母/符号的合理名称）
        grep -vE "^$|^#|^//|^[0-9]+$|^[A-Z_]+$" | \
        # 标准化处理（统一小写，避免重复）
        tr '[:upper:]' '[:lower:]' | \
        sort -u)
    
    # 5. 保存原始提取结果（便于调试）
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    echo "初步提取到 $(wc -l < "${LOG_DIR}/raw-devices.tmp") 个设备名称" | tee -a "${LOG_FILE}"
    
    # 6. 强制保留关键设备（兼容不同命名格式）
    local final_devices="${raw_devices}"
    for target in "${TARGET_DEVICES[@]}"; do
        # 同时检查原始名称和小写版本
        if ! echo -e "${final_devices}\n${final_devices^^}" | grep -q "^${target}$"; then
            echo "⚠️ 未自动抓取到 ${target}，手动添加" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${target}"
        fi
    done
    
    # 7. 去重并输出最终结果
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total} 个设备）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成设备JSON文件（保留完整信息）
# ==============================================
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    # 生成包含原始名称和标准化名称的详细JSON
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
    
    echo "✅ ${DEVICE_JSON} 生成成功，包含所有关键设备" | tee -a "${LOG_FILE}"
}

# ==============================================
# 主流程
# ==============================================
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
