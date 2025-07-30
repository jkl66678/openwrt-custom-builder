#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数（与generate-workflow.sh对应）
# ==============================================
OUTPUT_JSON="device-drivers.json"  # 输出的设备配置文件
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-devices.log"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"  # OpenWrt源码仓库
OPENWRT_DIR="openwrt-source"                         # 本地源码目录
MANDATORY_DEVICES=("cuby-tr3000")                    # 必须包含的设备
MANDATORY_CHIPS=("mt7981" "mt7621")                  # 必须包含的芯片

# ==============================================
# 初始化环境
# ==============================================
init() {
    echo "===== 初始化设备同步环境 ====="
    
    # 创建日志目录
    mkdir -p "${LOG_DIR}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" > "${LOG_FILE}"
    
    # 检查必要工具
    local required_tools=("git" "jq" "grep" "awk" "sed" "find" "sort" "uniq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}（请安装后重试）" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# ==============================================
# 拉取/更新OpenWrt源码
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
    echo "克隆OpenWrt源码仓库..." | tee -a "${LOG_FILE}"
    git clone --depth 1 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1 || {
        echo "❌ 源码克隆失败（请检查网络或仓库地址）" | tee -a "${LOG_FILE}"
        exit 1
    }
}

# ==============================================
# 抓取设备列表（适配generate-workflow.sh的.devices[].name）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 从DTS文件和设备配置中提取设备名称（使用-exec避免参数过长）
    local raw_devices
    raw_devices=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "*.dts" -o -name "*.dtsi" -o -name "devices.mk" -o -name "profiles.mk" \
    \) -exec grep -hE "DEVICE_NAME[:=][[:space:]]*|model[:=][[:space:]]*|boardname[:=][[:space:]]*" {} + | \
        sed -E \
            -e "s/DEVICE_NAME[:=][[:space:]]*//g" \
            -e "s/model[:=][[:space:]]*['\"]//g" \
            -e "s/boardname[:=][[:space:]]*['\"]//g" \
            -e "s/['\";,\t ]//g" \
            -e "s/^[[:space:]]*//g" \
        | grep -vE "^$|^#|^//|^[0-9]+$" | sort -u)
    
    # 保存原始抓取结果
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    echo "从源码中抓取到 $(wc -l < "${LOG_DIR}/raw-devices.tmp") 个原始设备" | tee -a "${LOG_FILE}"
    
    # 确保必填设备被包含（兜底逻辑）
    local final_devices="${raw_devices}"
    for device in "${MANDATORY_DEVICES[@]}"; do
        if ! echo "${final_devices}" | grep -q "^${device}$"; then
            echo "⚠️ 未抓取到必填设备 ${device}，手动添加" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${device}"
        fi
    done
    
    # 去重并输出最终设备列表
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total_devices=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total_devices} 个设备）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 抓取芯片列表（适配generate-workflow.sh的.chips[].name）
# ==============================================
fetch_chips() {
    echo -e "\n===== 抓取芯片列表 =====" | tee -a "${LOG_FILE}"
    
    # 从内核配置和设备树中提取芯片型号（使用-exec避免参数过长）
    local raw_chips
    raw_chips=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "Makefile" -o -name "*.dts" -o -name "config-*" \
    \) -exec grep -hE "TARGET_(CPU|BOARD)|SOC[:=]|CHIP[:=]|ARCH[:=]" {} + | \
        sed -E \
            -e "s/TARGET_(CPU|BOARD|ARCH)[:=][[:space:]]*//g" \
            -e "s/SOC[:=][[:space:]]*//g" \
            -e "s/CHIP[:=][[:space:]]*//g" \
            -e "s/['\";,\t _-]//g" \
            -e "s/^[[:space:]]*//g" \
        | grep -vE "^$|^#|^//|^[A-Z]+$" | sort -u)
    
    # 保存原始抓取结果
    echo "${raw_chips}" > "${LOG_DIR}/raw-chips.tmp"
    echo "从源码中抓取到 $(wc -l < "${LOG_DIR}/raw-chips.tmp") 个原始芯片" | tee -a "${LOG_FILE}"
    
    # 确保必填芯片被包含（兜底逻辑）
    local final_chips="${raw_chips}"
    for chip in "${MANDATORY_CHIPS[@]}"; do
        if ! echo "${final_chips}" | grep -q "^${chip}$"; then
            echo "⚠️ 未抓取到必填芯片 ${chip}，手动添加" | tee -a "${LOG_FILE}"
            final_chips="${final_chips}"$'\n'"${chip}"
        fi
    done
    
    # 去重并输出最终芯片列表
    echo "${final_chips}" | sort -u > "${LOG_DIR}/final-chips.tmp"
    local total_chips=$(wc -l < "${LOG_DIR}/final-chips.tmp")
    echo "✅ 最终芯片列表生成完成（共 ${total_chips} 个芯片）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成device-drivers.json（适配generate-workflow.sh的格式）
# ==============================================
generate_json() {
    echo -e "\n===== 生成${OUTPUT_JSON} =====" | tee -a "${LOG_FILE}"
    
    # 从临时文件生成JSON结构（确保格式为{"devices": [{"name": "xxx"}, ...], "chips": [{"name": "xxx"}, ...]}）
    jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        --argfile chips "${LOG_DIR}/final-chips.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)) | map({name: .}),
            "chips": $chips | split("\n") | map(select(length > 0)) | map({name: .})
        }' > "${OUTPUT_JSON}" || {
        echo "❌ 生成${OUTPUT_JSON}失败（JSON格式错误）" | tee -a "${LOG_FILE}"
        exit 1
    }
    
    # 验证JSON格式和必填设备
    if ! jq . "${OUTPUT_JSON}" &> /dev/null; then
        echo "❌ ${OUTPUT_JSON} 格式无效" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证必填设备是否存在
    for device in "${MANDATORY_DEVICES[@]}"; do
        if ! jq -e ".devices[] | select(.name == \"${device}\")" "${OUTPUT_JSON}" &> /dev/null; then
            echo "❌ ${OUTPUT_JSON} 中缺少必填设备: ${device}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    
    echo "✅ ${OUTPUT_JSON} 生成成功，格式完全适配generate-workflow.sh" | tee -a "${LOG_FILE}"
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
    
    echo -e "\n===== 设备同步完成 =====" | tee -a "${LOG_FILE}"
    echo "详细日志: ${LOG_FILE}"
    echo "生成的设备配置: ${OUTPUT_JSON}"
    echo "设备数量: $(jq '.devices | length' "${OUTPUT_JSON}")"
    echo "芯片数量: $(jq '.chips | length' "${OUTPUT_JSON}")"
}

# 启动主流程
main
