#!/bin/bash
set -uo pipefail

# ==============================================
# 基础配置（全设备支持）
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

# 创建日志目录
mkdir -p "$LOG_DIR" || { echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2; exit 1; }
> "$SYNC_LOG"  # 清空日志

# 日志函数（带时间戳）
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
log "📥 开始OpenWrt全设备同步（覆盖所有架构/厂商）"
log "========================================="

# ==============================================
# 1. 检查依赖工具（全设备处理依赖）
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc" "tr" "sort" "uniq" "file")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失必要工具：$tool（请先安装）"
        exit 1
    fi
done
log "✅ 所有依赖工具已安装"

# ==============================================
# 2. 初始化输出JSON（确保结构正确）
# ==============================================
log "🔧 初始化设备配置文件..."
echo '{"devices": [], "chips": [], "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'", "source": "OpenWrt official repo"}}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建输出文件 $OUTPUT_JSON（权限问题）"
    exit 1
}

# ==============================================
# 3. 克隆OpenWrt源码（包含所有设备定义）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码（全设备支持）到临时目录：$TMP_SRC"

# 增加克隆深度，确保获取所有设备定义文件
retries=5
while [ $retries -gt 0 ]; do
    if git clone --depth 10 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试次数：$retries（3秒后重试）"
    sleep 3
done

if [ $retries -eq 0 ]; then
    log "❌ 源码克隆失败（已重试5次）"
    exit 1
fi

# ==============================================
# 4. 提取设备信息（全设备适配核心逻辑）
# ==============================================
log "🔍 开始提取全设备信息（覆盖所有架构/厂商）..."
declare -A PROCESSED_DEVICES  # 去重哈希表
BATCH_SIZE=1000  # 大批次处理，适应大量设备文件
TMP_BATCH_DIR="$LOG_DIR/device_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# ==============================================
# 4.1 收集所有可能的设备定义文件（关键：扩大扫描范围）
# ==============================================
log "ℹ️ 收集设备定义文件（全类型）..."
find "$TMP_SRC/target/linux" \( \
    -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \                   # 设备树文件（主流架构）
    -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \              # 构建配置文件
    -o -name "*.board" -o -name "*.profile" -o -name "*.list" \          # 设备列表文件
    -o -name "*.json" -o -name "*.xml" \                                # 结构化配置文件
    -o -path "*/profiles/*" -o -path "*/devices/*" \                    # 设备专用目录
    -o -name "config-*" -o -name "defconfig"                            # 配置文件
\) > "$LOG_DIR/device_files.tmp"

total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
log "ℹ️ 共发现 $total_files 个潜在设备定义文件"
if [ "$total_files" -eq 0 ]; then
    log "❌ 未找到任何设备文件，源码可能损坏"
    exit 1
fi

# ==============================================
# 4.2 分批处理设备文件（避免内存溢出）
# ==============================================
split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"

# 遍历所有批次
for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    batch_name=$(basename "$batch_file")
    log "ℹ️ 开始处理批次：$batch_name（约$BATCH_SIZE个文件）"

    # 处理批次中的每个文件
    while IFS= read -r file; do
        [ -f "$file" ] || { log "⚠️ 跳过不存在的文件：$file"; continue; }

        # 临时关闭严格模式，避免单个文件错误终止整个流程
        set +e
        file_path=$(realpath "$file")
        file_type=$(file -b "$file" | cut -d ',' -f1)  # 识别文件类型（文本/二进制）
        file_ext=$(echo "$file" | awk -F '.' '{if (NF>1) print $NF; else print "none"}')
        device_names=""
        chip=""
        vendor=""  # 新增厂商信息

        # ==============================================
        # 4.3 按文件类型提取设备信息（多规则适配）
        # ==============================================
        case "$file_ext" in
            # 设备树文件（ARM/MIPS/ RISCV等架构）
            dts|dtsi|dtso)
                # 提取设备名（model字段，支持多语言和特殊字符）
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//; s/[[:space:]]+/ /g')
                # 提取兼容列表（compatible字段，可能包含厂商信息）
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g; s/;.*//')
                device_names="$model $compatible"
                # 提取厂商（compatible中的第一个字段，如"xiaomi,redmi-router-ax6" → "xiaomi"）
                vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                # 提取芯片（compatible中的芯片型号，如"mediatek,mt7986" → "mt7986"）
                chip=$(echo "$compatible" | sed -E 's/.*,[[:space:]]*([a-z0-9]+-[a-z0-9]+).*/\1/; s/^[a-z]+-//; t; d' | head -n1)
                ;;

            # Makefile和设备定义文件（全架构通用）
            mk|Makefile)
                # 提取设备名（支持DEVICE_NAME/SUPPORTED_DEVICES等多种格式）
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES|TARGET_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES|TARGET_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g; s/[[:space:]]+/ /g')
                # 提取厂商（从路径中的vendor目录获取）
                vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d')
                # 提取芯片（SOC定义，如"SOC := qca9531" → "qca9531"）
                chip=$(grep -E 'SOC[[:space:]]*[:=]|CONFIG_SOC' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/.*(mt|ipq|qca|rtl|ath|bcm|sun|exynos|imx|x86|ppc|mips)[0-9a-z-]*/\1/; s/[^a-z0-9]//g; t; d' | head -n1)
                ;;

            # 配置文件（x86/PowerPC等架构）
            conf|config|defconfig)
                # 提取设备名（TARGET_DEVICE配置）
                device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g; s/[[:space:]]+/ /g')
                # 提取架构（作为芯片的补充）
                chip=$(grep -E '^CONFIG_ARCH' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/CONFIG_ARCH_//; s/=y//; t; d')
                ;;

            # 其他文件类型（兼容厂商自定义格式）
            board|profile|list|json|xml)
                # 通用文本提取（匹配"设备名:..."或"型号:..."格式）
                device_names=$(grep -E '^(name|model|device)[[:space:]]*[:=]' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/(name|model|device)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g; s/[[:space:]]+/ /g')
                # 从文件名提取芯片信息（如"mt7621-device.list" → "mt7621"）
                chip=$(basename "$file" | sed -E 's/(mt|ipq|qca|rtl|ath)[0-9]+.*/\1/; t; d')
                ;;

            # 无扩展名文件（通常是Makefile或自定义脚本）
            none)
                if echo "$file_type" | grep -q "text"; then
                    # 尝试从文本内容提取设备名
                    device_names=$(grep -E 'device[[:space:]]+name|model[[:space:]]+is' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/.*(device name|model is)[[:space:]]*//; s/[[:punct:]]/ /g; s/[[:space:]]+/ /g')
                fi
                ;;

            *)
                log "⚠️ 跳过不支持的文件类型：$file（扩展名：$file_ext）"
                continue
                ;;
        esac

        # ==============================================
        # 4.4 补充设备信息（路径提取+标准化）
        # ==============================================
        # 从路径提取平台信息（如"target/linux/ramips/mt7621" → "ramips/mt7621"）
        platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
        # 路径作为芯片的兜底来源（当内容提取失败时）
        chip_from_dir=$(echo "$platform_path" | awk -F '/' '{if (NF>=2) print $2; else print $1}')
        chip=${chip:-$chip_from_dir}
        # 标准化芯片名称（小写+去特殊字符）
        chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g; s/--+/-/g')

        # ==============================================
        # 4.5 处理设备名（去重+标准化）
        # ==============================================
        for name in $device_names; do
            [ -z "$name" ] && continue  # 跳过空值
            # 标准化设备名（小写+替换特殊字符+去重空格）
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | 
                         sed -E 's/[_,:;\/]+/-/g; s/[^a-z0-9- ]//g; s/[[:space:]]+/-/g; s/--+/-/g; s/^-+//; s/-+$//')
            [ -z "$device_name" ] && continue  # 跳过标准化后为空的名称

            # 去重：只处理未记录的设备
            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                # 写入JSON（带厂商和平台信息）
                if ! jq --arg name "$device_name" \
                        --arg chip "$chip" \
                        --arg vendor "$vendor" \
                        --arg kt "$platform_path" \
                        --arg file "$(basename "$file")" \
                        '.devices += [
                            {"name": $name, "chip": $chip, "vendor": $vendor, 
                             "kernel_target": $kt, "source": $file, "drivers": []}
                        ]' \
                        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
                    log "⚠️ 设备 $device_name 写入JSON失败（跳过）"
                    rm -f "$OUTPUT_JSON.tmp"
                    continue
                fi
                mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                log "ℹ️ 提取设备：$device_name（厂商：$vendor，芯片：$chip）"
            fi
        done
        set -uo pipefail  # 恢复严格模式
    done < "$batch_file"
    log "ℹ️ 批次 $batch_name 处理完成"
done

# 清理临时文件
rm -f "$LOG_DIR/device_files.tmp"

# ==============================================
# 4.6 验证设备提取结果
# ==============================================
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$device_count" -eq 0 ]; then
    log "❌ 未从源码中提取到任何设备，同步失败"
    exit 1
fi
log "✅ 设备提取完成，共 $device_count 个设备"

# ==============================================
# 5. 提取芯片信息（与全设备匹配）
# ==============================================
log "🔍 提取芯片信息（匹配全设备）..."
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
> "$CHIP_TMP_FILE"

# 定义支持的芯片正则（覆盖所有主流+小众架构）
VALID_CHIP_REGEX='^(
    mt[0-9]+|ipq[0-9]+|qca[0-9]+|rtl[0-9]+|ath[0-9]+|bcm[0-9]+|
    sun[0-9]+|exynos[0-9]+|imx[0-9]+|x86|i386|amd64|x86_64|
    ppc|powerpc|mips|mipsel|arm|arm64|aarch64|riscv|riscv64|
    mediatek|qualcomm|broadcom|allwinner|rockchip|nvidia
)$'

# 合并芯片来源（从设备和源码中提取）
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | \
    grep -E "$VALID_CHIP_REGEX" > "$LOG_DIR/chips_from_devices.tmp"

# 从Makefile补充芯片信息（覆盖更多架构）
find "$TMP_SRC/target/linux" -name "Makefile" -exec grep -hE 'ARCH|SOC|CPU' {} + 2>> "$SYNC_LOG" | \
    sed -E 's/.*(mt|ipq|qca|rtl|ath|bcm|sun|exynos|imx|x86|ppc|mips|arm|riscv|mediatek|qualcomm).*/\1/; t; d' | \
    tr '[:upper:]' '[:lower:]' | sort | uniq | \
    grep -E "$VALID_CHIP_REGEX" >> "$LOG_DIR/chips_from_devices.tmp"

# 去重并保存
sort -u "$LOG_DIR/chips_from_devices.tmp" > "$LOG_DIR/all_chips.tmp"

# 验证芯片提取结果
chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
if [ "$chip_count_total" -eq 0 ]; then
    log "❌ 未提取到任何有效芯片信息，同步失败"
    exit 1
fi

# ==============================================
# 5.1 处理每个芯片（关联设备和驱动）
# ==============================================
while read -r chip; do
    [ -z "$chip" ] && { log "⚠️ 跳过空芯片名"; continue; }
    # 双重验证芯片格式
    if ! echo "$chip" | grep -qE "$VALID_CHIP_REGEX"; then
        log "⚠️ 过滤无效芯片：$chip"
        continue
    fi
    # 跳过已处理的芯片
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    # 关联支持的设备平台
    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')
    [ -z "$platforms" ] && platforms="unknown"

    # 关联厂商（用于驱动匹配）
    vendors=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | 
              sort | uniq | tr '\n' ',' | sed 's/,$//')

    # 芯片驱动映射（覆盖全架构默认驱动）
    case "$chip" in
        mt*|mediatek*) drivers='["kmod-mt76", "kmod-rtc-mt6397"]' ;;  # 联发科
        ipq*|qca*|qualcomm*) drivers='["kmod-ath10k", "kmod-qca-nss-dp"]' ;;  # 高通
        bcm*|broadcom*) drivers='["kmod-brcm-wl", "kmod-brcmutil"]' ;;  # 博通
        sun*|allwinner*) drivers='["kmod-sunxi-mmc", "kmod-rtc-sunxi"]' ;;  # 全志
        x86|i386|amd64|x86_64) drivers='["kmod-e1000", "kmod-ahci", "kmod-r8169"]' ;;  # x86
        arm|arm64|aarch64) drivers='["kmod-armada-37xx", "kmod-i2c-arm"]' ;;  # ARM
        mips*) drivers='["kmod-mt7603", "kmod-switch-rtl8366"]' ;;  # MIPS
        riscv*) drivers='["kmod-riscv-timer", "kmod-serial-8250"]' ;;  # RISC-V
        *) drivers='[]' ;;
    esac

    # 写入芯片信息到JSON
    if ! jq --arg name "$chip" \
            --arg p "$platforms" \
            --arg v "$vendors" \
            --argjson d "$drivers" \
            '.chips += [
                {"name": $name, "platforms": $p, "vendors": $v, 
                 "default_drivers": $d}
            ]' \
            "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
        log "⚠️ 芯片 $chip 写入JSON失败（跳过）"
        continue
    fi
    mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" && echo "$chip" >> "$CHIP_TMP_FILE"
    log "ℹ️ 提取芯片：$chip（支持厂商：$vendors）"
done < "$LOG_DIR/all_chips.tmp"

# 清理芯片临时文件
rm -f "$CHIP_TMP_FILE" "$LOG_DIR/chips_from_devices.tmp" "$LOG_DIR/all_chips.tmp"

# ==============================================
# 5.2 验证芯片提取结果
# ==============================================
final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
if [ "$final_chip_count" -eq 0 ]; then
    log "❌ 芯片信息提取失败，同步终止"
    exit 1
fi
log "✅ 芯片提取完成，共 $final_chip_count 个芯片"

# ==============================================
# 6. 为设备补充驱动（基于芯片匹配）
# ==============================================
log "🔧 为全设备补充芯片对应的驱动..."
jq -c '.devices[]' "$OUTPUT_JSON" | while read -r device; do
    device_name=$(echo "$device" | jq -r '.name')
    chip=$(echo "$device" | jq -r '.chip')
    # 从芯片信息中获取驱动
    drivers=$(jq --arg c "$chip" '.chips[] | select(.name == $c) | .default_drivers' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | head -n1)
    [ "$drivers" = "null" ] && drivers='[]'  # 无匹配驱动时设为空

    # 更新设备的驱动列表
    jq --arg name "$device_name" \
       --argjson d "$drivers" \
       '.devices[] |= (if .name == $name then .drivers = $d else . end)' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
done

# ==============================================
# 7. 最终清理与完成
# ==============================================
rm -rf "$TMP_SRC" "$TMP_BATCH_DIR"  # 清理临时源码和批次文件
log "========================================="
log "✅ OpenWrt全设备同步完成"
log "📊 最终统计：设备 $device_count 个，芯片 $final_chip_count 个"
log "📄 设备配置文件路径：$OUTPUT_JSON"
log "📄 同步日志路径：$SYNC_LOG"
log "========================================="
