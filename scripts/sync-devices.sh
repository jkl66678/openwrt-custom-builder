#!/bin/bash
set -euo pipefail

# 配置路径
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

# 初始化日志
mkdir -p "$LOG_DIR"
> "$SYNC_LOG"

# 日志函数
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

log "========================================="
log "📌 工作目录：$WORK_DIR"
log "📌 输出文件：$OUTPUT_JSON"
log "📥 开始设备同步"
log "========================================="

# 检查依赖
if ! command -v jq &> /dev/null; then
    log "❌ 未安装 jq（JSON处理工具）"
    exit 1
fi
if ! command -v git &> /dev/null; then
    log "❌ 未安装 git"
    exit 1
fi
log "✅ 依赖工具齐全"

# 初始化JSON
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建 $OUTPUT_JSON"
    exit 1
}
log "✅ 初始化配置文件"

# 克隆源码
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码到：$TMP_SRC"
if ! git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
    log "❌ 源码克隆失败"
    exit 1
fi

# 提取设备和芯片信息
log "🔍 提取设备信息..."
declare -A PROCESSED_DEVICES  # 去重

# 遍历所有.dts文件
find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts_file; do
    # 解析设备名（如"mt7621_redmi-ac2100.dts" → "redmi-ac2100"）
    filename=$(basename "$dts_file" .dts)
    device_name=$(echo "$filename" | sed -E 's/^[a-z0-9]+_//' | tr '_' '-')
    [ -z "$device_name" ] && device_name="$filename"  #  fallback
    
    # 解析芯片和平台（路径格式：target/linux/{platform}/{chip}）
    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||")
    chip=$(echo "$platform_path" | awk -F '/' '{print $2}')
    [ -z "$chip" ] && chip=$(echo "$platform_path" | awk -F '/' '{print $1}')  # 简化提取
    kernel_target="$platform_path"
    
    # 去重处理
    if [ -z "${PROCESSED_DEVICES[$device_name]}" ]; then
        PROCESSED_DEVICES["$device_name"]=1
        
        # 添加设备到JSON
        jq --arg name "$device_name" \
           --arg chip "$chip" \
           --arg kt "$kernel_target" \
           '.devices += [{"name": $name, "chip": $chip, "kernel_target": $kt, "drivers": []}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
        log "ℹ️ 添加设备：$device_name（芯片：$chip）"
    fi
done

# 提取芯片列表（去重）
log "🔍 提取芯片信息..."
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    # 关联芯片与平台
    platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1)
    jq --arg name "$chip" \
       --arg p "$platform" \
       '.chips += [{"name": $name, "platform": $p}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    log "ℹ️ 添加芯片：$chip（平台：$platform）"
done

# 补充默认驱动（示例）
log "🔧 补充默认驱动..."
jq '.devices[] |= (
    if .chip == "mt7621" then .drivers = ["kmod-mt7603e", "kmod-mt7615e"]
    elif .chip == "mt7981" then .drivers = ["kmod-mt7981-firmware", "kmod-gmac"]
    elif .chip == "x86_64" then .drivers = ["kmod-e1000e", "kmod-igb"]
    else .drivers end
)' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

# 最终验证
if [ $(jq '.devices | length' "$OUTPUT_JSON") -eq 0 ]; then
    log "⚠️ 未提取到设备，添加默认设备"
    jq '.devices += [{"name": "default-device", "chip": "default-chip", "kernel_target": "generic", "drivers": []}]' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
fi

# 清理
rm -rf "$TMP_SRC"
log "✅ 同步完成，设备总数：$(jq '.devices | length' "$OUTPUT_JSON")"
log "========================================="
