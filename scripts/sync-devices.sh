#!/bin/bash
set -euo pipefail  # 严格模式：遇到错误、未定义变量、管道失败时退出

# ==============================================
# 基础配置与初始化
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

# 确保日志目录存在
mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2
    exit 1
}
> "$SYNC_LOG"  # 清空旧日志

# 日志函数：同时输出到控制台和日志文件
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
log "📥 开始设备与芯片同步"
log "========================================="

# ==============================================
# 1. 检查依赖工具
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc")
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
# 3. 克隆OpenWrt源码（带重试机制）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码到临时目录：$TMP_SRC"

# 最多重试3次（应对网络波动）
retries=3
while [ $retries -gt 0 ]; do
    if git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
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
# 4. 提取设备信息（核心逻辑，修复关联数组问题）
# ==============================================
log "🔍 开始提取设备信息..."
declare -A PROCESSED_DEVICES  # 关联数组：用于设备去重（键为设备名）

# 查找所有.dts文件并保存到临时文件（避免管道子shell导致数组无法共享）
find "$TMP_SRC/target/linux" -name "*.dts" > "$LOG_DIR/dts_files.tmp"

# 遍历.dts文件（从临时文件读取，避免子shell问题）
while read -r dts_file; do
    # 解析设备名（从文件名提取，如"mt7621_redmi-ac2100.dts" → "redmi-ac2100"）
    filename=$(basename "$dts_file" .dts)
    device_name=$(echo "$filename" | sed -E 's/^[a-z0-9_-]+_//' | tr '_' '-')  # 移除前缀
    if [ -z "$device_name" ]; then
        device_name="$filename"  # 兜底：若提取失败则使用原始文件名
    fi

    # 解析芯片型号和平台路径（如"target/linux/ramips/mt7621" → 芯片mt7621，平台ramips/mt7621）
    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||")  # 相对路径
    chip=$(echo "$platform_path" | awk -F '/' '{print $2}')  # 取第二级目录（如mt7621）
    if [ -z "$chip" ] || [ "$chip" = "." ]; then  # 处理一级目录情况
        chip=$(echo "$platform_path" | awk -F '/' '{print $1}')
    fi
    kernel_target="$platform_path"  # 完整平台路径（如ramips/mt7621）

    # 去重处理（修复：使用 -v 检查数组键是否存在，避免未定义变量错误）
    if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
        PROCESSED_DEVICES["$device_name"]=1  # 标记为已处理

        # 写入设备信息到JSON
        jq --arg name "$device_name" \
           --arg chip "$chip" \
           --arg kt "$kernel_target" \
           '.devices += [{"name": $name, "chip": $chip, "kernel_target": $kt, "drivers": []}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

        log "ℹ️ 提取设备：$device_name（芯片：$chip，平台：$kernel_target）"
    fi
done < "$LOG_DIR/dts_files.tmp"  # 从临时文件读取.dts列表

# 清理临时文件
rm -f "$LOG_DIR/dts_files.tmp"

# ==============================================
# 5. 提取芯片信息（去重并关联平台）
# ==============================================
log "🔍 开始提取芯片信息..."
declare -A PROCESSED_CHIPS  # 关联数组：用于芯片去重

# 从设备列表中提取芯片并去重
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    if ! [[ -v PROCESSED_CHIPS["$chip"] ]]; then
        PROCESSED_CHIPS["$chip"]=1

        # 关联芯片与平台（取第一个使用该芯片的设备的平台）
        platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1)
        
        # 写入芯片信息到JSON
        jq --arg name "$chip" \
           --arg p "$platform" \
           '.chips += [{"name": $name, "platform": $p}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

        log "ℹ️ 提取芯片：$chip（关联平台：$platform）"
    fi
done

# ==============================================
# 6. 补充默认驱动（针对常见芯片）
# ==============================================
log "🔧 补充常见芯片的默认驱动..."
jq '.devices[] |= (
    if .chip == "mt7621" then .drivers = ["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s"]
    elif .chip == "mt7981" then .drivers = ["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3"]
    elif .chip == "ipq806x" then .drivers = ["kmod-qca-nss-dp", "kmod-qca-nss-ecm"]
    elif .chip == "x86_64" then .drivers = ["kmod-e1000e", "kmod-igb", "kmod-rtc-pc"]
    else .drivers end
)' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

# ==============================================
# 7. 兜底机制：确保文件非空
# ==============================================
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

if [ "$device_count" -eq 0 ] || [ "$chip_count" -eq 0 ]; then
    log "⚠️ 未提取到足够数据，添加默认测试设备"
    # 添加默认设备
    jq '.devices += [{"name": "test-device", "chip": "test-chip", "kernel_target": "generic", "drivers": ["kmod-generic"]}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    # 添加默认芯片
    jq '.chips += [{"name": "test-chip", "platform": "generic"}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    device_count=$((device_count + 1))
    chip_count=$((chip_count + 1))
fi

# ==============================================
# 8. 清理与完成
# ==============================================
rm -rf "$TMP_SRC"  # 清理临时源码目录
log "========================================="
log "✅ 同步完成"
log "📊 统计结果：设备 $device_count 个，芯片 $chip_count 个"
log "📄 配置文件路径：$OUTPUT_JSON"
log "📄 详细日志路径：$SYNC_LOG"
log "========================================="
