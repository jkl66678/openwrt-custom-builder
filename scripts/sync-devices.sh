#!/bin/bash
set -euo pipefail

# ==============================================
# 配置与初始化
# ==============================================
# 日志目录与文件（确保在仓库根目录下）
LOG_DIR="./sync-logs"
mkdir -p "$LOG_DIR"  # 强制创建日志目录
SYNC_LOG="$LOG_DIR/sync-detail.log"
> "$SYNC_LOG"  # 清空旧日志

# 输出文件（设备与芯片配置）
OUTPUT_JSON="device-drivers.json"

# 日志函数（同时输出到控制台和日志文件）
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 开始同步流程
# ==============================================
log "========================================="
log "📥 开始设备与芯片同步流程"
log "========================================="

# ==============================================
# 1. 检查依赖工具
# ==============================================
log "🔍 检查必要工具..."
if ! command -v jq &> /dev/null; then
    log "❌ 错误：未安装 jq（JSON 处理工具）"
    exit 1
fi
if ! command -v git &> /dev/null; then
    log "❌ 错误：未安装 git"
    exit 1
fi
log "✅ 所有依赖工具已安装"

# ==============================================
# 2. 初始化输出JSON文件
# ==============================================
log "🔧 初始化设备配置文件：$OUTPUT_JSON"
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "❌ 错误：无法创建 $OUTPUT_JSON（可能权限不足）"
    exit 1
}

# ==============================================
# 3. 克隆OpenWrt源码（临时目录）
# ==============================================
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt源码到临时目录：$TMP_SRC"

# 带重试的克隆（处理网络波动）
retries=3
while [ $retries -gt 0 ]; do
    if git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 克隆失败，剩余重试次数：$retries"
    sleep 5
done

if [ $retries -eq 0 ]; then
    log "❌ 错误：源码克隆失败（已重试3次，查看日志获取详情）"
    exit 1
fi

# ==============================================
# 4. 验证源码目录完整性
# ==============================================
TARGET_BASE="$TMP_SRC/target/linux"
log "🔍 验证源码目录：$TARGET_BASE"
if [ ! -d "$TARGET_BASE" ]; then
    log "❌ 错误：源码目录不完整，未找到 $TARGET_BASE"
    log "目录结构：$(ls -la "$TMP_SRC")"
    exit 1
fi
log "✅ 源码目录验证通过"

# ==============================================
# 5. 平台-芯片映射表（可扩展）
# ==============================================
declare -A PLATFORM_CHIPS=(
    ["mediatek/filogic"]="mt7981 mt7986 mt7983"
    ["ramips/mt7621"]="mt7621"
    ["x86/64"]="x86_64"
    ["ipq806x/generic"]="ipq8065 ipq8064"
    ["bcm53xx/generic"]="bcm53573 bcm4708"
)

# ==============================================
# 6. 提取设备与芯片信息
# ==============================================
log "🔍 开始提取设备与芯片信息..."
device_count=0
chip_count=0

for platform in "${!PLATFORM_CHIPS[@]}"; do
    plat_path="$TARGET_BASE/$platform"
    log "ℹ️ 处理平台：$platform（路径：$plat_path）"

    # 跳过不存在的平台目录
    if [ ! -d "$plat_path" ]; then
        log "⚠️ 平台目录不存在，跳过：$plat_path"
        continue
    fi

    # 提取设备信息（.mk文件）
    mk_files=$(find "$plat_path" -name "*.mk")
    if [ -z "$mk_files" ]; then
        log "⚠️ 未找到设备配置文件（.mk），跳过平台：$platform"
        continue
    fi

    # 处理每个设备文件
    echo "$mk_files" | while read -r mkfile; do
        # 提取设备名称（处理特殊字符）
        dev_name=$(grep "DEVICE_NAME" "$mkfile" | cut -d'=' -f2 | tr -d '"' | sed 's/[\/&]/\\&/g' | sed 's/ //g')
        if [ -z "$dev_name" ]; then
            log "⚠️ 未从文件中提取到设备名称：$mkfile"
            return 0  # 继续处理下一个文件
        fi

        # 关联芯片（取第一个芯片作为主芯片）
        chips=${PLATFORM_CHIPS[$platform]}
        main_chip=$(echo "$chips" | awk '{print $1}')

        # 写入设备到JSON
        jq --arg name "$dev_name" \
           --arg chip "$main_chip" \
           --arg target "$platform" \
           '.devices += [{"name": $name, "chip": $main_chip, "kernel_target": $target}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || {
            log "⚠️ 写入设备 $dev_name 到JSON失败（可能含特殊字符）"
        }
        device_count=$((device_count + 1))
        log "ℹ️ 已提取设备：$dev_name（芯片：$main_chip）"
    done

    # 提取芯片信息（去重）
    for chip in $chips; do
        # 检查芯片是否已存在于JSON中
        if ! jq --arg c "$chip" '.chips[] | select(.name == $c)' "$OUTPUT_JSON" > /dev/null; then
            jq --arg name "$chip" \
               --arg platform "$platform" \
               '.chips += [{"name": $name, "platform": $platform}]' \
               "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || {
                log "⚠️ 写入芯片 $chip 到JSON失败"
            }
            chip_count=$((chip_count + 1))
            log "ℹ️ 已提取芯片：$chip"
        fi
    done
done

# ==============================================
# 7. 验证提取结果
# ==============================================
log "📊 提取结果统计：设备 $device_count 个，芯片 $chip_count 个"
if [ $device_count -eq 0 ] && [ $chip_count -eq 0 ]; then
    log "❌ 错误：未提取到任何设备或芯片（可能平台映射表需要扩展）"
    exit 1
fi

# 验证JSON格式
if ! jq . "$OUTPUT_JSON" > /dev/null 2>&1; then
    log "❌ 错误：$OUTPUT_JSON 格式无效"
    exit 1
fi

# ==============================================
# 8. 清理与完成
# ==============================================
rm -rf "$TMP_SRC"
log "✅ 同步完成，配置文件：$OUTPUT_JSON（日志：$SYNC_LOG）"
log "========================================="
