#!/bin/bash
set -uo pipefail

# ==============================================
# 配置参数（同时包含设备和芯片）
# ==============================================
LOG_DIR="sync-logs"
LOG_FILE="${LOG_DIR}/sync-detail.log"
DEVICE_JSON="device-drivers.json"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_DIR="openwrt-source"

# 设备相关配置
DEVICE_CORE_DIRS=(
    "${OPENWRT_DIR}/target/linux/ath79/dts"
    "${OPENWRT_DIR}/target/linux/ramips/dts"
    "${OPENWRT_DIR}/target/linux/mediatek/dts"
    "${OPENWRT_DIR}/target/linux/x86/profiles"
)
DEVICE_KEYWORDS=(
    "DEVICE_NAME[:=][[:space:]]*[\"']"
    "model[[:space:]]*=[[:space:]]*[\"']"
    "SUPPORTED_DEVICES[[:=][:space:]]*"
)

# 芯片相关配置（新增）
CHIP_CORE_DIRS=(
    "${OPENWRT_DIR}/target/linux/*/Makefile"  # 芯片架构定义
    "${OPENWRT_DIR}/target/linux/*/config-*"  # 芯片配置文件
    "${OPENWRT_DIR}/package/kernel/linux/modules/"  # 内核模块中的芯片驱动
)
CHIP_KEYWORDS=(
    "CONFIG_SOC_|CONFIG_MT|CONFIG_ATH"  # 联发科、高通等芯片的配置关键词
    "SOC_NAME[[:=][:space:]]*"         # 芯片名称定义
    "mt7981|mt7621|ipq8074|qca9563"    # 常见芯片型号
)

# ==============================================
# 初始化环境
# ==============================================
init() {
    echo "===== 初始化同步环境 ====="
    mkdir -p "${LOG_DIR}"
    > "${LOG_FILE}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始设备和芯片同步" >> "${LOG_FILE}"
    
    local required_tools=("git" "jq" "grep" "sed" "find" "ls" "wc")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            echo "❌ 缺少工具: ${tool}" | tee -a "${LOG_FILE}"
            exit 1
        fi
    done
    echo "✅ 所有依赖工具已安装" | tee -a "${LOG_FILE}"
}

# ==============================================
# 克隆源码
# ==============================================
update_openwrt_source() {
    echo -e "\n===== 处理OpenWrt源码 =====" | tee -a "${LOG_FILE}"
    
    [ -d "${OPENWRT_DIR}" ] && rm -rf "${OPENWRT_DIR}"
    
    echo "克隆OpenWrt主线分支..." | tee -a "${LOG_FILE}"
    if ! git clone -b main --depth 5 "${OPENWRT_REPO}" "${OPENWRT_DIR}" >> "${LOG_FILE}" 2>&1; then
        echo "❌ 源码克隆失败" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 验证设备和芯片目录
    local missing=0
    for dir in "${DEVICE_CORE_DIRS[@]}" "${CHIP_CORE_DIRS[@]}"; do
        # 处理通配符目录（如*）
        expanded_dirs=$(ls -d ${dir} 2>/dev/null || true)
        if [ -z "${expanded_dirs}" ]; then
            echo "⚠️ 核心目录缺失: ${dir}" | tee -a "${LOG_FILE}"
            missing=1
        fi
    done
    if [ "${missing}" -eq 1 ]; then
        echo "❌ 源码不完整" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ 源码克隆完成" | tee -a "${LOG_FILE}"
}

# ==============================================
# 抓取设备列表（复用之前的逻辑）
# ==============================================
fetch_devices() {
    echo -e "\n===== 抓取设备列表 =====" | tee -a "${LOG_FILE}"
    
    local device_files=()
    for dir in "${DEVICE_CORE_DIRS[@]}"; do
        while IFS= read -r file; do
            device_files+=("${file}")
        done < <(find "${dir}" -type f \( -name "*.dts" -o -name "*.mk" \) 2>> "${LOG_FILE}")
    done
    
    local file_count=${#device_files[@]}
    echo "找到 ${file_count} 个设备文件" | tee -a "${LOG_FILE}"
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 未找到设备文件" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    local keyword_regex="($(IFS=\|; echo "${DEVICE_KEYWORDS[*]}"))"
    local raw_devices
    for file in "${device_files[@]}"; do
        grep -E "${keyword_regex}" "${file}" 2>/dev/null | \
            sed -E \
                -e "s/${keyword_regex}//gi" \
                -e "s/[\"';, ]//g" \
                -e "s/^[[:space:]]*//g" \
                -e "/^$/d"
    done | sort -u > "${LOG_DIR}/raw-devices.tmp"
    
    local raw_count=$(wc -l < "${LOG_DIR}/raw-devices.tmp")
    echo "提取到 ${raw_count} 个设备" | tee -a "${LOG_FILE}"
    if [ "${raw_count}" -eq 0 ]; then
        echo "❌ 未提取到设备" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    cp "${LOG_DIR}/raw-devices.tmp" "${LOG_DIR}/final-devices.tmp"
    echo "✅ 设备列表生成（共 ${raw_count} 个）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 抓取芯片列表（新增逻辑）
# ==============================================
fetch_chips() {
    echo -e "\n===== 抓取芯片列表 =====" | tee -a "${LOG_FILE}"
    
    # 收集芯片相关文件
    local chip_files=()
    for dir in "${CHIP_CORE_DIRS[@]}"; do
        # 处理含通配符的目录（如*）
        while IFS= read -r expanded_dir; do
            while IFS= read -r file; do
                chip_files+=("${file}")
            done < <(find "${expanded_dir}" -type f 2>> "${LOG_FILE}")
        done < <(ls -d ${dir} 2>/dev/null)
    done
    
    local file_count=${#chip_files[@]}
    echo "找到 ${file_count} 个芯片相关文件" | tee -a "${LOG_FILE}"
    if [ "${file_count}" -eq 0 ]; then
        echo "❌ 未找到芯片文件" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    # 提取芯片型号
    local keyword_regex="($(IFS=\|; echo "${CHIP_KEYWORDS[*]}"))"
    local raw_chips
    for file in "${chip_files[@]}"; do
        grep -Eo "${keyword_regex}[a-z0-9]+" "${file}" 2>/dev/null | \
            sed -E \
                -e "s/CONFIG_//g" \  # 移除配置前缀
                -e "s/SOC_NAME[:=]//gi" \
                -e "s/^[[:space:]]*//g" \
                -e "s/[^a-z0-9]//g" \  # 保留字母和数字
                -e "/^$/d"
    done | sort -u > "${LOG_DIR}/raw-chips.tmp"
    
    local raw_count=$(wc -l < "${LOG_DIR}/raw-chips.tmp")
    echo "提取到 ${raw_count} 个芯片" | tee -a "${LOG_FILE}"
    if [ "${raw_count}" -eq 0 ]; then
        echo "❌ 未提取到芯片" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    cp "${LOG_DIR}/raw-chips.tmp" "${LOG_DIR}/final-chips.tmp"
    echo "✅ 芯片列表生成（共 ${raw_count} 个）" | tee -a "${LOG_FILE}"
}

# ==============================================
# 生成包含设备和芯片的JSON
# ==============================================
generate_json() {
    echo -e "\n===== 生成设备和芯片JSON =====" | tee -a "${LOG_FILE}"
    
    # 同时处理设备和芯片
    local devices_str=$(cat "${LOG_DIR}/final-devices.tmp" | tr '\n' ' ')
    local chips_str=$(cat "${LOG_DIR}/final-chips.tmp" | tr '\n' ' ')
    
    if ! jq -n \
        --arg devices "${devices_str}" \
        --arg chips "${chips_str}" \
        '{
            "devices": $devices | split(" ") | map(select(length > 0)),
            "chips": $chips | split(" ") | map(select(length > 0))
        }' > "${DEVICE_JSON}" 2>> "${LOG_FILE}"; then
        echo "⚠️ jq失败，手动生成JSON" | tee -a "${LOG_FILE}"
        # 手动构建包含设备和芯片的JSON
        echo '{"devices": [' > "${DEVICE_JSON}"
        sed 's/^/    "/; s/$/"/' "${LOG_DIR}/final-devices.tmp" | sed '$!s/$/,/' >> "${DEVICE_JSON}"
        echo '  ],' >> "${DEVICE_JSON}"
        echo '  "chips": [' >> "${DEVICE_JSON}"
        sed 's/^/    "/; s/$/"/' "${LOG_DIR}/final-chips.tmp" | sed '$!s/$/,/' >> "${DEVICE_JSON}"
        echo '  ]}' >> "${DEVICE_JSON}"
    fi
    
    if ! jq . "${DEVICE_JSON}" &> /dev/null; then
        echo "❌ JSON格式无效" | tee -a "${LOG_FILE}"
        exit 1
    fi
    
    echo "✅ ${DEVICE_JSON} 生成成功" | tee -a "${LOG_FILE}"
}

# ==============================================
# 主流程（同时执行设备和芯片提取）
# ==============================================
main() {
    init
    update_openwrt_source
    fetch_devices
    fetch_chips  # 新增芯片提取步骤
    generate_json
    
    echo -e "\n===== 同步完成 =====" | tee -a "${LOG_FILE}"
    echo "设备数量: $(jq '.devices | length' "${DEVICE_JSON}")"
    echo "芯片数量: $(jq '.chips | length' "${DEVICE_JSON}")"
    echo "详细日志: ${LOG_FILE}"
}

main
