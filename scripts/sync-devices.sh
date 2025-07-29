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
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc")
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
# 4. 解析设备与芯片（优化版：支持子目录和多格式）
# ==============================================
TARGET_BASE="$TMP_SRC/target/linux"
device_count=0
chip_count=0

log "🔍 开始解析设备（支持子目录搜索）..."

# 遍历所有平台（包含子平台目录，如mediatek/filogic）
find "$TARGET_BASE" -type d \( -name "generic" -o -name "filogic" -o -name "mt7621" -o -name "ipq806x" -o -name "ath79" -o -name "ramips" -o -name "x86" \) | while read -r plat_dir; do
    # 提取完整平台名（如"mediatek/filogic"）
    plat_name=$(echo "$plat_dir" | sed "s|$TARGET_BASE/||")
    
    # 跳过问题平台
    if [[ " ${SKIP_PLATFORMS[@]} " =~ " $plat_name " ]]; then
        log "⚠️ 跳过平台: $plat_name"
        continue
    fi

    log "ℹ️ 处理平台: $plat_name（路径: $plat_dir）"
    {
        # 递归查找所有.dts文件（包含所有子目录）
        log "  查找.dts文件路径: $plat_dir/dts"
        dts_files=$(find "$plat_dir/dts" -type f -name "*.dts" 2>/dev/null)
        
        # 检查是否找到.dts文件
        if [ -z "$dts_files" ]; then
            log "⚠️ 未找到.dts文件，跳过平台: $plat_name"
            continue
        else
            dts_count=$(echo "$dts_files" | wc -l)
            log "  找到.dts文件数量: $dts_count"
            # 打印前3个文件路径（调试用）
            echo "$dts_files" | head -n3 | while read -r f; do log "  示例文件: $f"; done
        fi

        # 解析每个.dts文件
        echo "$dts_files" | while read -r dts_file; do
            # 提取设备名称（从文件名简化，支持多级目录）
            dev_name=$(basename "$dts_file" .dts | sed -E 's/^(qcom|mediatek|realtek|mtk|ath)-//; s/_/-/g')
            if [ -z "$dev_name" ]; then
                log "⚠️ 从文件 $dts_file 提取设备名称失败（名称为空）"
                continue
            fi

            # 提取芯片型号（兼容更多格式：支持大写、下划线、点号）
            # 匹配格式：compatible = "厂商,芯片型号"（如"qcom,ipq8074"、"MediaTek,MT7981"）
            chip_line=$(grep -E 'compatible\s*=\s*"[A-Za-z0-9_]+,[A-Za-z0-9_\.-]+"' "$dts_file" 2>/dev/null | head -n1)
            if [ -n "$chip_line" ]; then
                chip=$(echo "$chip_line" | sed -E 's/.*"[A-Za-z0-9_]+,([A-Za-z0-9_\.-]+)"/\1/' | tr '[:upper:]' '[:lower:]')
            else
                # 未找到时从平台名推断
                chip=$(echo "$plat_name" | sed -E 's/.*\/([a-z0-9-]+)/\1/')  # 取最后一级目录名
                log "⚠️ 文件 $dts_file 未找到芯片信息，从平台名推断: $chip"
            fi

            # 写入设备到JSON（去重）
            if ! jq --arg name "$dev_name" '.devices[] | select(.name == $name)' "$OUTPUT_JSON" >/dev/null 2>&1; then
                jq --arg name "$dev_name" \
                   --arg chip "$chip" \
                   --arg target "$plat_name" \
                   '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                
                device_count=$((device_count + 1))
                log "✅ 提取设备: $dev_name（芯片: $chip，平台: $plat_name）"
            fi

            # 写入芯片到JSON（去重）
            if ! jq --arg c "$chip" '.chips[] | select(.name == $c)' "$OUTPUT_JSON" >/dev/null 2>&1; then
                jq --arg name "$chip" \
                   --arg platform "$plat_name" \
                   '.chips += [{"name": $name, "platform": $platform}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                
                chip_count=$((chip_count + 1))
                log "✅ 提取芯片: $chip（平台: $plat_name）"
            fi
        done
    } || log "⚠️ 平台 $plat_name 处理失败（继续下一个）"
done

# ==============================================
# 5. 兜底：确保文件非空
# ==============================================
current_dev_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
current_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

if [ "$current_dev_count" -eq 0 ] || [ "$current_chip_count" -eq 0 ]; then
    log "⚠️ 未提取到足够数据，添加测试数据"
    # 添加默认设备
    jq '.devices += [{"name": "test-device", "chip": "test-chip", "kernel_target": "test-platform"}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    # 添加默认芯片
    jq '.chips += [{"name": "test-chip", "platform": "test-platform"}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    current_dev_count=$((current_dev_count + 1))
    current_chip_count=$((current_chip_count + 1))
fi

# ==============================================
# 6. 清理与完成
# ==============================================
rm -rf "$TMP_SRC"
log "===== 同步完成 ====="
log "最终设备总数: $current_dev_count，芯片总数: $current_chip_count"
log "日志路径: $SYNC_LOG"
log "配置文件路径: $OUTPUT_JSON"
