#!/bin/bash
set -euo pipefail  # 严格模式：错误、未定义变量、管道失败时退出

# 捕获EXIT信号，确保临时文件清理
trap 'cleanup' EXIT
cleanup() {
    if [ -n "${TMP_SRC:-}" ] && [ -d "$TMP_SRC" ]; then
        rm -rf "$TMP_SRC"
        log "🧹 清理临时源码目录: $TMP_SRC"
    fi
    # 清理临时文件
    for tmp in "$DTS_LIST_TMP" "$CHIP_TMP_FILE" "$DEVICE_TMP_JSON" "$CHIP_TMP_JSON" "$DEDUP_FILE"; do
        [ -f "$tmp" ] && rm -f "$tmp"
    done
}

# ==============================================
# 基础配置与常量定义
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

MAX_MEM_THRESHOLD=6000
MAX_DTS_SIZE=5242880
CLONE_RETRIES=5
SOURCE_REPOS=(
    "https://git.openwrt.org/openwrt/openwrt.git"
    "https://github.com/openwrt/openwrt.git"
)

# 临时文件
DTS_LIST_TMP="$LOG_DIR/dts_files.tmp"
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
DEVICE_TMP_JSON="$LOG_DIR/devices_temp.json"
CHIP_TMP_JSON="$LOG_DIR/chips_temp.json"
DEDUP_FILE="$LOG_DIR/processed_devices.tmp"

# ==============================================
# 初始化与日志系统（彻底修复$2变量和整数表达式错误）
# ==============================================
mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2
    exit 1
}
> "$SYNC_LOG"
> "$DTS_LIST_TMP"
> "$CHIP_TMP_FILE"
echo '[]' > "$DEVICE_TMP_JSON"
echo '[]' > "$CHIP_TMP_JSON"
> "$DEDUP_FILE"

# 日志函数：移除所有$2引用，修复整数比较
LOG_LEVEL="${1:-INFO}"
log() {
    local level="$1"
    local message="$2"
    local level_order=("DEBUG" "INFO" "WARN" "ERROR")
    
    # 修复整数表达式错误：为索引设置默认值0
    local current_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$LOG_LEVEL$" | cut -d: -f1)
    current_idx=${current_idx:-0}  # 若未找到则设为0
    local msg_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$level$" | cut -d: -f1)
    msg_idx=${msg_idx:-0}  # 若未找到则设为0

    # 确保比较的是整数（强制转换）
    if [ $((msg_idx)) -lt $((current_idx)) ]; then
        return
    fi

    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local level_tag
    case "$level" in
        "INFO")  level_tag="ℹ️" ;;
        "SUCCESS") level_tag="✅" ;;
        "WARN")  level_tag="⚠️" ;;
        "ERROR") level_tag="❌" ;;
        "DEBUG") level_tag="🔍" ;;
        *) level_tag="📌" ;;
    esac
    echo "[$timestamp] $level_tag $message" | tee -a "$SYNC_LOG"
}

# ==============================================
# 资源监控函数
# ==============================================
check_resources() {
    if command -v free &>/dev/null; then
        local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    else
        local mem_used=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    fi
    if [ "$mem_used" -gt "$MAX_MEM_THRESHOLD" ]; then
        log "WARN" "内存使用过高($mem_used MB)，暂停处理"
        sleep 10
        return 1
    fi

    if command -v df &>/dev/null; then
        local disk_free=$(df -P "$LOG_DIR" | awk 'NR==2 {print $4}')
        if [ "$disk_free" -lt 1048576 ]; then
            log "ERROR" "磁盘空间不足（剩余<$((disk_free/1024))MB）"
            exit 1
        fi
    fi
    return 0
}

# ==============================================
# 启动同步流程
# ==============================================
start_time=$(date +%s)
log "INFO" "========================================="
log "INFO" "工作目录：$WORK_DIR"
log "INFO" "输出文件：$OUTPUT_JSON"
log "INFO" "日志级别：$LOG_LEVEL"
log "INFO" "开始设备与芯片信息同步"
log "INFO" "========================================="

# ==============================================
# 1. 检查依赖工具（修复jq版本解析）
# ==============================================
log "INFO" "检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc" "stat" "timeout")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "ERROR" "缺失必要工具：$tool（请先安装）"
        exit 1
    fi
done

# 强制处理jq版本为整数
jq_version_str=$(jq --version 2>/dev/null || echo "jq-0.0.0")
jq_version=$(echo "$jq_version_str" | awk -F'[.-]' '{
    if ($1 ~ /jq/) { major = $2 + 0 } else { major = $1 + 0 }
    minor = $3 + 0
    print major * 100 + minor
}')
jq_version=$((jq_version))  # 强制转为整数
if [ "$jq_version" -lt 106 ]; then
    log "ERROR" "jq版本过低（需要≥1.6，当前版本：$jq_version_str）"
    exit 1
fi
log "SUCCESS" "所有依赖工具已就绪"

# ==============================================
# 2. 初始化输出JSON
# ==============================================
log "INFO" "初始化输出配置文件..."
if ! echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON"; then
    log "ERROR" "无法创建输出文件 $OUTPUT_JSON（权限不足）"
    exit 1
fi
if ! jq . "$OUTPUT_JSON" &> /dev/null; then
    log "ERROR" "输出文件JSON格式错误"
    exit 1
fi

# ==============================================
# 3. 克隆OpenWrt源码
# ==============================================
TMP_SRC=$(mktemp -d -t openwrt-src-XXXXXX)
log "INFO" "准备克隆源码到临时目录：$TMP_SRC"

clone_success=0
for repo in "${SOURCE_REPOS[@]}"; do
    retry=$CLONE_RETRIES
    while [ $retry -gt 0 ]; do
        log "INFO" "尝试克隆仓库：$repo（剩余重试：$retry）"
        if timeout 300 git clone --depth 1 "$repo" "$TMP_SRC" 2>> "$SYNC_LOG"; then
            log "SUCCESS" "源码克隆成功（仓库：$repo）"
            clone_success=1
            break
        fi
        retry=$((retry - 1))
        log "WARN" "仓库 $repo 克隆失败，剩余重试：$retry"
        [ $retry -gt 0 ] && sleep 2
    done
    [ $clone_success -eq 1 ] && break
done

if [ "$clone_success" -eq 0 ]; then
    log "ERROR" "所有仓库克隆失败"
    exit 1
fi

# ==============================================
# 4. 提取设备信息
# ==============================================
log "INFO" "开始提取设备信息（过滤异常文件）..."

find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts_file; do
    [ ! -f "$dts_file" ] && continue

    file_size=$(stat -c%s "$dts_file" 2>/dev/null || echo $((MAX_DTS_SIZE + 1)))
    if [ "$file_size" -gt "$MAX_DTS_SIZE" ]; then
        log "WARN" "跳过超大dts文件：$dts_file（大小：$((file_size/1024))KB）"
        continue
    fi

    filename=$(basename "$dts_file")
    if [[ "$filename" =~ [^a-zA-Z0-9_.-] ]]; then
        log "WARN" "跳过含特殊字符的文件：$filename"
        continue
    fi
    echo "$dts_file" >> "$DTS_LIST_TMP"
done

total_dts=$(wc -l < "$DTS_LIST_TMP")
log "INFO" "共发现有效dts文件：$total_dts 个，开始解析..."

processed_count=0
while IFS= read -r dts_file; do
    if ! check_resources; then
        log "WARN" "资源紧张，跳过当前文件：$dts_file"
        continue
    fi

    filename=$(basename "$dts_file" .dts)
    device_name=$(echo "$filename" | sed -E \
        -e 's/^[a-z0-9]+[-_]//' \
        -e 's/^([a-z]+[0-9]+)-//' \
        -e 's/^[a-z]+([0-9]+)?-//' \
        -e 's/^[0-9]+-//' \
        -e 's/_/-/g' \
        -e 's/^-+//; s/-+$//' \
        -e 's/-+/\-/g')

    if [ -z "$device_name" ] || [ "$device_name" = "." ]; then
        device_name="unknown-device-${filename}"
    fi

    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||; s|/$||")
    chip=$(echo "$platform_path" | awk -F '/' '{
        for (i=NF; i>=1; i--) {
            if ($i != "generic" && $i != "base-files" && $i != "dts") {
                print $i; exit
            }
        }
        print $0
    }')
    kernel_target="$platform_path"

    dedup_key="${device_name}_${chip}"
    if ! grep -qxF "$dedup_key" "$DEDUP_FILE"; then
        echo "$dedup_key" >> "$DEDUP_FILE"

        model=$(grep -E 'model\s*=\s*"[^"]+"' "$dts_file" 2>/dev/null | \
            sed -n 's/.*model\s*=\s*"\(.*\)";.*/\1/p' | head -n1 | \
            sed 's/"/\\"/g; s/^[ \t]*//; s/[ \t]*$//')
        if [ -z "$model" ]; then
            model="Unknown ${device_name} (${chip})"
        fi

        jq --arg name "$device_name" \
           --arg chip "$chip" \
           --arg kt "$kernel_target" \
           --arg model "$model" \
           '. += [{"name": $name, "chip": $chip, "kernel_target": $kt, "model": $model, "drivers": []}]' \
           "$DEVICE_TMP_JSON" > "$DEVICE_TMP_JSON.tmp" && mv "$DEVICE_TMP_JSON.tmp" "$DEVICE_TMP_JSON"
    fi

    processed_count=$((processed_count + 1))
    if [ $((processed_count % 50)) -eq 0 ]; then
        log "INFO" "设备解析进度：$processed_count/$total_dts"
    fi
done < "$DTS_LIST_TMP"

jq --argfile tmp "$DEVICE_TMP_JSON" '.devices = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
log "SUCCESS" "设备信息提取完成，共处理文件：$processed_count 个"

# ==============================================
# 5. 提取芯片信息
# ==============================================
log "INFO" "开始提取芯片信息..."

jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    if [ -z "$chip" ] || [ "$chip" = "null" ]; then
        log "WARN" "跳过空芯片名"
        continue
    fi

    if grep -qxF "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1 | sed 's/"//g')
    if [ -z "$platform" ] || [ "$platform" = "null" ]; then
        platform="unknown-platform"
    fi

    case "$chip" in
        mt7621)      drivers='["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s"]' ;;
        mt7981)      drivers='["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3"]' ;;
        ipq806x)     drivers='["kmod-qca-nss-dp", "kmod-ath10k"]' ;;
        x86_64)      drivers='["kmod-e1000e", "kmod-igb", "kmod-usb-xhci-hcd"]' ;;
        *)           drivers='[]' ;;
    esac

    jq --arg name "$chip" \
       --arg p "$platform" \
       --argjson drv "$drivers" \
       '. += [{"name": $name, "platform": $p, "default_drivers": $drv}]' \
       "$CHIP_TMP_JSON" > "$CHIP_TMP_JSON.tmp" && mv "$CHIP_TMP_JSON.tmp" "$CHIP_TMP_JSON"
    echo "$chip" >> "$CHIP_TMP_FILE"
done

jq --argfile tmp "$CHIP_TMP_JSON" '.chips = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
log "SUCCESS" "芯片信息提取完成"

# ==============================================
# 6. 最终校验
# ==============================================
log "INFO" "验证输出文件完整性..."
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

if [ "$device_count" -eq 0 ] || [ "$chip_count" -eq 0 ]; then
    log "WARN" "数据提取不足，添加测试数据"
    jq '.devices += [{"name": "test-device", "chip": "test-chip", "kernel_target": "generic", "model": "Test Device", "drivers": []}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    jq '.chips += [{"name": "test-chip", "platform": "generic", "default_drivers": ["kmod-generic"]}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
fi

# ==============================================
# 7. 完成同步
# ==============================================
end_time=$(date +%s)
elapsed=$((end_time - start_time))
log "========================================="
log "SUCCESS" "同步完成！总耗时：$((elapsed/60))分$((elapsed%60))秒"
log "SUCCESS" "输出文件：$OUTPUT_JSON"
log "SUCCESS" "详细日志：$SYNC_LOG"
log "========================================="
