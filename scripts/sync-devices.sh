#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数
# ==============================================
OUTPUT_JSON="device-drivers.json"
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-devices.log"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
MANDATORY_DEVICES=("cudy-tr3000" "cudy_tr3000")  # 兼容两种命名格式
MANDATORY_CHIPS=("mt7981" "mt7621")

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
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" > "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "awk" "sed" "find" "sort" "uniq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            error_log "缺少必要工具: ${tool}（请安装后重试）"
            exit 1
        fi
    done
    info_log "所有依赖工具已安装"
}

# ==============================================
# 拉取/更新OpenWrt源码
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
            error_log "源码更新失败，尝试重新克隆"
            cd .. && rm -rf "${OPENWRT_DIR}" || {
                error_log "无法删除旧源码目录"
                exit 1
            }
            clone_openwrt_source
        fi
        cd ..
    else
        clone_openwrt_source
    fi

    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        error_log "源码目录结构无效，未找到target/linux目录"
        exit 1
    fi
    info_log "源码处理完成"
}

clone_openwrt_source() {
    info_log "开始克隆OpenWrt源码仓库"
    if ! git clone --depth 1 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        error_log "源码克隆失败（仓库地址: ${OPENWRT_REPO}）"
        exit 1
    fi
    info_log "源码克隆完成"
}

# ==============================================
# 抓取设备列表（核心修复：错误隔离）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 ====="
    info_log "开始抓取设备列表"
    
    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        error_log "源码目录不存在，无法抓取设备列表"
        exit 1
    fi

    # 查找设备相关文件
    info_log "开始查找设备相关文件"
    local device_files
    device_files=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "*.dts" -o -name "*.dtsi" -o -name "devices.mk" -o -name "profiles.mk" \
    \) 2>> "${LOG_FILE}")

    if [ -z "${device_files}" ]; then
        error_log "未找到任何设备相关文件"
        exit 1
    fi
    local file_count=$(echo "${device_files}" | wc -l)
    info_log "找到 ${file_count} 个设备相关文件"

    # 核心修复1：使用临时文件存储提取结果，避免管道错误导致整体失败
    local temp_extract=$(mktemp)
    info_log "临时提取文件: ${temp_extract}"

    # 核心修复2：逐文件处理，单个文件错误不影响全局，仅记录日志
    info_log "开始提取设备名称（错误隔离模式）"
    while IFS= read -r file; do
        # 跳过空行
        [ -z "${file}" ] && continue
        
        # 尝试提取设备名称，忽略单个文件的错误
        if ! grep -hE "DEVICE_NAME[:=][[:space:]]*|model[:=][[:space:]]*|boardname[:=][[:space:]]*" "${file}" 2>> "${LOG_FILE}" |
            sed -E \
                -e "s/DEVICE_NAME[:=][[:space:]]*//gi" \
                -e "s/model[:=][[:space:]]*['\"]//gi" \
                -e "s/boardname[:=][[:space:]]*['\"]//gi" \
                -e "s/['\";,\t\/\\]//g" \
                -e "s/^[[:space:]]*//g" \
                -e "s/[[:space:]]+$//g" >> "${temp_extract}"; then
            info_log "警告：文件处理失败（已跳过）: ${file}"
        fi
    done <<< "${device_files}"

    # 处理提取结果（去重、过滤无效值）
    local raw_devices
    raw_devices=$(grep -vE "^$|^#|^//|^[0-9]+$" "${temp_extract}" | sort -u)
    
    # 清理临时文件
    rm -f "${temp_extract}"

    # 核心修复3：即使提取结果为空，也用必填设备兜底，避免流程中断
    if [ -z "${raw_devices}" ]; then
        info_log "所有文件提取失败，使用必填设备兜底"
        raw_devices="${MANDATORY_DEVICES[*]}"
    fi

    # 标准化设备名称（统一转为连字符格式）
    local normalized_devices
    normalized_devices=$(echo "${raw_devices}" | sed -e "s/_/-/g" | sort -u)

    # 保存原始结果
    echo "${normalized_devices}" > "${LOG_DIR}/raw-devices.tmp"
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    info_log "从源码中抓取到 ${raw_count} 个原始设备"
    
    # 确保必填设备存在
    local final_devices="${normalized_devices}"
    for device in "${MANDATORY_DEVICES[@]}"; do
        local normalized_device=$(echo "${device}" | sed -e "s/_/-/g")
        if ! echo "${final_devices}" | grep -q "^${normalized_device}$"; then
            info_log "未抓取到必填设备 ${device}，手动添加"
            final_devices="${final_devices}"$'\n'"${normalized_device}"
        fi
    done
    
    # 去重并清理空行
    echo "${final_devices}" | sort -u | grep -vE "^$" > "${LOG_DIR}/final-devices.tmp"
    local total_devices=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    info_log "最终设备列表生成完成（共 ${total_devices} 个设备）"
}

# ==============================================
# 抓取芯片列表（同设备列表错误隔离逻辑）
# ==============================================
fetch_chips() {
    echo -e "\n===== 抓取芯片列表 ====="
    info_log "开始抓取芯片列表"
    
    local temp_extract=$(mktemp)
    info_log "临时提取文件: ${temp_extract}"

    # 逐文件处理芯片信息
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

    # 兜底处理
    if [ -z "${raw_chips}" ]; then
        info_log "所有文件提取失败，使用必填芯片兜底"
        raw_chips="${MANDATORY_CHIPS[*]}"
    fi

    echo "${raw_chips}" > "${LOG_DIR}/raw-chips.tmp"
    info_log "从源码中抓取到 $(wc -l < "${LOG_DIR}/raw-chips.tmp") 个原始芯片"
    
    local final_chips="${raw_chips}"
    for chip in "${MANDATORY_CHIPS[@]}"; do
        if ! echo "${final_chips}" | grep -q "^${chip}$"; then
            info_log "未抓取到必填芯片 ${chip}，手动添加"
            final_chips="${final_chips}"$'\n'"${chip}"
        fi
    done
    
    echo "${final_chips}" | sort -u | grep -vE "^$" > "${LOG_DIR}/final-chips.tmp"
    local total_chips=$(wc -l < "${LOG_DIR}/final-chips.tmp")
    info_log "最终芯片列表生成完成（共 ${total_chips} 个芯片）"
}

# ==============================================
# 生成JSON文件
# ==============================================
generate_json() {
    echo -e "\n===== 生成${OUTPUT_JSON} ====="
    info_log "开始生成设备配置JSON文件"
    
    # 检查临时文件
    if [ ! -f "${LOG_DIR}/final-devices.tmp" ] || [ ! -s "${LOG_DIR}/final-devices.tmp" ]; then
        error_log "设备临时文件不存在或为空"
        exit 1
    fi
    if [ ! -f "${LOG_DIR}/final-chips.tmp" ] || [ ! -s "${LOG_DIR}/final-chips.tmp" ]; then
        error_log "芯片临时文件不存在或为空"
        exit 1
    fi

    # 安全生成JSON
    if ! jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        --argfile chips "${LOG_DIR}/final-chips.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)) | map({name: .}),
            "chips": $chips | split("\n") | map(select(length > 0)) | map({name: .})
        }' > "${OUTPUT_JSON}" 2>> "${LOG_FILE}"; then
        error_log "jq命令错误详情：$(cat "${LOG_FILE}" | grep -A 10 "jq: error")"
        error_log "生成${OUTPUT_JSON}失败（JSON格式错误）"
        exit 1
    fi
    
    # 验证JSON
    if ! jq . "${OUTPUT_JSON}" &> /dev/null; then
        error_log "${OUTPUT_JSON} 格式无效"
        exit 1
    fi
    
    # 验证必填项
    for device in "${MANDATORY_DEVICES[@]}"; do
        local normalized_device=$(echo "${device}" | sed -e "s/_/-/g")
        if ! jq -e ".devices[] | select(.name == \"${normalized_device}\")" "${OUTPUT_JSON}" &> /dev/null; then
            error_log "${OUTPUT_JSON} 中缺少必填设备: ${normalized_device}"
            exit 1
        fi
    done
    for chip in "${MANDATORY_CHIPS[@]}"; do
        if ! jq -e ".chips[] | select(.name == \"${chip}\")" "${OUTPUT_JSON}" &> /dev/null; then
            error_log "${OUTPUT_JSON} 中缺少必填芯片: ${chip}"
            exit 1
        fi
    done
    
    info_log "${OUTPUT_JSON} 生成成功"
}

# ==============================================
# 主流程
# ==============================================
main() {
    init
    update_openwrt_source
    fetch_devices
    fetch_chips
    generate_json
    
    echo -e "\n===== 设备同步完成 ====="
    info_log "设备同步流程完成"
    echo "详细日志: ${LOG_FILE}"
    echo "生成的设备配置: ${OUTPUT_JSON}"
    echo "设备数量: $(jq '.devices | length' "${OUTPUT_JSON}")"
    echo "芯片数量: $(jq '.chips | length' "${OUTPUT_JSON}")"
}

main
