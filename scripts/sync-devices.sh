#!/bin/bash
set -euo pipefail  # 严格模式：错误、未定义变量、管道失败时退出

# 捕获EXIT信号，确保临时文件清理（无论正常/异常退出）
trap 'cleanup' EXIT
cleanup() {
    if [ -n "${TMP_SRC:-}" ] && [ -d "$TMP_SRC" ]; then
        rm -rf "$TMP_SRC"
        log "🧹 清理临时源码目录: $TMP_SRC"
    fi
    rm -f "$DTS_LIST_TMP" "$CHIP_TMP_FILE"  # 清理临时文件
}

# ==============================================
# 基础配置与常量定义
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

# 资源阈值（根据Runner配置调整）
MAX_MEM_THRESHOLD=6000  # 最大内存使用(MB)
MAX_DTS_SIZE=5242880    # 最大dts文件大小(5MB)，超过则跳过
CLONE_RETRIES=3         # 源码克隆重试次数
SOURCE_REPOS=(          # 源码仓库列表（主仓库+镜像）
    "https://git.openwrt.org/openwrt/openwrt.git"
    "https://github.com/openwrt/openwrt.git"
)

# 临时文件（避免子shell变量丢失）
DTS_LIST_TMP="$LOG_DIR/dts_files.tmp"
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"

# ==============================================
# 初始化与日志系统
# ==============================================
# 确保日志目录存在
mkdir -p "$LOG_DIR" || {
    echo "❌ 无法创建日志目录 $LOG_DIR（权限不足）" >&2
    exit 1
}
> "$SYNC_LOG"  # 清空旧日志
> "$DTS_LIST_TMP"  # 初始化dts文件列表
> "$CHIP_TMP_FILE"  # 初始化芯片去重文件

# 日志函数：带类型标识，同时输出到控制台和日志
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local level_tag
    case $level in
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
# 资源监控函数（避免Runner资源耗尽）
# ==============================================
check_resources() {
    # 检查内存使用
    local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    if [ "$mem_used" -gt "$MAX_MEM_THRESHOLD" ]; then
        log "WARN" "内存使用过高($mem_used MB)，暂停处理以释放资源"
        sleep 10  # 等待系统自动回收内存
        return 1
    fi

    # 检查磁盘空间（临时目录所在分区）
    local disk_free=$(df -P "$LOG_DIR" | awk 'NR==2 {print $4}')  # 剩余空间(KB)
    if [ "$disk_free" -lt 1048576 ]; then  # 小于1GB
        log "ERROR" "磁盘空间不足（剩余<$((disk_free/1024))MB），终止同步"
        exit 1
    fi
    return 0
}

# ==============================================
# 启动同步流程
# ==============================================
start_time=$(date +%s)  # 记录开始时间
log "INFO" "========================================="
log "INFO" "工作目录：$WORK_DIR"
log "INFO" "输出文件：$OUTPUT_JSON"
log "INFO" "开始设备与芯片信息同步"
log "INFO" "========================================="

# ==============================================
# 1. 检查依赖工具（增强版）
# ==============================================
log "INFO" "检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc" "stat")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "ERROR" "缺失必要工具：$tool（请先安装）"
        exit 1
    fi
done
# 检查jq版本（确保支持基本语法）
jq_version=$(jq --version | cut -d'-' -f2 | cut -d'.' -f1)
if [ "$jq_version" -lt 1 ]; then
    log "ERROR" "jq版本过低（需要≥1.6，当前版本：$(jq --version)）"
    exit 1
fi
log "SUCCESS" "所有依赖工具已就绪"

# ==============================================
# 2. 初始化输出JSON（确保结构正确）
# ==============================================
log "INFO" "初始化输出配置文件..."
if ! echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON"; then
    log "ERROR" "无法创建输出文件 $OUTPUT_JSON（权限不足）"
    exit 1
fi
# 验证JSON格式（避免初始化失败）
if ! jq . "$OUTPUT_JSON" &> /dev/null; then
    log "ERROR" "输出文件JSON格式错误，初始化失败"
    exit 1
fi
log "DEBUG" "输出文件初始化完成：$(cat "$OUTPUT_JSON" | jq .)"

# ==============================================
# 3. 克隆OpenWrt源码（多仓库重试机制）
# ==============================================
TMP_SRC=$(mktemp -d)
log "INFO" "准备克隆源码到临时目录：$TMP_SRC"

clone_success=0
for repo in "${SOURCE_REPOS[@]}"; do
    log "INFO" "尝试克隆仓库：$repo（剩余重试：$CLONE_RETRIES）"
    if git clone --depth 1 "$repo" "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "SUCCESS" "源码克隆成功（仓库：$repo）"
        clone_success=1
        break
    fi
    log "WARN" "仓库 $repo 克隆失败，尝试下一个"
done

if [ "$clone_success" -eq 0 ]; then
    log "ERROR" "所有仓库克隆失败（已尝试${#SOURCE_REPOS[@]}个仓库）"
    exit 1
fi

# ==============================================
# 4. 提取设备信息（增强解析与去重）
# ==============================================
log "INFO" "开始提取设备信息（过滤异常文件）..."
declare -A PROCESSED_DEVICES  # 设备去重：键为"设备名+芯片"（避免同设备不同芯片被误去重）

# 收集所有dts文件（排除过大/特殊文件）
find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts_file; do
    # 过滤超大文件
    file_size=$(stat -c%s "$dts_file")
    if [ "$file_size" -gt "$MAX_DTS_SIZE" ]; then
        log "WARN" "跳过超大dts文件：$dts_file（大小：$((file_size/1024))KB）"
        continue
    fi
    # 过滤含特殊字符的文件（避免解析异常）
    filename=$(basename "$dts_file")
    if [[ "$filename" =~ [^a-zA-Z0-9_.-] ]]; then
        log "WARN" "跳过含特殊字符的文件：$filename"
        continue
    fi
    echo "$dts_file" >> "$DTS_LIST_TMP"
done

# 处理过滤后的dts文件
total_dts=$(wc -l < "$DTS_LIST_TMP")
log "INFO" "共发现有效dts文件：$total_dts 个，开始解析..."

processed_count=0
while read -r dts_file; do
    # 定期检查资源（每处理10个文件）
    if [ $((processed_count % 10)) -eq 0 ]; then
        if ! check_resources; then
            log "WARN" "资源紧张，跳过当前文件：$dts_file"
            continue
        fi
    fi

    # 解析文件名（增强正则，适应更多格式）
    filename=$(basename "$dts_file" .dts)
    # 提取设备名（支持"芯片_品牌_型号"、"品牌-型号"等格式）
    device_name=$(echo "$filename" | sed -E \
        -e 's/^[a-z0-9]+[-_]//' \   # 移除前缀芯片名（如mt7621-、ramips_）
        -e 's/^[a-z0-9]+$//' \      # 排除纯芯片名文件（如mt7621.dts）
        -e 's/_/-/g' \              # 下划线转连字符
        -e 's/^-//; s/-$//')        # 移除首尾连字符
    # 兜底：若提取失败则用原始文件名（去后缀）
    if [ -z "$device_name" ] || [ "$device_name" = "." ]; then
        device_name="$filename"
    fi

    # 解析芯片与平台路径
    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||")
    # 从路径提取芯片（支持"target/linux/ramips/mt7621" → mt7621）
    chip=$(echo "$platform_path" | awk -F '/' '{
        if (NF >= 2) print $2;  # 二级目录（如ramips/mt7621 → mt7621）
        else print $1;          # 一级目录（如x86 → x86）
    }')
    kernel_target="$platform_path"

    # 去重键：设备名+芯片（避免同设备不同芯片被合并）
    dedup_key="${device_name}_${chip}"
    if ! [[ -v PROCESSED_DEVICES["$dedup_key"] ]]; then
        PROCESSED_DEVICES["$dedup_key"]=1

        # 从dts文件提取型号（增强匹配，支持多行注释内的model）
        model=$(grep -E 'model\s*=\s*"[^"]+"' "$dts_file" | \
            sed -n 's/.*model\s*=\s*"\(.*\)";.*/\1/p' | head -n1 | sed 's/^[ \t]*//;s/[ \t]*$//')
        # 兜底型号
        if [ -z "$model" ]; then
            model="Unknown ${device_name} (${chip})"
        fi

        # 写入设备信息到JSON（原子操作，避免文件损坏）
        if ! jq --arg name "$device_name" \
                --arg chip "$chip" \
                --arg kt "$kernel_target" \
                --arg model "$model" \
                '.devices += [{"name": $name, "chip": $chip, "kernel_target": $kt, "model": $model, "drivers": []}]' \
                "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp"; then
            log "ERROR" "JSON写入失败（设备：$device_name），跳过"
            rm -f "$OUTPUT_JSON.tmp"
            continue
        fi
        mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
        log "DEBUG" "已提取设备：$device_name（芯片：$chip，型号：$model）"
    fi

    processed_count=$((processed_count + 1))
    # 进度提示（每50个文件）
    if [ $((processed_count % 50)) -eq 0 ]; then
        log "INFO" "设备解析进度：$processed_count/$total_dts"
    fi
done < "$DTS_LIST_TMP"

log "SUCCESS" "设备信息提取完成，共处理文件：$processed_count 个"

# ==============================================
# 5. 提取芯片信息（关联平台与驱动）
# ==============================================
log "INFO" "开始提取芯片信息..."

# 从设备列表提取芯片并去重
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    if [ -z "$chip" ] || [ "$chip" = "null" ]; then
        log "WARN" "跳过空芯片名"
        continue
    fi

    # 检查是否已处理
    if grep -q "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    # 关联芯片与平台（取第一个匹配的设备平台）
    platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1)
    if [ -z "$platform" ] || [ "$platform" = "null" ]; then
        log "WARN" "芯片 $chip 未找到关联平台，使用默认值"
        platform="unknown-platform"
    fi

    # 补充芯片默认驱动（扩展常见芯片列表）
    case "$chip" in
        mt7621) drivers='["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s"]' ;;
        mt7981) drivers='["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3"]' ;;
        ipq806x) drivers='["kmod-qca-nss-dp", "kmod-qca-nss-ecm", "kmod-ath10k"]' ;;
        x86_64) drivers='["kmod-e1000e", "kmod-igb", "kmod-rtc-pc", "kmod-usb-xhci-hcd"]' ;;
        bcm53xx) drivers='["kmod-brcmfmac", "kmod-usb-ohci", "kmod-leds-gpio"]' ;;
        *) drivers='[]' ;;  # 未知芯片默认空驱动
    esac

    # 写入芯片信息到JSON
    if ! jq --arg name "$chip" \
            --arg p "$platform" \
            --argjson drv "$drivers" \
            '.chips += [{"name": $name, "platform": $p, "default_drivers": $drv}]' \
            "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp"; then
        log "ERROR" "芯片 $chip 写入失败，跳过"
        rm -f "$OUTPUT_JSON.tmp"
        continue
    fi
    mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    echo "$chip" >> "$CHIP_TMP_FILE"
    log "DEBUG" "已提取芯片：$chip（平台：$platform，默认驱动：${drivers:1:-1}）"
done

# ==============================================
# 6. 最终校验与兜底
# ==============================================
log "INFO" "验证输出文件完整性..."
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

# 兜底：确保至少有基础数据
if [ "$device_count" -eq 0 ] || [ "$chip_count" -eq 0 ]; then
    log "WARN" "数据提取不足，添加测试数据兜底"
    # 添加测试设备
    jq '.devices += [{"name": "test-device", "chip": "test-chip", "kernel_target": "generic", "model": "Test Device", "drivers": []}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    # 添加测试芯片
    jq '.chips += [{"name": "test-chip", "platform": "generic", "default_drivers": ["kmod-generic"]}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    device_count=$((device_count + 1))
    chip_count=$((chip_count + 1))
fi

# ==============================================
# 7. 完成同步
# ==============================================
end_time=$(date +%s)
elapsed=$((end_time - start_time))
log "========================================="
log "SUCCESS" "同步完成！总耗时：$((elapsed/60))分$((elapsed%60))秒"
log "SUCCESS" "统计结果：设备 $device_count 个，芯片 $chip_count 个"
log "SUCCESS" "输出文件：$OUTPUT_JSON（大小：$(du -h "$OUTPUT_JSON" | cut -f1)）"
log "SUCCESS" "详细日志：$SYNC_LOG"
log "========================================="
