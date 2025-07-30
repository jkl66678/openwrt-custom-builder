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
MANDATORY_DEVICES=("cuby-tr3000")
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
# 抓取设备列表（核心修复部分）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 ====="
    info_log "开始抓取设备列表"
    
    if [ ! -d "${OPENWRT_DIR}/target/linux" ]; then
        error_log "源码目录不存在，无法抓取设备列表"
        exit 1
    fi

    # 查找设备相关文件并记录
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

    # 核心修复：增强提取命令的容错性，记录错误文件
    info_log "开始提取设备名称（允许部分文件处理失败）"
    local raw_devices
    # 使用while循环逐文件处理，避免批量命令失败导致整体中断
    raw_devices=$(while IFS= read -r file; do
        # 单个文件提取失败不影响整体，仅记录日志
        if ! grep -hE "DEVICE_NAME[:=][[:space:]]*|model[:=][[:space:]]*|boardname[:=][[:space:]]*" "${file}" 2>> "${LOG_FILE}"; then
            info_log "警告：文件提取失败（忽略）: ${file}"
        fi
    done <<< "${device_files}" | \
        sed -E \
            -e "s/DEVICE_NAME[:=][[:space:]]*//g" \
            -e "s/model[:=][[:space:]]*['\"]//g" \
            -e "s/boardname[:=][[:space:]]*['\"]//g" \
            -e "s/['\";,\t ]//g" \
            -e "s/^[[:space:]]*//g" \
        | grep -vE "^$|^#|^//|^[0-9]+$" | sort -u)

    # 检查提取结果（允许部分失败，只要有有效内容）
    if [ -z "${raw_devices}" ]; then
        error_log "所有文件均未提取到设备名称，使用必填设备兜底"
        raw_devices="${MANDATORY_DEVICES[*]}"  # 直接使用必填设备
    fi

    # 保存原始结果
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    info_log "从源码中抓取到 ${raw_count} 个原始设备"
    
    # 确保必填设备存在
    local final_devices="${raw_devices}"
    for device in "${MANDATORY_DEVICES[@]}"; do
        if ! echo "${final_devices}" | grep -q "^${device}$"; then
            info_log "未抓取到必填设备 ${device}，手动添加"
            final_devices="${final_devices}"$'\n'"${device}"
        fi
    done
    
    # 去重输出
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total_devices=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    info_log "最终设备列表生成完成（共 ${total_devices} 个设备）"
}

# ==============================================
# 抓取芯片列表
# ==============================================
fetch_chips() {
    echo -e "\n===== 抓取芯片列表 ====="
    info_log "开始抓取芯片列表"
    
    local raw_chips
    # 同样采用逐文件处理增强容错
    raw_chips=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "Makefile" -o -name "*.dts" -o -name "config-*" \
    \) -exec grep -hE "TARGET_(CPU|BOARD)|SOC[:=]|CHIP[:=]|ARCH[:=]" {} + 2>> "${LOG_FILE}" | \
        sed -E \
            -e "s/TARGET_(CPU|BOARD|ARCH)[:=][[:space:]]*//g" \
            -e "s/SOC[:=][[:space:]]*//g" \
            -e "s/CHIP[:=][[:space:]]*//g" \
            -e "s/['\";,\t _-]//g" \
            -e "s/^[[:space:]]*//g" \
        | grep -vE "^$|^#|^//|^[A-Z]+$" | sort -u)

    if [ -z "${raw_chips}" ]; then
        error_log "所有文件均未提取到芯片型号，使用必填芯片兜底"
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
    
    echo "${final_chips}" | sort -u > "${LOG_DIR}/final-chips.tmp"
    local total_chips=$(wc -l < "${LOG_DIR}/final-chips.tmp")
    info_log "最终芯片列表生成完成（共 ${total_chips} 个芯片）"
}

# ==============================================
# 生成JSON文件
# ==============================================
generate_json() {
    echo -e "\n===== 生成${OUTPUT_JSON} ====="
    info_log "开始生成设备配置JSON文件"
    
    if ! jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        --argfile chips "${LOG_DIR}/final-chips.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)) | map({name: .}),
            "chips": $chips | split("\n") | map(select(length > 0)) | map({name: .})
        }' > "${OUTPUT_JSON}" 2>> "${LOG_FILE}"; then
        error_log "生成${OUTPUT_JSON}失败（JSON格式错误）"
        exit 1
    fi
    
    if ! jq . "${OUTPUT_JSON}" &> /dev/null; then
        error_log "${OUTPUT_JSON} 格式无效"
        exit 1
    fi
    
    for device in "${MANDATORY_DEVICES[@]}"; do
        if ! jq -e ".devices[] | select(.name == \"${device}\")" "${OUTPUT_JSON}" &> /dev/null; then
            error_log "${OUTPUT_JSON} 中缺少必填设备: ${device}"
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
