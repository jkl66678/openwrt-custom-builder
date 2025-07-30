#!/bin/bash
set -uo pipefail  # 保留容错但不自动终止，便于排查

# ==============================================
# 配置参数（精准匹配OpenWrt源码结构）
# ==============================================
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
# 核心设备定义目录（OpenWrt官方标准路径）
DEVICE_DIRS=(
    "${OPENWRT_DIR}/target/linux/*/dts"         # 设备树文件（必含设备型号）
    "${OPENWRT_DIR}/target/linux/*/profiles"     # 设备配置文件
    "${OPENWRT_DIR}/target/linux/*/image"        # 镜像生成配置（含设备列表）
)
# 精准匹配的设备关键词（符合OpenWrt源码规范）
DEVICE_KEYWORDS=(
    "DEVICE_NAME[:=][[:space:]]*"                # 标准设备名定义（如DEVICE_NAME := xxx）
    "model[[:space:]]*=[[:space:]]*[\"']"        # 设备树中型号定义（如model = "xxx"）
    "BOARD_NAME[[:=][:space:]]*"                # 板型名称定义
    "SUPPORTED_DEVICES[[:=][:space:]]*"          # 支持的设备列表（如SUPPORTED_DEVICES := xxx）
)

# ==============================================
# 初始化环境（增加源码完整性检查）
# ==============================================
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步（无兜底模式）" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "find" "sed" "awk" "ls")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 依赖工具齐全" | tee -a "${LOG_FILE}"
}

# ==============================================
# 克隆完整源码（确保设备文件不缺失）
# ==============================================
update_openwrt_source() {
    echo -e "\n===== 克隆完整源码 =====" | tee -a "${LOG_FILE}"
    
    # 强制删除旧目录，避免缓存干扰
    [ -d "${OPENWRT_DIR}" ] && rm -rf "${OPENWRT_DIR}"
    
    # 完整克隆（不限制深度，确保所有设备目录下载）
    echo "克隆源码（完整仓库，约5-10分钟）..." | tee -a "${LOG_FILE}"
    if ! git clone "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        echo "❌ 源码克隆失败（网络问题）" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证核心设备目录存在
    local missing_dir=0
    for dir_pattern in "${DEVICE_DIRS[@]}"; do
        # 检查是否有匹配的目录（允许通配符）
        if ! ls -d ${dir_pattern} &> /dev/null; then
            echo "⚠️ 未找到设备目录: ${dir_pattern}" | tee -a "${LOG_FILE}"
            missing_dir=1
        fi
    done
    if [ "${missing_dir}" -eq 1 ]; then
        echo "❌ 源码不完整，关键设备目录缺失" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ 源码克隆完成，设备目录验证通过" | tee -a "${LOG_FILE}"
}

# ==============================================
# 抓取设备列表（精准匹配源码格式）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表（无兜底） =====" | tee -a "${LOG_FILE}"
    
    # 1. 收集所有设备文件（遍历核心目录）
    local device_files=()
    for dir_pattern in "${DEVICE_DIRS[@]}"; do
        # 扩展通配符，获取实际文件路径
        for dir in $(ls -d ${dir_pattern} 2>/dev/null); do
            # 只取目标文件类型（dts、mk、Makefile）
            find "${dir}" -type f \( -name "*.dts" -o -name "*.mk" -o -name "Makefile" \) | while read -r file; do
                device_files+=("${file}")
            done
        done
    done
    
    # 2. 验证文件数量（至少10个才合理）
    local file_count=${#device_files[@]}
    echo "找到 ${file_count} 个设备文件（核心目录）" | tee -a "${LOG_FILE}"
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 未找到任何设备文件，源码异常" | tee -a "${LOG_FILE}"
        exit 1
    fi
    # 输出前5个文件路径到日志，确认是否正确
    echo "部分设备文件路径: ${device_files[@]:0:5}" | tee -a "${LOG_FILE}"
    
    # 3. 精准提取设备名称（匹配OpenWrt源码格式）
    local raw_devices
    # 构建关键词正则（支持多种定义格式）
    local keyword_regex="($(IFS=\|; echo "${DEVICE_KEYWORDS[*]}"))"
    # 逐个文件提取，确保匹配格式正确
    for file in "${device_files[@]}"; do
        # 提取DEVICE_NAME=xxx、model="xxx"等格式中的值
        grep -E "${keyword_regex}" "${file}" 2>/dev/null | \
            sed -E \
                -e "s/${keyword_regex}//gi" \  # 移除关键词前缀
                -e "s/[\"' ;,]+$//g" \         # 移除末尾引号和符号
                -e "s/^[[:space:]]+//g" \      # 移除前导空格
                -e "/^$/d"                     # 过滤空行
    done | sort -u > "${LOG_DIR}/raw-devices.tmp"
    
    # 4. 检查提取结果（禁止兜底，必须有真实设备）
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    echo "从源码中提取到 ${raw_count} 个设备" | tee -a "${LOG_FILE}"
    if [ "${raw_count}" -eq 0 ]; then
        echo "❌ 未提取到任何设备，匹配规则可能错误" | tee -a "${LOG_FILE}"
        # 输出一个设备文件内容到日志，帮助调试匹配规则
        echo "示例文件内容（首个文件）:" | tee -a "${LOG_FILE}"
        cat "${device_files[0]}" | head -n 20 >> "${LOG_FILE}"
        exit 1
    fi
    
    # 5. 确保关键设备在列（如未在列，说明提取规则遗漏）
    local final_devices=$(cat "${LOG_DIR}/raw-devices.tmp")
    local target="cuby-tr3000"
    if ! echo "${final_devices}" | grep -q "^${target}$"; then
        echo "⚠️ 关键设备 ${target} 未在提取结果中（可能型号不同）" | tee -a "${LOG_FILE}"
        # 不兜底，强制保留提取结果
    fi
    
    # 6. 输出最终结果
    echo "${final_devices}" | sort -u > "${LOG_DIR}/final-devices.tmp"
    local total=$(wc -l < "${LOG_DIR}/final-devices.tmp")
    echo "✅ 最终设备列表生成（共 ${total} 个，无兜底）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成JSON（确保无兜底）
# ==============================================
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    # 强制使用提取的设备列表，不手动创建
    jq -n \
        --argfile devices "${LOG_DIR}/final-devices.tmp" \
        '{
            "devices": $devices | split("\n") | map(select(length > 0)),
            "count": ($devices | split("\n") | map(select(length > 0)) | length)
        }' > "${DEVICE_JSON}" || {
        echo "❌ jq命令失败，提取结果异常" | tee -a "${LOG_FILE}"
        exit 1
    }
    
    echo "✅ ${DEVICE_JSON} 生成成功（纯源码提取）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 主流程（无兜底，强制源码提取）
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
