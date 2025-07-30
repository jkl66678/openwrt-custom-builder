#!/bin/bash
set -uo pipefail

# ==============================================
# 基础配置
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

mkdir -p "$LOG_DIR" || { echo "❌ 无法创建日志目录" >&2; exit 1; }
> "$SYNC_LOG"

log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步
# ==============================================
log "========================================="
log "📌 工作目录：$WORK_DIR"
log "📌 输出文件：$OUTPUT_JSON"
log "📥 开始OpenWrt设备同步（修复grep错误）"
log "========================================="

# ==============================================
# 1. 检查依赖
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失工具：$tool"
        exit 1
    fi
done
log "✅ 依赖齐全"

# ==============================================
# 2. 初始化JSON
# ==============================================
log "🔧 初始化配置文件..."
echo '{"devices": [], "chips": [], "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'"}}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建输出文件"
    exit 1
}

# ==============================================
# 3. 克隆源码
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆源码到临时目录：$TMP_SRC"

retries=5
while [ $retries -gt 0 ]; do
    if git clone --depth 10 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试：$retries"
    sleep 3
done

if [ $retries -eq 0 ]; then
    log "❌ 源码克隆失败"
    exit 1
fi

# ==============================================
# 4. 提取设备信息
# ==============================================
log "🔍 提取设备信息..."
declare -A PROCESSED_DEVICES
BATCH_SIZE=1000
TMP_BATCH_DIR="$LOG_DIR/device_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# 收集设备文件
log "ℹ️ 收集设备定义文件..."
find "$TMP_SRC/target/linux" \( -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \
    -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \
    -o -name "*.board" -o -name "*.profile" -o -name "*.list" \
    -o -name "*.json" -o -name "*.xml" \
    -o -path "*/profiles/*" -o -path "*/devices/*" \
    -o -name "config-*" -o -name "defconfig" \) > "$LOG_DIR/device_files.tmp"

total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
log "ℹ️ 共发现 $total_files 个设备文件"
if [ "$total_files" -eq 0 ]; then
    log "❌ 未找到设备文件"
    exit 1
fi

# 分批处理
split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"

for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    batch_name=$(basename "$batch_file")
    log "ℹ️ 处理批次：$batch_name"

    while IFS= read -r file; do
        [ -f "$file" ] || { log "⚠️ 跳过不存在文件：$file"; continue; }

        set +e
        file_ext=$(echo "$file" | awk -F '.' '{if (NF>1) print $NF; else print "none"}')
        device_names=""
        chip=""
        vendor=""

        case "$file_ext" in
            dts|dtsi|dtso)
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g; s/;.*//')
                device_names="$model $compatible"
                vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                chip=$(echo "$compatible" | sed -E 's/.*,[[:space:]]*([a-z0-9]+-[a-z0-9]+).*/\1/; s/^[a-z]+-//; t; d' | head -n1)
                ;;

            mk|Makefile)
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d')
                chip=$(grep -E 'SOC[[:space:]]*[:=]' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/.*(mt|ipq|qca|rtl|ath)[0-9a-z-]*/\1/; t; d')
                ;;

            conf|config)
                device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g')
                chip=$(grep -E '^CONFIG_ARCH' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/CONFIG_ARCH_//; s/=y//; t; d')
                ;;

            *)
                device_names=$(grep -E 'name|model' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/(name|model)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                ;;
        esac

        # 补充芯片信息
        platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
        chip_from_dir=$(echo "$platform_path" | awk -F '/' '{print $1}')
        chip=${chip:-$chip_from_dir}
        chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g')

        # 处理设备名（修复sed正则）
        for name in $device_names; do
            [ -z "$name" ] && continue
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | 
                         sed -E 's/[_,:;\/]+/-/g; s/[^a-z0-9 -]//g; s/[[:space:]]+/-/g; s/--+/-/g; s/^-+//; s/-+$//')
            [ -z "$device_name" ] && continue

            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                if ! jq --arg name "$device_name" \
                        --arg chip "$chip" \
                        --arg vendor "$vendor" \
                        --arg kt "$platform_path" \
                        '.devices += [{"name": $name, "chip": $chip, "vendor": $vendor, "kernel_target": $kt, "drivers": []}]' \
                        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
                    log "⚠️ 设备 $device_name 写入失败"
                    continue
                fi
                mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                log "ℹ️ 提取设备：$device_name（芯片：$chip）"
            fi
        done
        set -uo pipefail
    done < "$batch_file"
    log "ℹ️ 批次 $batch_name 处理完成"
done

rm -f "$LOG_DIR/device_files.tmp"

# 验证设备提取结果
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$device_count" -eq 0 ]; then
    log "❌ 未提取到任何设备"
    exit 1
fi
log "✅ 设备提取完成，共 $device_count 个"

# ==============================================
# 5. 提取芯片信息（核心修复：正则表达式括号问题）
# ==============================================
log "🔍 提取芯片信息..."
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
> "$CHIP_TMP_FILE"

# ==============================================
# 修复点1：将正则表达式改为单行，确保括号正确闭合
# 移除多行格式，避免grep解析时出现括号不匹配
# ==============================================
VALID_CHIP_REGEX='^(mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+|ath[0-9]+|bcm[0-9]+|sun[0-9]+|exynos[0-9]+|imx[0-9]+|x86|i386|amd64|x86_64|ppc|powerpc|mips|mipsel|arm|arm64|aarch64|riscv|riscv64|mediatek|qualcomm|broadcom|allwinner|rockchip|nvidia)$'

# ==============================================
# 修复点2：拆分管道命令，避免Broken pipe错误
# 先将结果保存到临时文件，再进行后续处理
# ==============================================
# 从设备中提取芯片
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq > "$LOG_DIR/chips_step1.tmp"
# 过滤有效芯片
grep -E "$VALID_CHIP_REGEX" "$LOG_DIR/chips_step1.tmp" > "$LOG_DIR/chips_from_devices.tmp"

# 从Makefile补充芯片
find "$TMP_SRC/target/linux" -name "Makefile" -exec grep -hE 'ARCH|SOC|CPU' {} + 2>> "$SYNC_LOG" | \
    sed -E 's/.*(mt|ipq|qca|rtl|ath|bcm|sun|exynos|imx|x86|ppc|mips|arm|riscv|mediatek|qualcomm).*/\1/; t; d' | \
    tr '[:upper:]' '[:lower:]' | sort | uniq > "$LOG_DIR/chips_step2.tmp"
# 过滤有效芯片
grep -E "$VALID_CHIP_REGEX" "$LOG_DIR/chips_step2.tmp" >> "$LOG_DIR/chips_from_devices.tmp"

# 合并去重
sort -u "$LOG_DIR/chips_from_devices.tmp" > "$LOG_DIR/all_chips.tmp"

# 验证芯片提取结果
chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
if [ "$chip_count_total" -eq 0 ]; then
    log "❌ 未提取到任何有效芯片信息"
    exit 1
fi

# 处理每个芯片
while read -r chip; do
    [ -z "$chip" ] && { log "⚠️ 跳过空芯片名"; continue; }
    if ! echo "$chip" | grep -qE "$VALID_CHIP_REGEX"; then
        log "⚠️ 过滤无效芯片：$chip"
        continue
    fi
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')
    [ -z "$platforms" ] && platforms="unknown"

    vendors=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
              sort | uniq | tr '\n' ',' | sed 's/,$//')

    # 芯片驱动映射
    case "$chip" in
        mt*|mediatek*) drivers='["kmod-mt76", "kmod-rtc-mt6397"]' ;;
        ipq*|qca*|qualcomm*) drivers='["kmod-ath10k", "kmod-qca-nss-dp"]' ;;
        bcm*|broadcom*) drivers='["kmod-brcm-wl", "kmod-brcmutil"]' ;;
        sun*|allwinner*) drivers='["kmod-sunxi-mmc", "kmod-rtc-sunxi"]' ;;
        x86|i386|amd64|x86_64) drivers='["kmod-e1000", "kmod-ahci", "kmod-r8169"]' ;;
        arm|arm64|aarch64) drivers='["kmod-armada-37xx", "kmod-i2c-arm"]' ;;
        mips*) drivers='["kmod-mt7603", "kmod-switch-rtl8366"]' ;;
        riscv*) drivers='["kmod-riscv-timer", "kmod-serial-8250"]' ;;
        *) drivers='[]' ;;
    esac

    # 写入芯片信息
    if ! jq --arg name "$chip" \
            --arg p "$platforms" \
            --arg v "$vendors" \
            --argjson d "$drivers" \
            '.chips += [{"name": $name, "platforms": $p, "vendors": $v, "default_drivers": $d}]' \
            "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
        log "⚠️ 芯片 $chip 写入失败（跳过）"
        continue
    fi
    mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" && echo "$chip" >> "$CHIP_TMP_FILE"
    log "ℹ️ 提取芯片：$chip（支持厂商：$vendors）"
done < "$LOG_DIR/all_chips.tmp"

# 清理临时文件
rm -f "$CHIP_TMP_FILE" "$LOG_DIR/chips_from_devices.tmp" "$LOG_DIR/all_chips.tmp" \
      "$LOG_DIR/chips_step1.tmp" "$LOG_DIR/chips_step2.tmp"

# 验证芯片结果
final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$final_chip_count" -eq 0 ]; then
    log "❌ 芯片信息提取失败"
    exit 1
fi
log "✅ 芯片提取完成，共 $final_chip_count 个芯片"

# ==============================================
# 6. 补充设备驱动
# ==============================================
log "🔧 为设备补充驱动..."
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
# 7. 清理与完成
# ==============================================
rm -rf "$TMP_SRC" "$TMP_BATCH_DIR"
log "========================================="
log "✅ OpenWrt设备同步完成"
log "📊 最终统计：设备 $device_count 个，芯片 $final_chip_count 个"
log "📄 配置文件：$OUTPUT_JSON"
log "📄 日志：$SYNC_LOG"
log "========================================="
