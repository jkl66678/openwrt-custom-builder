#!/bin/bash
set -uo pipefail  # 移除-e，避免单个文件错误终止整个脚本

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

# 错误捕获函数（记录具体错误位置）
log_error() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] ❌ 错误：$1（文件：$2，行号：$3）" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步流程
# ==============================================
log "========================================="
log "📌 工作目录：$WORK_DIR"
log "📌 输出文件：$OUTPUT_JSON"
log "📥 开始设备与芯片同步（增强错误捕获版）"
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
# 4. 提取设备信息（核心修复：增强错误捕获）
# ==============================================
log "🔍 开始提取设备信息（扩展文件类型+多规则）..."
declare -A PROCESSED_DEVICES
BATCH_SIZE=300
TMP_BATCH_DIR="$LOG_DIR/dts_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# 收集设备文件并记录总数
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

# 遍历批次文件（添加错误捕获）
for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    batch_name=$(basename "$batch_file")
    log "ℹ️ 开始处理批次：$batch_name（约$BATCH_SIZE个文件）"

    # 处理当前批次的每个文件（逐个捕获错误）
    while IFS= read -r file; do
        [ -f "$file" ] || { 
            log "⚠️ 跳过不存在的文件：$file"
            continue 
        }

        # 临时关闭严格模式，捕获文件处理错误
        set +e
        # 记录当前处理的文件，便于定位错误
        log "ℹ️ 正在处理文件：$file"
        file_ext=$(echo "$file" | awk -F '.' '{print $NF}')
        device_names=""
        model=""
        compatible=""
        chip_from_content=""

        # 根据文件类型解析（添加详细错误日志）
        case "$file_ext" in
            dts|dtsi)
                # 提取model字段（捕获grep错误）
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                if [ $? -ne 0 ]; then
                    log "⚠️ 文件 $file 中未找到model字段（可能正常）"
                fi
                # 提取compatible字段
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                device_names="$model $compatible"
                ;;
            mk)
                # 提取DEVICE_NAME等字段
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/DEVICE_NAME[[:space:]]*[:=][[:space:]]*//; s/SUPPORTED_DEVICES[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                if [ $? -ne 0 ]; then
                    log "⚠️ 文件 $file 中未找到设备字段（可能正常）"
                fi
                ;;
            *)
                log "⚠️ 跳过不支持的文件类型：$file"
                continue
                ;;
        esac

        # 解析芯片（双重来源）
        chip_from_content=$(grep -E 'SOC|CHIP' "$file" 2>> "$SYNC_LOG" | 
                           sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | head -n1)
        platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
        chip_from_dir=$(echo "$platform_path" | awk -F '/' '{print $2}')
        chip=${chip_from_content:-$chip_from_dir}
        chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g')

        # 处理设备名（去重+标准化）
        for name in $device_names; do
            [ -z "$name" ] && continue
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[_,]+/-/g; s/[^a-z0-9-]//g')
            [ -z "$device_name" ] && continue

            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                # 写入JSON（捕获jq错误）
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

# ==============================================
# 5. 提取芯片信息（复用优化逻辑）
# ==============================================
log "🔍 开始提取芯片信息..."
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
> "$CHIP_TMP_FILE"

# 合并设备和Makefile中的芯片
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq > "$LOG_DIR/chips_from_devices.tmp"
find "$TMP_SRC/target/linux" -name "Makefile" -exec grep -hE 'SOC_NAME|CONFIG_SOC' {} + 2>> "$SYNC_LOG" | 
    sed -E 's/.*(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+).*/\1/; t; d' | tr '[:upper:]' '[:lower:]' | sort | uniq >> "$LOG_DIR/chips_from_devices.tmp"
sort -u "$LOG_DIR/chips_from_devices.tmp" > "$LOG_DIR/all_chips.tmp"

# 处理芯片（添加错误捕获）
while read -r chip; do
    [ -z "$chip" ] && { log "⚠️ 跳过空芯片名"; continue; }
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')
    [ -z "$platforms" ] && platforms="unknown-platform"

    # 芯片驱动映射
    case "$chip" in
        mt7621) drivers='["kmod-mt7603e", "kmod-mt7615e"]' ;;
        mt7981|mt7986) drivers='["kmod-mt7981-firmware", "kmod-gmac"]' ;;
        ipq806x|ipq807x) drivers='["kmod-qca-nss-dp"]' ;;
        qca9563|qca9531) drivers='["kmod-ath9k"]' ;;
        *) drivers='[]' ;;
    esac

    # 写入芯片信息（捕获错误）
    if ! jq --arg name "$chip" \
            --arg p "$platforms"
