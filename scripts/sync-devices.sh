#!/bin/bash
set -euo pipefail

# 日志文件（记录每一步操作）
SYNC_LOG="sync-detail.log"
> "$SYNC_LOG"  # 清空旧日志

# 输出到控制台并写入日志
log() {
    echo "$1" | tee -a "$SYNC_LOG"
}

log "📥 开始同步设备信息..."

# 1. 检查依赖工具
log "🔍 检查依赖工具..."
if ! command -v jq &> /dev/null; then
    log "❌ 错误：未安装 jq（JSON处理工具）"
    exit 1
fi
if ! command -v git &> /dev/null; then
    log "❌ 错误：未安装 git"
    exit 1
fi
log "✅ 依赖工具齐全"

# 2. 克隆源码（临时目录）
TMP_SRC=$(mktemp -d)
log "📥 克隆源码到临时目录：$TMP_SRC"
if ! git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
    log "❌ 源码克隆失败（查看 sync-detail.log 中的克隆日志）"
    exit 1
fi

# 3. 验证源码目录完整性
TARGET_DIR="$TMP_SRC/target/linux"
log "🔍 验证源码目录：$TARGET_DIR"
if [ ! -d "$TARGET_DIR" ]; then
    log "❌ 错误：源码目录不完整，未找到 $TARGET_DIR"
    log "目录内容：$(ls -la "$TMP_SRC")"
    exit 1
fi
log "✅ 源码目录有效"

# 4. 初始化设备配置文件
OUTPUT_JSON="device-drivers.json"
log "🔧 初始化配置文件：$OUTPUT_JSON"
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 错误：无法创建 $OUTPUT_JSON（权限不足？）"
    exit 1
}

# 5. 平台-芯片映射表（简化版，减少出错点）
declare -A PLATFORM_CHIPS=(
    ["mediatek/filogic"]="mt7981"
    ["ramips/mt7621"]="mt7621"
    ["x86/64"]="x86_64"
)

# 6. 提取设备和芯片信息
log "🔍 开始提取设备信息..."
for platform in "${!PLATFORM_CHIPS[@]}"; do
    plat_path="$TARGET_DIR/$platform"
    log "ℹ️ 处理平台：$platform（路径：$plat_path）"
    
    # 检查平台目录是否存在
    if [ ! -d "$plat_path" ]; then
        log "⚠️ 平台目录不存在，跳过：$plat_path"
        continue
    fi
    
    # 查找设备配置文件（.mk）
    mk_files=$(find "$plat_path" -name "*.mk")
    if [ -z "$mk_files" ]; then
        log "⚠️ 未找到 .mk 文件，跳过平台：$platform"
        continue
    fi
    log "ℹ️ 找到 .mk 文件数量：$(echo "$mk_files" | wc -l)"
    
    # 提取设备信息
    echo "$mk_files" | while read -r file; do
        log "ℹ️ 处理设备文件：$file"
        
        # 提取设备名称
        device_name=$(grep "DEVICE_NAME" "$file" | cut -d'=' -f2 | tr -d '"' | sed 's/ //g')
        if [ -z "$device_name" ]; then
            log "⚠️ 未提取到设备名称，跳过文件：$file"
            continue
        fi
        
        # 提取芯片（从映射表）
        chip="${PLATFORM_CHIPS[$platform]}"
        
        # 写入JSON
        log "ℹ️ 写入设备：$device_name（芯片：$chip）"
        if ! jq --arg name "$device_name" \
                --arg chip "$chip" \
                --arg target "$platform" \
                '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target}]' \
                "$OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "$OUTPUT_JSON"; then
            log "⚠️ 写入设备 $device_name 失败（可能含特殊字符）"
        fi
    done
    
    # 提取芯片信息
    chip="${PLATFORM_CHIPS[$platform]}"
    log "ℹ️ 写入芯片：$chip"
    if ! jq --arg name "$chip" \
            --arg platform "$platform" \
            '.chips += [{"name": $name, "platform": $platform}]' \
            "$OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "$OUTPUT_JSON"; then
        log "⚠️ 写入芯片 $chip 失败"
    fi
done

# 7. 验证是否提取到数据
if [ $(jq '.devices | length' "$OUTPUT_JSON") -eq 0 ] && [ $(jq '.chips | length' "$OUTPUT_JSON") -eq 0 ]; then
    log "❌ 错误：未提取到任何设备或芯片（平台映射表可能不完整）"
    exit 1
fi

# 8. 清理临时文件
rm -rf "$TMP_SRC"
log "✅ 同步完成，配置文件：$OUTPUT_JSON"
log "📄 详细日志已保存到：$SYNC_LOG"
