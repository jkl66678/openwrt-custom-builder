#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数
# ==============================================
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"  # OpenWrt源码仓库
OPENWRT_DIR="openwrt-source"                         # 本地源码目录
TARGET_DEVICES=("cuby-tr3000")                       # 必须包含的关键设备

# ==============================================
# 初始化环境
# ==============================================
init() {
    echo "===== 初始化同步环境 ====="
    
    # 创建日志目录
    mkdir -p "${LOG_DIR}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步流程" > "${LOG_FILE}"
    
    # 检查必要工具
    local required_tools=("git" "jq" "grep" "awk" "find" "sort")
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

# 克隆源码（独立函数，方便重试）
clone_openwrt_source() {
    echo "克隆源码仓库..." | tee -a "${LOG_FILE}"
    git clone --depth 1 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1 || {
        echo "❌ 源码克隆失败，请检查网络或仓库地址" | tee -a "${LOG_FILE}"
        exit 1
    }
}

# ==============================================
# 抓取设备列表（核心逻辑）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 从多个来源抓取设备信息（扩大覆盖范围）
    local device_files
    device_files=$(find "${OPENWRT_DIR}/target/linux/" -type f \( \
        -name "*.dts" -o -name "*.dtsi" -o -name "profiles.mk" -o -name "devices.mk" \
    \))
    
    # 提取设备名称（支持多种命名格式）
    local raw_devices
    raw_devices=$(grep -hE "DEVICE_(NAME|TITLE)|model|boardname|DEVICE_COMPAT_VERSION" ${device_files} | \
        sed -E 's/DEVICE_NAME:?=//; s/DEVICE_TITLE:?=//; s/model=//; s/boardname=//; s/["'\''\t ]//g; s/^[[:space:]]*//' | \
        grep -vE "^$|^#|^//" | sort -u)
    
    # 合并结果并去重
    echo "${raw_devices}" > "${LOG_DIR}/raw-devices.tmp"
    echo "已从源码中抓取到 $(wc -l < "${LOG_DIR}/raw-devices.tmp") 个潜在设备" | tee -a "${LOG_FILE}"
    
    # 确保关键设备被包含（手动兜底）
    local final_devices="${raw_devices}"
    for target in "${TARGET_DEVICES[@]}"; do
        if ! echo "${final_devices}" | grep -q "^${target}$"; then
            echo "⚠️ 未自动抓取到 ${target}，手动添加" | tee -a "${LOG_FILE}"
            final_devices="${final_devices}"$'\n'"${target}"
        fi
    done
    
    # 去重并输出最终设备列表
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成完成（共 ${total} 个设备）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成设备JSON文件
# ==============================================
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    # 从临时文件生成JSON
    jq -n --argfile devices "${LOG_DIR}/final-devices.tmp" \
        '{"devices": $devices | split("\n") | map(select(length > 0))}' > "${DEVICE_JSON}" || {
        echo "❌ 生成 ${DEVICE_JSON} 失败" | tee -a "${LOG_FILE}"
        exit 1
    }
    
    # 验证JSON有效性和关键设备
    if ! jq . "${DEVICE_JSON}" &> /dev/null; then
        echo "❌ ${DEVICE_JSON} 格式无效" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    for target in "${TARGET_DEVICES[@]}"; do
        if ! jq -e ".devices[] | select(. == \"${target}\")" "${DEVICE_JSON}" &> /dev/null; then
            echo "❌ ${DEVICE_JSON} 中仍缺少关键设备: ${target}" | tee -a "${LOG_FILE}"
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
    echo "设备列表: ${DEVICE_JSON}"
}

# 启动主流程
main
