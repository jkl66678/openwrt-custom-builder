#!/bin/bash
set -uo pipefail  # 保留容错，避免小错误中断

# ==============================================
# 配置参数（精准匹配OpenWrt官方目录结构）
# ==============================================
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"
# OpenWrt官方设备文件核心目录（必含设备信息）
DEVICE_CORE_DIRS=(
    "${OPENWRT_DIR}/target/linux/ath79/dts"       # Atheros芯片设备树
    "${OPENWRT_DIR}/target/linux/ramips/dts"      # 联发科RAMIPS系列设备树
    "${OPENWRT_DIR}/target/linux/mediatek/dts"   # 联发科MTK系列设备树
    "${OPENWRT_DIR}/target/linux/x86/profiles"    # x86平台配置文件
    "${OPENWRT_DIR}/target/linux/realtek/dts"    # 瑞昱芯片设备树
)
# 设备定义关键词（严格匹配源码格式）
DEVICE_KEYWORDS=(
    "DEVICE_NAME[:=][[:space:]]*[\"']"  # .mk文件中：DEVICE_NAME := "设备名"
    "model[[:space:]]*=[[:space:]]*[\"']"  # .dts文件中：model = "设备名";
    "SUPPORTED_DEVICES[[:=][:space:]]*"   # .mk文件中：SUPPORTED_DEVICES := 设备名
)

# ==============================================
# 初始化环境（增强日志）
# ==============================================
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"  # 清空日志
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备同步（精准提取模式）" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "sed" "find" "ls" "wc")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少必要工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# ==============================================
# 克隆源码（确保完整且分支正确）
# ==============================================
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    # 强制删除旧目录，避免缓存干扰
    if [ -d "${OPENWRT_DIR}" ]; then
        echo "移除旧源码目录..." | tee -a "${LOG_FILE}"
        rm -rf "${OPENWRT_DIR}" || true
    fi
    
    # 克隆main分支（OpenWrt主线，设备支持最完整）
    echo "克隆OpenWrt主线分支（main）..." | tee -a "${LOG_FILE}"
    if ! git clone -b main --depth 5 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        echo "❌ 源码克隆失败（网络或仓库地址错误）" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证核心设备目录是否存在
    local missing=0
    for dir in "${DEVICE_CORE_DIRS[@]}"; do
        if [ ! -d "${dir}" ]; then
            echo "⚠️ 核心设备目录不存在: ${dir}" | tee -a "${LOG_FILE}"
            missing=1
        else
            # 统计目录下的文件数量（至少1个才正常）
            local file_count=$(find "${dir}" -type f | wc -l)
            echo "目录 ${dir} 包含 ${file_count} 个文件" | tee -a "${LOG_FILE}"
            if [ "${file_count}" -eq 0 ]; then
                echo "⚠️ 核心目录为空: ${dir}" | tee -a "${LOG_FILE}"
                missing=1
            fi
        fi
    done
    
    if [ "${missing}" -eq 1 ]; then
        echo "❌ 源码不完整，关键设备目录缺失或为空" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ 源码克隆完成，核心设备目录验证通过" | tee -a "${LOG_FILE}"
}

# ==============================================
# 抓取设备列表（精准提取，无兜底）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    # 1. 收集所有设备文件（遍历核心目录）
    local device_files=()
    for dir in "${DEVICE_CORE_DIRS[@]}"; do
        # 只找.dts（设备树）和.mk（配置文件）
        while IFS= read -r file; do
            device_files+=("${file}")
        done < <(find "${dir}" -type f \( -name "*.dts" -o -name "*.mk" \) 2>> "${LOG_FILE}")
    done
    
    # 2. 验证文件数量
    local file_count=${#device_files[@]}
    echo "找到 ${file_count} 个设备文件（核心目录）" | tee -a "${LOG_FILE}"
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 未找到任何设备文件，源码异常" | tee -a "${LOG_FILE}"
        exit 1
    fi
    # 输出前5个文件路径（调试用）
    echo "示例设备文件: ${device_files[@]:0:5}" | tee -a "${LOG_FILE}"
    
    # 3. 构建关键词正则（匹配源码格式）
    local keyword_regex="($(IFS=\|; echo "${DEVICE_KEYWORDS[*]}"))"
    
    # 4. 提取设备名称（精准匹配）
    local raw_devices
    for file in "${device_files[@]}"; do
        # 提取关键词后的设备名（移除引号和特殊符号）
        grep -E "${keyword_regex}" "${file}" 2>/dev/null | \
            sed -E \
                -e "s/${keyword_regex}//gi" \  # 移除关键词前缀（如DEVICE_NAME:="）
                -e "s/[\"';, ]//g" \          # 移除引号、分号等符号
                -e "s/^[[:space:]]*//g" \     # 移除前导空格
                -e "/^$/d"                    # 过滤空行
    done | sort -u > "${LOG_DIR}/raw-devices.tmp"
    
    # 5. 检查提取结果（禁止兜底）
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    echo "从源码中提取到 ${raw_count} 个设备名称" | tee -a "${LOG_FILE}"
    if [ "${raw_count}" -eq 0 ]; then
        echo "❌ 未提取到任何设备，匹配规则错误" | tee -a "${LOG_FILE}"
        # 输出首个文件内容片段（调试匹配规则）
        echo "首个文件内容（前10行）:" >> "${LOG_FILE}"
        head -n 10 "${device_files[0]}" >> "${LOG_FILE}"
        exit 1
    fi
    
    # 6. 输出最终结果（无兜底）
    cp "${LOG_DIR}/raw-devices.tmp" "${LOG_DIR}/final-devices.tmp"
    echo "✅ 最终设备列表生成（共 ${raw_count} 个，纯源码提取）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成JSON（修复jq命令问题）
# ==============================================
generate_device_json() {
    echo -e "\n===== 生成设备JSON =====" | tee -a "${LOG_FILE}"
    
    # 简化JSON生成，避免格式错误
    local devices_str=$(cat "${LOG_DIR}/final-devices.tmp" | tr '\n' ' ')
    jq -n \
        --arg devices "${devices_str}" \
        '{
            "devices": $devices | split(" ") | map(select(length > 0))
        }' > "${DEVICE_JSON}" || {
        echo "⚠️ jq命令失败，手动生成JSON" | tee -a "${LOG_FILE}"
        # 手动构建JSON数组（确保格式正确）
        echo '{"devices": [' > "${DEVICE_JSON}"
        sed 's/^/    "'"'"'/' "${LOG_DIR}/final-devices.tmp" | sed 's/$/"'"'",/' >> "${DEVICE_JSON}"
        sed -i '$ s/,$//' "${DEVICE_JSON}"  # 移除最后一个逗号
        echo ']}' >> "${DEVICE_JSON}"
    }
    
    # 验证JSON有效性
    if ! jq . "${DEVICE_JSON}" &> /dev/null; then
        echo "❌ JSON格式无效" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ ${DEVICE_JSON} 生成成功" | tee -a "${LOG_FILE}"
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
    echo "设备列表: ${DEVICE_JSON}（共 $(jq '.devices | length' "${DEVICE_JSON}") 个设备）"
}

main
