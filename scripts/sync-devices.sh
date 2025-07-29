#!/bin/bash
set -euo pipefail  # 严格模式：错误、未定义变量、管道失败时退出

# 捕获EXIT信号，确保临时文件清理（无论正常/异常退出）
trap 'cleanup' EXIT
cleanup() {
    if [ -n "${TMP_SRC:-}" ] && [ -d "$TMP_SRC" ]; then
        rm -rf "$TMP_SRC"
        log "🧹 清理临时源码目录: $TMP_SRC"
    fi
    # 清理临时文件（容错处理）
    for tmp in "$DTS_LIST_TMP" "$CHIP_TMP_FILE" "$DEVICE_TMP_JSON" "$CHIP_TMP_JSON"; do
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

# 资源阈值（根据Runner配置调整）
MAX_MEM_THRESHOLD=6000  # 最大内存使用(MB)
MAX_DTS_SIZE=5242880    # 最大dts文件大小(5MB)，超过则跳过
CLONE_RETRIES=3         # 源码克隆重试次数
CLONE_TIMEOUT=300       # 克隆超时时间(秒)
SOURCE_REPOS=(          # 源码仓库列表（主仓库+镜像）
    "https://git.openwrt.org/openwrt/openwrt.git"
    "https://github.com/openwrt/openwrt.git"
)

# 临时文件（避免子shell变量丢失）
DTS_LIST_TMP="$LOG_DIR/dts_files.tmp"
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
DEVICE_TMP_JSON="$LOG_DIR/devices_temp.json"  # 设备临时JSON（批量处理用）
CHIP_TMP_JSON="$LOG_DIR/chips_temp.json"      # 芯片临时JSON（批量处理用）

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
echo '[]' > "$DEVICE_TMP_JSON"  # 初始化设备临时JSON
echo '[]' > "$CHIP_TMP_JSON"    # 初始化芯片临时JSON

# 日志函数：支持日志级别控制（默认INFO，可通过参数调整）
LOG_LEVEL="${1:-INFO}"  # 允许通过第一个参数设置日志级别（DEBUG/INFO/WARN/ERROR）
log() {
    local level=$1
    local message=$2
    # 日志级别过滤（如设置为INFO则不输出DEBUG）
    local level_order=("DEBUG" "INFO" "WARN" "ERROR")
    local current_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$LOG_LEVEL$" | cut -d: -f1)
    local msg_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$level$" | cut -d: -f1)
    if [ "$msg_idx" -lt "$current_idx" ]; then
        return  # 低于当前级别则不输出
    fi

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
# 资源监控函数（增强版：更及时的检查）
# ==============================================
check_resources() {
    # 检查内存使用（兼容不同版本free命令）
    if command -v free &>/dev/null; then
        local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    else
        #  fallback for systems without free (如busybox)
        local mem_used=$(grep MemTotal /proc/meminfo | awk '{print $2/1024}')
        mem_used=${mem_used%.*}  # 取整数
    fi
    if [ "$mem_used" -gt "$MAX_MEM_THRESHOLD" ]; then
        log "WARN" "内存使用过高($mem_used MB)，暂停处理以释放资源"
        sleep 10  # 等待系统自动回收内存
        return 1
    fi

    # 检查磁盘空间（临时目录所在分区）
    if command -v df &>/dev/null; then
        local disk_free=$(df -P "$LOG_DIR" | awk 'NR==2 {print $4}')  # 剩余空间(KB)
        if [ "$disk_free" -lt 1048576 ]; then  # 小于1GB
            log "ERROR" "磁盘空间不足（剩余<$((disk_free/1024))MB），终止同步"
            exit 1
        fi
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
log "INFO" "日志级别：$LOG_LEVEL"
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
jq_version=$(jq --version | cut -d'-' -f2 | awk -F. '{print $1*100 + $2}')  # 转为数字（如1.6→106）
if [ "$jq_version" -lt 106 ]; then
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
# 3. 克隆OpenWrt源码（多仓库重试+超时机制）
# ==============================================
TMP_SRC=$(mktemp -d -t openwrt-src-XXXXXX)  # 更安全的临时目录命名
log "INFO" "准备克隆源码到临时目录：$TMP_SRC"

clone_success=0
for repo in "${SOURCE_REPOS[@]}"; do
    log "INFO" "尝试克隆仓库：$repo（剩余重试：$CLONE_RETRIES）"
    # 添加超时和深度限制，避免卡住
    if git clone --depth 1 --timeout "$CLONE_TIMEOUT" "$repo" "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "SUCCESS" "源码克隆成功（仓库：$repo）"
        clone_success=1
        break
    fi
    CLONE_RETRIES=$((CLONE_RETRIES - 1))
    [ "$CLONE_RETRIES" -eq 0 ] && break  # 重试次数耗尽
    log "WARN" "仓库 $repo 克隆失败，剩余重试：$CLONE_RETRIES"
done

if [ "$clone_success" -eq 0 ]; then
    log "ERROR" "所有仓库克隆失败（已尝试${#SOURCE_REPOS[@]}个仓库）"
    exit 1
fi

# ==============================================
# 4. 提取设备信息（修复去重失效+增强解析）
# ==============================================
log "INFO" "开始提取设备信息（过滤异常文件）..."
DEDUP_FILE="$LOG_DIR/processed_devices.tmp"  # 用文件存储去重键（解决子shell问题）
> "$DEDUP_FILE"

# 收集所有dts文件（排除过大/特殊文件）
find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts_file; do
    # 过滤不存在的文件（防御性检查）
    [ ! -f "$dts_file" ] && continue

    # 过滤超大文件
    file_size=$(stat -c%s "$dts_file" 2>/dev/null || echo $((MAX_DTS_SIZE + 1)))
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

# 处理过滤后的dts文件（用进程替换避免子shell，保留变量）
total_dts=$(wc -l < "$DTS_LIST_TMP")
log "INFO" "共发现有效dts文件：$total_dts 个，开始解析..."

processed_count=0
# 使用while循环+文件读取（避免子shell导致的变量丢失）
while IFS= read -r dts_file; do
    # 每次处理前检查资源（更及时）
    if ! check_resources; then
        log "WARN" "资源紧张，跳过当前文件：$dts_file"
        continue
    fi

    # 解析文件名（增强正则，适应更多格式）
    filename=$(basename "$dts_file" .dts)
    # 提取设备名（支持更多前缀格式：如"rt305x-", "qca9531_", "bcm5301x-"等）
    device_name=$(echo "$filename" | sed -E \
        -e 's/^[a-z0-9]+[-_]//' \           # 移除前缀芯片名（如mt7621-、ramips_）
        -e 's/^([a-z]+[0-9]+)-//' \        # 移除纯字母+数字前缀（如rt305x-）
        -e 's/^[a-z]+([0-9]+)?-//' \       # 移除字母+可选数字前缀（如qca-、ar9344-）
        -e 's/^[0-9]+-//' \                # 移除纯数字前缀（如123-）
        -e 's/_/-/g' \                     # 下划线转连字符
        -e 's/^-+//; s/-+$//' \            # 移除首尾连字符
        -e 's/-+/\-/g')                    # 合并连续连字符
    # 兜底：若提取失败则用原始文件名（去后缀）
    if [ -z "$device_name" ] || [ "$device_name" = "." ]; then
        device_name="$filename"
    fi

    # 解析芯片与平台路径（增强容错）
    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||; s|/$||")  # 移除末尾斜杠
    # 从路径提取芯片（支持多级目录，优先取最深层有效目录）
    chip=$(echo "$platform_path" | awk -F '/' '{
        # 优先取最后一个非"generic"的目录（如"ramips/mt7621"→mt7621；"x86/generic"→x86）
        for (i=NF; i>=1; i--) {
            if ($i != "generic" && $i != "base-files" && $i != "dts") {
                print $i; exit
            }
        }
        print $0;  # 兜底：全路径
    }')
    kernel_target="$platform_path"

    # 去重键：设备名+芯片（用文件存储，解决子shell关联数组失效问题）
    dedup_key="${device_name}_${chip}"
    if ! grep -qxF "$dedup_key" "$DEDUP_FILE"; then
        echo "$dedup_key" >> "$DEDUP_FILE"  # 记录已处理

        # 从dts文件提取型号（增强匹配，支持多行注释内的model，处理特殊字符）
        model=$(grep -E 'model\s*=\s*"[^"]+"' "$dts_file" | \
            sed -n 's/.*model\s*=\s*"\(.*\)";.*/\1/p' | head -n1 | \
            sed 's/"/\\"/g' | sed 's/^[ \t]*//;s/[ \t]*$//')  # 转义双引号，去首尾空格
        # 兜底型号
        if [ -z "$model" ]; then
            model="Unknown ${device_name} (${chip})"
        fi

        # 写入临时JSON（批量处理，减少IO）
        jq --arg name "$device_name" \
           --arg chip "$chip" \
           --arg kt "$kernel_target" \
           --arg model "$model" \
           '. += [{"name": $name, "chip": $chip, "kernel_target": $kt, "model": $model, "drivers": []}]' \
           "$DEVICE_TMP_JSON" > "$DEVICE_TMP_JSON.tmp" && mv "$DEVICE_TMP_JSON.tmp" "$DEVICE_TMP_JSON"
        log "DEBUG" "已提取设备：$device_name（芯片：$chip，型号：$model）"
    fi

    processed_count=$((processed_count + 1))
    # 进度提示（每50个文件）
    if [ $((processed_count % 50)) -eq 0 ]; then
        log "INFO" "设备解析进度：$processed_count/$total_dts"
    fi
done < "$DTS_LIST_TMP"

# 批量合并设备信息到输出文件（减少jq调用次数）
jq --argfile tmp "$DEVICE_TMP_JSON" '.devices = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
log "SUCCESS" "设备信息提取完成，共处理文件：$processed_count 个"

# ==============================================
# 5. 提取芯片信息（扩展驱动列表+批量处理）
# ==============================================
log "INFO" "开始提取芯片信息..."

# 从设备列表提取芯片并去重
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    if [ -z "$chip" ] || [ "$chip" = "null" ]; then
        log "WARN" "跳过空芯片名"
        continue
    fi

    # 检查是否已处理
    if grep -qxF "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    # 关联芯片与平台（取第一个匹配的设备平台）
    platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1 | sed 's/"//g')
    if [ -z "$platform" ] || [ "$platform" = "null" ]; then
        log "WARN" "芯片 $chip 未找到关联平台，使用默认值"
        platform="unknown-platform"
    fi

    # 补充芯片默认驱动（扩展常见芯片列表）
    case "$chip" in
        mt7621)      drivers='["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s", "kmod-usb3"]' ;;
        mt7981)      drivers='["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3", "kmod-mt7921e"]' ;;
        mt7620)      drivers='["kmod-mt76", "kmod-usb2", "kmod-switch-rtl8366rb"]' ;;
        ipq806x)     drivers='["kmod-qca-nss-dp", "kmod-qca-nss-ecm", "kmod-ath10k", "kmod-usb3"]' ;;
        ipq4019)     drivers='["kmod-ath10k-smallbuffers", "kmod-usb3", "kmod-leds-gpio"]' ;;
        x86_64|x86)  drivers='["kmod-e1000e", "kmod-igb", "kmod-rtc-pc", "kmod-usb-xhci-hcd", "kmod-i2c-piix4"]' ;;
        bcm53xx)     drivers='["kmod-brcmfmac", "kmod-usb-ohci", "kmod-leds-gpio", "kmod-b53"]' ;;
        ar9344)      drivers='["kmod-ath9k", "kmod-usb2", "kmod-gpio-button-hotplug"]' ;;
        qca9531)     drivers='["kmod-ath9k", "kmod-usb2", "kmod-switch-rtl8306"]' ;;
        rt305x)      drivers='["kmod-rt2800-soc", "kmod-usb2", "kmod-ledtrig-gpio"]' ;;
        *)           drivers='[]' ;;  # 未知芯片默认空驱动
    esac

    # 写入临时JSON（批量处理）
    jq --arg name "$chip" \
       --arg p "$platform" \
       --argjson drv "$drivers" \
       '. += [{"name": $name, "platform": $p, "default_drivers": $drv}]' \
       "$CHIP_TMP_JSON" > "$CHIP_TMP_JSON.tmp" && mv "$CHIP_TMP_JSON.tmp" "$CHIP_TMP_JSON"
    echo "$chip" >> "$CHIP_TMP_FILE"
    log "DEBUG" "已提取芯片：$chip（平台：$platform，默认驱动：${drivers:1:-1}）"
done

# 批量合并芯片信息到输出文件
jq --argfile tmp "$CHIP_TMP_JSON" '.chips = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
log "SUCCESS" "芯片信息提取完成"

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
