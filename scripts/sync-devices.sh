#!/bin/bash
set -euo pipefail

# ==============================================
# 基础配置与初始化（保留原结构）
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2
    exit 1
}
> "$SYNC_LOG"

# 日志函数（保持原逻辑）
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步流程
# ==============================================
log "========================================="
log "📌 工作目录：$WORK_DIR"
log "📌 输出文件：$OUTPUT_JSON"
log "📥 开始设备与芯片同步（增强提取版）"
log "========================================="

# ==============================================
# 1. 检查依赖工具（补充必要工具）
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc" "tr" "sort" "uniq")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失必要工具：$tool"
        exit 1
    fi
done
log "✅ 所有依赖工具已安装"

# ==============================================
# 2. 初始化输出JSON文件
# ==============================================
log "🔧 初始化配置文件..."
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建输出文件 $OUTPUT_JSON（权限问题）"
    exit 1
}

# ==============================================
# 3. 克隆OpenWrt源码（保留重试机制）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码到临时目录：$TMP_SRC"

retries=3
while [ $retries -gt 0 ]; do
    if git clone --depth 3 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试次数：$retries"
    sleep 3
done

if [ $retries -eq 0 ]; then
    log "❌ 源码克隆失败（已重试3次）"
    exit 1
fi

# ==============================================
# 4. 提取设备信息（核心优化：扩展文件范围+多规则解析）
# ==============================================
log "🔍 开始提取设备信息（扩展文件类型+多规则）..."
declare -A PROCESSED_DEVICES
BATCH_SIZE=300
TMP_BATCH_DIR="$LOG_DIR/dts_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# 核心优化1：扩展设备文件类型（不仅限于.dts）
log "ℹ️ 收集设备定义文件（.dts/.dtsi/.mk/profiles.mk）..."
find "$TMP_SRC/target/linux" \( \
    -name "*.dts" -o -name "*.dtsi" -o -name "devices.mk" -o -name "profiles.mk" \
\) > "$LOG_DIR/device_files.tmp"  # 保存所有设备相关文件

# 分批处理所有设备文件
split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"

for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    log "ℹ️ 处理批次：$(basename "$batch_file")（约$BATCH_SIZE个文件）"

    while read -r file; do
        [ -f "$file" ] || { log "⚠️ 跳过不存在的文件：$file"; continue; }
        file_ext=$(echo "$file" | awk -F '.' '{print $NF}')  # 文件后缀

        # 核心优化2：根据文件类型使用不同解析规则
        case "$file_ext" in
            dts|dtsi)
                # .dts/.dtsi文件：从model和compatible字段提取
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>/dev/null | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>/dev/null | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                device_names="$model $compatible"
                ;;
            mk)
                # .mk文件：从DEVICE_NAME和SUPPORTED_DEVICES提取
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>/dev/null | 
                              sed -E 's/DEVICE_NAME[[:space:]]*[:=][[:space:]]*//; s/SUPPORTED_DEVICES[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                ;;
        esac

        # 提取设备名并去重
        for name in $device_names; do
            [ -z "$name" ] && continue
            # 标准化设备名（替换特殊字符，统一格式）
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[_,]+/-/g; s/[^a-z0-9-]//g')
            [ -z "$device_name" ] && continue

            # 解析芯片和平台（优化目录+字段双重提取）
            platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
            # 从文件内容提取芯片（优先于目录）
            chip_from_content=$(grep -E 'SOC|CHIP' "$file" 2>/dev/null | 
                               sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | head -n1)
            # 从目录提取芯片（兜底）
            chip_from_dir=$(echo "$platform_path" | awk -F '/' '{print $2}')
            chip=${chip_from_content:-$chip_from_dir}
            chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g')  # 标准化芯片名

            # 去重处理
            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                # 写入设备信息（包含更多细节）
                jq --arg name "$device_name" \
                   --arg chip "$chip" \
                   --arg kt "$platform_path" \
                   --arg file "$(basename "$file")" \
                   '.devices += [{"name": $name, "chip": $chip, "kernel_target": $kt, "source": $file, "drivers": []}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                log "ℹ️ 提取设备：$device_name（芯片：$chip，来源：$(basename "$file")）"
            fi
        done
    done < "$batch_file"
done

rm -f "$LOG_DIR/device_files.tmp"

# ==============================================
# 5. 提取芯片信息（核心优化：多来源识别+去重增强）
# ==============================================
log "🔍 开始提取芯片信息（多来源验证）..."
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
> "$CHIP_TMP_FILE"

# 核心优化3：从设备列表+源码Makefile双重提取芯片
log "ℹ️ 从设备和Makefile中收集芯片..."
# 1. 从设备列表提取芯片
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq > "$LOG_DIR/chips_from_devices.tmp"
# 2. 从Makefile提取芯片（补充遗漏）
find "$TMP_SRC/target/linux" -name "Makefile" -exec grep -hE 'SOC_NAME|CONFIG_SOC' {} + 2>> "$SYNC_LOG" | 
    sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | tr '[:upper:]' '[:lower:]' | sort | uniq >> "$LOG_DIR/chips_from_devices.tmp"

# 合并去重
sort -u "$LOG_DIR/chips_from_devices.tmp" > "$LOG_DIR/all_chips.tmp"

# 处理每个芯片，关联平台和驱动
while read -r chip; do
    [ -z "$chip" ] && { log "⚠️ 跳过空芯片名"; continue; }
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    # 核心优化4：关联多个平台（而非仅第一个）
    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')  # 逗号分隔多个平台
    [ -z "$platforms" ] && platforms="unknown-platform"

    # 补充芯片对应的默认驱动（扩展覆盖范围）
    case "$chip" in
        mt7621) drivers='["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s"]' ;;
        mt7981|mt7986) drivers='["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3"]' ;;
        ipq806x|ipq807x) drivers='["kmod-qca-nss-dp", "kmod-qca-nss-ecm"]' ;;
        qca9563|qca9531) drivers='["kmod-ath9k", "kmod-ath10k"]' ;;
        rtl8367|rtl8366) drivers='["kmod-switch-rtl8367", "kmod-rtl8367b"]' ;;
        *) drivers='[]' ;;
    esac

    # 写入芯片信息
    if ! jq --arg name "$chip" \
            --arg p "$platforms" \
            --argjson d "$drivers" \
            '.chips += [{"name": $name, "platforms": $p, "default_drivers": $d}]' \
            "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
        log "❌ 芯片 $chip 写入失败，跳过"
        continue
    fi
    mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" && echo "$chip" >> "$CHIP_TMP_FILE"
    log "ℹ️ 提取芯片：$chip（关联平台：$platforms）"
done < "$LOG_DIR/all_chips.tmp"

rm -f "$CHIP_TMP_FILE" "$LOG_DIR/chips_from_devices.tmp" "$LOG_DIR/all_chips.tmp"

# ==============================================
# 6. 补充设备驱动（基于芯片匹配）
# ==============================================
log "🔧 为设备补充芯片对应的驱动..."
# 遍历设备，根据芯片关联驱动
jq -c '.devices[]' "$OUTPUT_JSON" | while read -r device; do
    device_name=$(echo "$device" | jq -r '.name')
    chip=$(echo "$device" | jq -r '.chip')
    # 从芯片列表获取默认驱动
    drivers=$(jq --arg c "$chip" '.chips[] | select(.name == $c) | .default_drivers' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | head -n1)
    [ "$drivers" = "null" ] && drivers='[]'

    # 更新设备的驱动列表
    jq --arg name "$device_name" \
       --argjson d "$drivers" \
       '.devices[] |= (if .name == $name then .drivers = $d else . end)' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
done

# ==============================================
# 7. 兜底机制（保留但降低触发概率）
# ==============================================
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

if [ "$device_count" -lt 5 ] || [ "$chip_count" -lt 3 ]; then  # 降低阈值，减少兜底触发
    log "⚠️ 提取数据较少，补充默认设备和芯片"
    # 补充常见设备
    jq '.devices += [
        {"name": "cudy-tr3000", "chip": "mt7981", "kernel_target": "mediatek/mt7981", "drivers": ["kmod-mt7981-firmware"]},
        {"name": "xiaomi-ax3600", "chip": "ipq8074", "kernel_target": "ipq807x", "drivers": ["kmod-qca-nss-dp"]}
    ]' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    # 补充常见芯片
    jq '.chips += [
        {"name": "mt7981", "platforms": "mediatek/mt7981", "default_drivers": ["kmod-mt7981-firmware"]},
        {"name": "ipq8074", "platforms": "ipq807x", "default_drivers": ["kmod-qca-nss-dp"]}
    ]' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    device_count=$(jq '.devices | length' "$OUTPUT_JSON")
    chip_count=$(jq '.chips | length' "$OUTPUT_JSON")
fi

# ==============================================
# 8. 清理与完成
# ==============================================
rm -rf "$TMP_SRC" "$TMP_BATCH_DIR"
log "========================================="
log "✅ 同步完成（增强版）"
log "📊 统计结果：设备 $device_count 个，芯片 $chip_count 个"
log "📄 配置文件路径：$OUTPUT_JSON"
log "📄 详细日志路径：$SYNC_LOG"
log "========================================="
