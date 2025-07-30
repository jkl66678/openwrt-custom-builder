#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数（无兜底数据）
# ==============================================
OUTPUT_JSON="device-drivers.json"
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-devices.log"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
MANDATORY_DEVICES=("cudy-tr3000")  # 必须从源码提取的设备
MANDATORY_CHIPS=("mt7981" "mt7621")  # 必须从源码提取的芯片

# 日志函数
error_log() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: ${message}" >> "${LOG_FILE}"
    echo "❌ ${message}"
}

info_log() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: ${message}" >> "${LOG_FILE}"
    echo "ℹ️ ${message}"
}

# ==============================================
# 初始化环境
# ==============================================
init() {
    echo "===== 初始化设备同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"  # 清空日志
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "sed" "find" "sort" "uniq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            error_log "缺少必要工具: ${tool}（请安装后重试）"
            exit 1
        fi
    done
    info_log "所有依赖工具已安装"
}

# ==============================================
# 拉取/更新OpenWrt源码（失败则终止）
# ==============================================
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 ====="
    info_log "开始处理OpenWrt源码"
    
    if [ -d "${OPENWRT_DIR}" ]; then
        info_log "更新现有源码仓库"
        cd "${OPENWRT_DIR}" || {
            error_log "无法进入源码目录: ${OPENWRT_DIR}"
            exit 1
        }
        if ! git pull --rebase origin main >> "${LOG_FILE}" 2>&1; then
            error_log "源码更新失败"
            exit 1
        fi
        cd ..
    else
        info_log "克隆OpenWrt源码仓库"
        if ! git clone --depth 1 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
            error_log "源码克隆失败（仓库地址: ${OPENWRT_REPO}）"
            exit 1
        fi
    fi

    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        error_log "源码目录结构无效，未找到target/linux目录"
        exit 1
    fi
    info_log "源码处理完成"
}

# ==============================================
# 抓取设备列表（纯源码提取，无兜底）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 ====="
    info_log "开始抓取设备列表"
    
    # 查找设备相关文件（必须找到至少一个文件）
    info_log "开始查找设备相关文件"
    local device_files
    device_files=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "*.dts" -o -name "*.dtsi" -o -name "devices.mk" -o -name "profiles.mk" \
    \) 2>> "${LOG_FILE}")

    if [ -z "${device_files}" ]; then
        error_log "未找到任何设备相关文件，无法提取设备列表"
        exit 1
    fi
    local file_count=$(echo "${device_files}" | wc -l)
    info_log "找到 ${file_count} 个设备相关文件"

    # 提取设备名称（单个文件失败不影响，但最终结果不能为空）
    local temp_extract=$(mktemp)
    info_log "开始提取设备名称（无兜底模式）"
    
    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        [ ! -f "${file}" ] && { info_log "跳过不存在的文件: ${file}"; continue; }
        
        # 提取逻辑（失败仅记录，不中断）
        grep -hE "DEVICE_NAME[:=][[:space:]]*|model[:=][[:space:]]*|boardname[:=][[:space:]]*" "${file}" 2>> "${LOG_FILE}" |
            sed -E \
                -e "s/DEVICE_NAME[:=][[:space:]]*//gi" \
                -e "s/model[:=][[:space:]]*['\"]//gi" \
                -e "s/boardname[:=][[:space:]]*['\"]//gi" \
                -e "s/['\";,\t\/\\]//g" \
                -e "s/^[[:space:]]*//g" \
                -e "s/[[:space:]]+$//g" >> "${temp_extract}" || true
    done <<< "${device_files}"

    # 处理提取结果（必须非空）
    local raw_devices
    raw_devices=$(grep -vE "^$|^#|^//|^[0-9]+$" "${temp_extract}" | sort -u)
    rm -f "${temp_extract}"

    if [ -z "${raw_devices}" ]; then
        error_log "设备名称提取结果为空，无兜底数据可用"
        exit 1
    fi

    # 标准化设备名称
    local normalized_devices
    normalized_devices=$(echo "${raw_devices}" | sed -e "s/_/-/g" | sort -u)

    # 保存原始结果
    echo "${normalized_devices}" > "${LOG_DIR}/raw-devices.tmp"
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    info_log "从源码中抓取到 ${raw_count} 个原始设备"
    
    # 验证必填设备（必须存在，否则失败）
    local final_devices="${normalized_devices}"
    for device in "${MANDATORY_DEVICES[@]}"; do
        local normalized_device=$(echo "${device}" | sed -e "s/_/-/g")
        if ! echo "${final_devices}" | grep -q "^${normalized_device}$"; then
            error_log "未从源码中提取到必填设备: ${device}（无兜底）"
            exit 1
        fi
    done
    
    # 去重并保存
    echo "${final_devices}" | sort -u | grep -vE "^$" > "${LOG_DIR}/final-devices.tmp"
    local total_devices=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    info_log "最终设备列表生成完成（共 ${total_devices} 个设备）"
}

# ==============================================
# 抓取芯片列表（纯源码提取，无兜底）
# ==============================================
fetch_chips() {
    echo -e "\n===== 抓取芯片列表 ====="
    info_log "开始抓取芯片列表"
    
    # 提取芯片型号（必须有结果）
    local temp_extract=$(mktemp)
    
    find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "Makefile" -o -name "*.dts" -o -name "config-*" \
    \) -exec grep -hE "mt7981|mt7981b|mt7621|MT7981|MT7981B|MT7621" {} + 2>> "${LOG_FILE}" |
        sed -E \
            -e "s/TARGET_(CPU|BOARD|ARCH)[:=][[:space:]]*//g" \
            -e "s/SOC[:=][[:space:]]*//g" \
            -e "s/CHIP[:=][[:space:]]*//g" \
            -e "s/['\";,\t _-]//g" \
            -e "s/^[[:space:]]*//g" \
            -e "s/^MT/mt/" \
            -e "s/b$//i" >> "${temp_extract}"

    local raw_chips
    raw_chips=$(grep -vE "^$|^#|^//|^[A-Z]+$" "${temp_extract}" | sort -u)
    rm -f "${temp_extract}"

    if [ -z "${raw_chips}" ]; then
        error_log "芯片型号提取结果为空，无兜底数据可用"
        exit 1
    fi

    echo "${raw_chips}" > "${LOG_DIR}/raw-chips.tmp"
    info_log "从源码中抓取到 $(wc -l < "${LOG_DIR}/raw-chips.tmp") 个原始芯片"
    
    # 验证必填芯片（必须存在）
    local final_chips="${raw_chips}"
    for chip in "${MANDATORY_CHIPS[@]}"; do
        if ! echo "${final_chips}" | grep -q "^${chip}$"; then
            error_log "未从源码中提取到必填芯片: ${chip}（无兜底）"
            exit 1
        fi
    done
    
    echo "${final_chips}" | sort -u | grep -vE "^$" > "${LOG_DIR}/final-chips.tmp"
    local total_chips=$(wc -l < "${LOG_DIR}/final-chips.tmp")
    info_log "最终芯片列表生成完成（共 ${total_chips} 个芯片）"
}

# ==============================================
# 生成JSON文件（仅使用源码提取数据）
# ==============================================
generate_json() {
    echo -e "\n===== 生成${OUTPUT_JSON} ====="
    info_log "开始生成设备配置JSON文件"
    
    # 验证临时文件有效性
    if [ ! -f "${LOG_DIR}/final-devices.tmp" ] || [ ! -s "${LOG_DIR}/final-devices.tmp" ]; then
        error_log "设备临时文件无效且无兜底数据"
        exit 1
    fi
    if [ ! -f "${LOG_DIR}/final-chips.tmp" ] || [ ! -s "${LOG_DIR}/final-chips.tmp" ]; then
        error_log "芯片临时文件无效且无兜底数据"
        exit 1
    fi

    # 生成JSON（失败则终止）
    if ! jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        --argfile chips "${LOG_DIR}/final-chips.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)) | map({name: .}),
            "chips": $chips | split("\n") | map(select(length > 0)) | map({name: .})
        }' > "${OUTPUT_JSON}" 2>> "${LOG_FILE}"; then
        error_log "JSON生成失败（无兜底），查看日志获取详情"
        exit 1
    fi
    
    # 验证JSON格式
    if ! jq . "${OUTPUT_JSON}" &> /dev/null; then
        error_log "生成的JSON格式无效（无兜底）"
        exit 1
    fi
    
    info_log "${OUTPUT_JSON} 生成成功"
}

# ==============================================
# 主流程（任何步骤失败即终止）
# ==============================================
main() {
    init
    update_openwrt_source
    fetch_devices
    fetch_chips
    generate_json
    
    echo -e "\n===== 设备同步完成 ====="
    echo "详细日志: ${LOG_FILE}"
    echo "生成的设备配置: ${OUTPUT_JSON}"
    echo "设备数量: $(jq '.devices | length' "${OUTPUT_JSON}")"
    echo "芯片数量: $(jq '.chips | length' "${OUTPUT_JSON}")"
}

main
