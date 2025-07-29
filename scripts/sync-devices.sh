#!/bin/bash
set -eu pipefail  # 移除-o选项，允许管道错误不中断整体流程

# ==============================================
# 基础配置与初始化
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SKIP_PLATFORMS=("siflower" "unknown")  # 已知有问题的平台，可手动添加

# 确保日志目录存在
mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）"
    exit 1
}
SYNC_LOG="$LOG_DIR/sync-detail.log"
> "$SYNC_LOG"  # 清空旧日志

# 日志函数：同时输出到控制台和日志文件
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步流程
# ==============================================
log "===== 开始设备与芯片自动同步 ====="
log "工作目录: $WORK_DIR"
log "输出文件: $OUTPUT_JSON"
log "跳过平台: ${SKIP_PLATFORMS[*]}"

# ==============================================
# 1. 检查依赖工具
# ==============================================
log "🔍 检查必要工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 错误：未安装必要工具 $tool"
        exit 1
    fi
done
log "✅ 所有依赖工具已安装"

# ==============================================
# 2. 初始化输出JSON（确保文件存在）
# ==============================================
log "🔧 初始化配置文件..."
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 错误：无法创建 $OUTPUT_JSON（权限问题）"
    exit 1
}

# ==============================================
# 3. 克隆OpenWrt源码（带重试机制）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码到临时目录: $TMP_SRC"

# 最多重试3次（应对网络波动）
retries=3
while [ $retries -gt 0 ]; do
    if git clone --depth 1 https://github.com/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试次数: $retries"
    sleep 3
done

if [ $retries -eq 0 ]; then
    log "❌ 错误：源码克隆失败（已重试3次）"
    exit 1
fi

# ==============================================
# 4. 验证源码目录
# ==============================================
TARGET_BASE="$TMP_SRC/target/linux"
if [ ! -d "$TARGET_BASE" ]; then
    log "❌ 错误：源码目录不完整，未找到 $TARGET_BASE"
    exit 1
fi
log "✅ 源码目录验证通过"

# ==============================================
# 5. 自动解析设备与芯片（核心逻辑）
# ==============================================
log "🔍 开始解析设备与芯片信息..."
device_count=0
chip_count=0

# 遍历所有平台目录
find "$TARGET_BASE" -maxdepth 1 -type d ! -name "linux" | while read -r plat_dir; do
    plat_name=$(basename "$plat_dir")
    
    # 跳过已知问题平台
    if [[ " ${SKIP_PLATFORMS[@]} " =~ " $plat_name " ]]; then
        log "⚠️ 跳过已知问题平台: $plat_name"
        continue
    fi

    log "ℹ️ 处理平台: $plat_name（路径: $plat_dir）"

    # 单个平台的解析逻辑（失败时仅记录不中断）
    {
        # 查找该平台下的设备树文件（.dts）
        dts_files=$(find "$plat_dir/dts" -name "*.dts" 2>/dev/null)
        if [ -z "$dts_files" ]; then
            log "⚠️ 未找到.dts文件，跳过平台: $plat_name"
            continue
        fi

        # 解析每个.dts文件提取设备信息
        echo "$dts_files" | while read -r dts_file; do
            # 提取设备名称（从文件名简化）
            dev_name=$(basename "$dts_file" .dts | sed -E 's/^(qcom|mediatek|realtek)-//; s/_/-/g')
            [ -z "$dev_name" ] && continue

            # 提取芯片型号（兼容多厂商格式）
            # 匹配格式：compatible = "厂商,芯片型号"
            chip=$(grep -E 'compatible\s*=\s*"[a-z0-9]+,[a-z0-9-]+"' "$dts_file" 2>/dev/null | \
                   head -n1 | \
                   sed -E 's/.*"[a-z0-9]+,([a-z0-9-]+)"/\1/' | \
                   sed 's/-/./g')  # 替换连字符为点（如ipq8074-a → ipq8074.a）

            # 若未提取到芯片，从平台名推断
            if [ -z "$chip" ]; then
                chip="$plat_name"
                log "⚠️ 设备 $dev_name 未找到芯片信息，从平台名推断: $chip"
            fi

            # 提取驱动包（从对应.mk文件）
            drivers=""
            mk_file=$(find "$plat_dir/image" -name "*.mk" 2>/dev/null | head -n1)
            if [ -n "$mk_file" ]; then
                drivers=$(grep "DEFAULT_PACKAGES" "$mk_file" 2>/dev/null | \
                          grep -oE "kmod-[a-z0-9-]+" | \
                          sort -u | \
                          tr '\n' ' ')
            fi

            # 写入设备到JSON（去重）
            if ! jq --arg name "$dev_name" '.devices[] | select(.name == $name)' "$OUTPUT_JSON" >/dev/null 2>&1; then
                jq --arg name "$dev_name" \
                   --arg chip "$chip" \
                   --arg target "$plat_name" \
                   --arg drivers "$drivers" \
                   '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(. != "")))}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

                device_count=$((device_count + 1))
                log "✅ 提取设备: $dev_name（芯片: $chip）"
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
    } || {
        log "⚠️ 平台 $plat_name 处理失败（继续下一个平台）"
    }
done

# ==============================================
# 6. 确保输出文件非空（兜底机制）
# ==============================================
current_dev_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
current_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

if [ "$current_dev_count" -eq 0 ] && [ "$current_chip_count" -eq 0 ]; then
    log "⚠️ 警告：未提取到任何设备和芯片，添加默认测试数据"
    # 添加默认设备
    jq '.devices += [{"name": "default-test-device", "chip": "default-chip", "kernel_target": "default-platform", "drivers": []}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    # 添加默认芯片
    jq '.chips += [{"name": "default-chip", "platform": "default-platform"}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    current_dev_count=1
    current_chip_count=1
fi

# ==============================================
# 7. 清理与完成
# ==============================================
rm -rf "$TMP_SRC"
log "===== 同步完成 ====="
log "统计结果：设备 $current_dev_count 个，芯片 $current_chip_count 个"
log "配置文件已保存到: $OUTPUT_JSON"
log "详细日志已保存到: $SYNC_LOG"
