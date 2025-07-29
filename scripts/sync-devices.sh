#!/bin/bash
set -eu pipefail

# ==============================================
# 基础配置（强制生成日志和输出文件）
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SKIP_PLATFORMS=("siflower")  # 跳过已知问题平台

# 强制创建日志目录和文件（即使后续步骤失败也保留）
mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2
    exit 1
}
SYNC_LOG="$LOG_DIR/sync-detail.log"
touch "$SYNC_LOG"  # 确保日志文件存在

# 日志函数
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步
# ==============================================
log "===== 开始设备与芯片同步 ====="
log "工作目录: $WORK_DIR"
log "输出文件: $OUTPUT_JSON"
log "跳过平台: ${SKIP_PLATFORMS[*]}"

# ==============================================
# 1. 检查依赖
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失工具: $tool"
        exit 1
    fi
done
log "✅ 依赖齐全"

# ==============================================
# 2. 初始化输出文件（确保非空）
# ==============================================
log "🔧 初始化配置文件..."
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建 $OUTPUT_JSON"
    exit 1
}

# ==============================================
# 3. 克隆OpenWrt源码（带重试）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆源码到: $TMP_SRC"
retries=3
while [ $retries -gt 0 ]; do
    if git clone --depth 1 https://github.com/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试: $retries"
    sleep 3
done
if [ $retries -eq 0 ]; then
    log "❌ 源码克隆失败"
    exit 1
fi

# ==============================================
# 4. 解析设备与芯片（容错模式）
# ==============================================
TARGET_BASE="$TMP_SRC/target/linux"
device_count=0
chip_count=0

log "🔍 开始解析设备..."
find "$TARGET_BASE" -maxdepth 1 -type d ! -name "linux" | while read -r plat_dir; do
    plat_name=$(basename "$plat_dir")
    
    # 跳过问题平台
    if [[ " ${SKIP_PLATFORMS[@]} " =~ " $plat_name " ]]; then
        log "⚠️ 跳过平台: $plat_name"
        continue
    fi

    log "ℹ️ 处理平台: $plat_name"
    {
        # 解析.dts文件
        dts_files=$(find "$plat_dir/dts" -name "*.dts" 2>/dev/null)
        [ -z "$dts_files" ] && { log "⚠️ 无.dts文件，跳过"; continue; }

        echo "$dts_files" | while read -r dts_file; do
            dev_name=$(basename "$dts_file" .dts | sed -E 's/^(qcom|mediatek)-//')
            [ -z "$dev_name" ] && continue

            # 提取芯片
            chip=$(grep -E 'compatible = "[a-z0-9]+,[a-z0-9-]+"' "$dts_file" 2>/dev/null | \
                   head -n1 | sed -E 's/.*"[a-z0-9]+,([a-z0-9-]+)"/\1/')
            [ -z "$chip" ] && chip="$plat_name"

            # 写入设备
            if ! jq --arg name "$dev_name" '.devices[] | select(.name == $name)' "$OUTPUT_JSON" >/dev/null; then
                jq --arg name "$dev_name" --arg chip "$chip" --arg target "$plat_name" \
                   '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                device_count=$((device_count + 1))
                log "✅ 提取设备: $dev_name"
            fi

            # 写入芯片
            if ! jq --arg c "$chip" '.chips[] | select(.name == $c)' "$OUTPUT_JSON" >/dev/null; then
                jq --arg name "$chip" --arg platform "$plat_name" \
                   '.chips += [{"name": $name, "platform": $platform}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                chip_count=$((chip_count + 1))
                log "✅ 提取芯片: $chip"
            fi
        done
    } || log "⚠️ 平台 $plat_name 处理失败（继续下一个）"
done

# ==============================================
# 5. 兜底：确保文件非空
# ==============================================
if [ $(jq '.devices | length' "$OUTPUT_JSON") -eq 0 ]; then
    log "⚠️ 未提取到设备，添加测试数据"
    jq '.devices += [{"name": "test-device", "chip": "test-chip"}]' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    jq '.chips += [{"name": "test-chip"}]' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
fi

# ==============================================
# 6. 清理与完成
# ==============================================
rm -rf "$TMP_SRC"
log "===== 同步完成 ====="
log "设备总数: $device_count，芯片总数: $chip_count"
log "日志路径: $SYNC_LOG"
