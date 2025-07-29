#!/bin/bash
set -euo pipefail

# 配置
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
mkdir -p "$LOG_DIR"
SYNC_LOG="$LOG_DIR/sync-detail.log"
> "$SYNC_LOG"

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$SYNC_LOG"
}

log "===== 开始自动同步设备与芯片 ====="
log "工作目录: $WORK_DIR"

# 1. 检查依赖
log "检查依赖工具..."
for tool in git jq grep sed awk find; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失工具: $tool"
        exit 1
    fi
done

# 2. 克隆OpenWrt源码（最新版）
TMP_SRC=$(mktemp -d)
log "克隆OpenWrt源码到临时目录: $TMP_SRC"
git clone --depth 1 https://github.com/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG" || {
    log "❌ 源码克隆失败"
    exit 1
}

# 3. 初始化输出文件
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON"

# 4. 自动解析所有平台的设备与芯片
log "开始解析源码中的设备与芯片..."
TARGET_BASE="$TMP_SRC/target/linux"

# 遍历所有平台（如 ath79、mediatek、ipq806x 等）
find "$TARGET_BASE" -maxdepth 1 -type d ! -name "linux" | while read -r plat_dir; do
    plat_name=$(basename "$plat_dir")  # 平台名称（如 ipq806x）
    log "处理平台: $plat_name"

    # 解析该平台下的所有设备DTS文件（芯片信息主要在.dts中）
    find "$plat_dir/dts" -name "*.dts" | while read -r dts_file; do
        # 提取设备名称（从文件名或DTS内容）
        dev_name=$(basename "$dts_file" .dts | sed 's/^qcom-//; s/^mt-//')  # 简化名称
        [ -z "$dev_name" ] && continue

        # 提取芯片型号（匹配常见格式：qcom,ipq8074、mt7981、rtl8380等）
        # 正则匹配芯片型号（支持高通、联发科、瑞昱等厂商格式）
        chip=$(grep -E 'compatible = "qcom,[a-z0-9-]+"|compatible = "mediatek,[a-z0-9-]+"|compatible = "realtek,[a-z0-9-]+"' "$dts_file" | \
               head -n1 | \
               sed -E 's/.*"(qcom|mediatek|realtek),([a-z0-9-]+)".*/\2/' | \
               sed 's/-/./g')  # 替换连字符（如 ipq8074-a 转为 ipq8074.a）

        # 若DTS中未直接找到，从平台名推断（如 ipq806x 平台默认芯片 ipq806x）
        [ -z "$chip" ] && chip="$plat_name"

        # 提取驱动（从对应.mk文件）
        mk_file=$(find "$plat_dir/image" -name "*.mk" | grep -v "generic" | head -n1)
        drivers=$(if [ -f "$mk_file" ]; then
            grep "DEFAULT_PACKAGES" "$mk_file" | grep -oE "kmod-[a-z0-9-]+" | tr '\n' ' '
        else
            echo ""
        fi)

        # 写入设备信息到JSON（去重）
        if ! jq --arg name "$dev_name" '.devices[] | select(.name == $name)' "$OUTPUT_JSON" > /dev/null; then
            log "提取设备: $dev_name (芯片: $chip, 平台: $plat_name)"
            jq --arg name "$dev_name" \
               --arg chip "$chip" \
               --arg target "$plat_name" \
               --arg drivers "$drivers" \
               '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(. != "")))}]' \
               "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
        fi

        # 写入芯片信息到JSON（去重）
        if ! jq --arg c "$chip" '.chips[] | select(.name == $c)' "$OUTPUT_JSON" > /dev/null; then
            log "提取芯片: $chip (平台: $plat_name)"
            jq --arg name "$chip" \
               --arg platform "$plat_name" \
               '.chips += [{"name": $name, "platform": $platform}]' \
               "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
        fi
    done
done

# 5. 结果统计
dev_count=$(jq '.devices | length' "$OUTPUT_JSON")
chip_count=$(jq '.chips | length' "$OUTPUT_JSON")
log "===== 同步完成 ====="
log "共提取设备: $dev_count 个，芯片: $chip_count 个"
log "结果已保存到: $OUTPUT_JSON"

# 清理临时文件
rm -rf "$TMP_SRC"
