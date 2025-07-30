#!/bin/bash
set -uo pipefail

# ==============================================
# 基础配置与初始化
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

# 日志函数
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
log "📥 开始设备与芯片同步（移除第7步兜底）"
log "========================================="

# ==============================================
# 1. 检查依赖工具
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
# 3. 克隆OpenWrt源码
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
# 4. 提取设备信息
# ==============================================
log "🔍 开始提取设备信息（仅源码提取）..."
declare -A PROCESSED_DEVICES
BATCH_SIZE=300
TMP_BATCH_DIR="$LOG_DIR/dts_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# 收集设备文件
log "ℹ️ 收集设备定义文件（.dts/.dtsi/.mk/profiles.mk）..."
find "$TMP_SRC/target/linux" \( \
    -name "*.dts" -o -name "*.dtsi" -o -name "devices.mk" -o -name "profiles.mk" \
\) > "$LOG_DIR/device_files.tmp"
total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
log "ℹ️ 共发现 $total_files 个设备相关文件"
if [ "$total_files" -eq 0 ]; then
    log "❌ 未找到任何设备文件，源码异常"
    exit 1
fi

# 分批处理
split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"

# 遍历批次文件
for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    batch_name=$(basename "$batch_file")
    log "ℹ️ 开始处理批次：$batch_name（约$BATCH_SIZE个文件）"

    # 处理当前批次的每个文件
    while IFS= read -r file; do
        [ -f "$file" ] || { 
            log "⚠️ 跳过不存在的文件：$file"
            continue 
        }

        set +e  # 临时关闭严格模式
        file_ext=$(echo "$file" | awk -F '.' '{print $NF}')
        device_names=""
        model=""
        compatible=""

        case "$file_ext" in
            dts|dtsi)
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                device_names="$model $compatible"
                ;;
            mk)
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/DEVICE_NAME[[:space:]]*[:=][[:space:]]*//; s/SUPPORTED_DEVICES[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                ;;
            *)
                log "⚠️ 跳过不支持的文件类型：$file"
                continue
                ;;
        esac

        # 解析芯片
        chip_from_content=$(grep -E 'SOC|CHIP' "$file" 2>> "$SYNC_LOG" | 
                           sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | head -n1)
        platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
        chip_from_dir=$(echo "$platform_path" | awk -F '/' '{print $2}')
        chip=${chip_from_content:-$chip_from_dir}
        chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g')

        # 处理设备名
        for name in $device_names; do
            [ -z "$name" ] && continue
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[_,]+/-/g; s/[^a-z0-9-]//g')
            [ -z "$device_name" ] && continue

            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                if ! jq --arg name "$device_name" \
                        --arg chip "$chip" \
                        --arg kt "$platform_path" \
                        --arg file "$(basename "$file")" \
                        '.devices += [{"name": $name, "chip": $chip, "kernel_target": $kt, "source": $file, "drivers": []}]' \
                        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
                    log "⚠️ 设备 $device_name 写入JSON失败（跳过）"
                    rm -f "$OUTPUT_JSON.tmp"
                    continue
                fi
                mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                log "ℹ️ 提取设备：$device_name（芯片：$chip，来源：$(basename "$file")）"
            fi
        done
        set -uo pipefail  # 恢复严格模式
    done < "$batch_file"
    log "ℹ️ 批次 $batch_name 处理完成"
done

rm -f "$LOG_DIR/device_files.tmp"

# 验证设备提取结果（数量为0时报错）
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$device_count" -eq 0 ]; then
    log "❌ 未从源码中提取到任何设备，同步失败"
    exit 1
fi
log "✅ 设备提取完成，共 $device_count 个设备"

# ==============================================
# 5. 提取芯片信息
# ==============================================
log "🔍 开始提取芯片信息（仅源码提取）..."
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
> "$CHIP_TMP_FILE"

# 合并芯片来源
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq > "$LOG_DIR/chips_from_devices.tmp"
find "$TMP_SRC/target/linux" -name "Makefile" -exec grep -hE 'SOC_NAME|CONFIG_SOC' {} + 2>> "$SYNC_LOG" | 
    sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | tr '[:upper:]' '[:lower:]' | sort | uniq >> "$LOG_DIR/chips_from_devices.tmp"
sort -u "$LOG_DIR/chips_from_devices.tmp" > "$LOG_DIR/all_chips.tmp"

# 验证芯片提取结果（数量为0时报错）
chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
if [ "$chip_count_total" -eq 0 ]; then
    log "❌ 未从源码中提取到任何芯片，同步失败"
    exit 1
fi

# 处理每个芯片
while read -r chip; do
    [ -z "$chip" ] && { log "⚠️ 跳过空芯片名"; continue; }
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')
    [ -z "$platforms" ] && platforms=""

    # 芯片驱动映射
    case "$chip" in
        mt7621) drivers='["kmod-mt7603e", "kmod-mt7615e"]' ;;
        mt7981|mt7986) drivers='["kmod-mt7981-firmware", "kmod-gmac"]' ;;
        ipq806x|ipq807x) drivers='["kmod-qca-nss-dp"]' ;;
        qca9563|qca9531) drivers='["kmod-ath9k"]' ;;
        *) drivers='[]' ;;
    esac

    # 写入芯片信息
    if ! jq --arg name "$chip" \
            --arg p "$platforms" \
            --argjson d "$drivers" \
            '.chips += [{"name": $name, "platforms": $p, "default_drivers": $d}]' \
            "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
        log "⚠️ 芯片 $chip 写入JSON失败（跳过）"
        continue
    fi
    mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" && echo "$chip" >> "$CHIP_TMP_FILE"
    log "ℹ️ 提取芯片：$chip（关联平台：$platforms）"
done < "$LOG_DIR/all_chips.tmp"

# 清理芯片临时文件
rm -f "$CHIP_TMP_FILE" "$LOG_DIR/chips_from_devices.tmp" "$LOG_DIR/all_chips.tmp"

# 验证芯片最终结果
final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$final_chip_count" -eq 0 ]; then
    log "❌ 芯片信息提取失败，同步终止"
    exit 1
fi
log "✅ 芯片提取完成，共 $final_chip_count 个芯片"

# ==============================================
# 6. 补充设备驱动
# ==============================================
log "🔧 为设备补充芯片对应的驱动..."
jq -c '.devices[]' "$OUTPUT_JSON" | while read -r device; do
    device_name=$(echo "$device" | jq -r '.name')
    chip=$(echo "$device" | jq -r '.chip')
    drivers=$(jq --arg c "$chip" '.chips[] | select(.name == $c) | .default_drivers' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | head -n1)
    [ "$drivers" = "null" ] && drivers='[]'

    jq --arg name "$device_name" \
       --argjson d "$drivers" \
       '.devices[] |= (if .name == $name then .drivers = $d else . end)' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
done

# ==============================================
# （已移除第7步：不再补充默认设备/芯片）
# ==============================================

# ==============================================
# 8. 清理与完成
# ==============================================
rm -rf "$TMP_SRC" "$TMP_BATCH_DIR"
log "========================================="
log "✅ 同步完成（已移除第7步兜底）"
log "📊 最终统计：设备 $device_count 个，芯片 $final_chip_count 个"
log "📄 配置文件路径：$OUTPUT_JSON"
log "📄 详细日志路径：$SYNC_LOG"
log "========================================="
