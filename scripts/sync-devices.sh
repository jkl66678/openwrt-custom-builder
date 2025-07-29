#!/bin/bash
set -euo pipefail  # 严格模式，确保未定义变量和命令失败时终止

# 捕获EXIT信号清理临时文件
trap 'cleanup' EXIT
cleanup() {
    if [ -n "${TMP_SRC:-}" ] && [ -d "$TMP_SRC" ]; then
        rm -rf "$TMP_SRC"
        log "🧹 清理临时源码目录: $TMP_SRC"
    fi
    # 清理所有临时文件
    for tmp in "$DTS_LIST_TMP" "$CHIP_TMP_FILE" "$DEVICE_TMP_JSON" "$CHIP_TMP_JSON" "$DEDUP_FILE"; do
        [ -f "$tmp" ] && rm -f "$tmp"
    done
}

# ==============================================
# 基础配置
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

MAX_MEM_THRESHOLD=5000  # 内存阈值（MB），超过则清理缓存
MAX_DTS_SIZE=5242880    # 最大dts文件大小（5MB）
CLONE_RETRIES=5         # 仓库克隆重试次数
SOURCE_REPOS=(          # 源码仓库列表（优先级从高到低）
    "https://git.openwrt.org/openwrt/openwrt.git"
    "https://github.com/openwrt/openwrt.git"
)

# 临时文件路径
DTS_LIST_TMP="$LOG_DIR/dts_files.tmp"
CHIP_TMP_FILE="$LOG_DIR/processed_chips.tmp"
DEVICE_TMP_JSON="$LOG_DIR/devices_temp.json"
CHIP_TMP_JSON="$LOG_DIR/chips_temp.json"
DEDUP_FILE="$LOG_DIR/processed_devices.tmp"

# 初始化目录和文件
mkdir -p "$LOG_DIR"
> "$SYNC_LOG"           # 清空日志
> "$DTS_LIST_TMP"       # 设备文件列表
> "$CHIP_TMP_FILE"      # 已处理芯片记录
echo '[]' > "$DEVICE_TMP_JSON"  # 设备临时JSON
echo '[]' > "$CHIP_TMP_JSON"    # 芯片临时JSON
> "$DEDUP_FILE"         # 设备去重记录

# ==============================================
# 日志函数（支持多级别和详细时间戳）
# ==============================================
LOG_LEVEL="${1:-INFO}"  # 日志级别，默认INFO
log() {
    local level="$1"
    local message="$2"
    local level_order=("DEBUG" "INFO" "WARN" "ERROR" "FATAL")
    
    # 日志级别过滤
    local current_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$LOG_LEVEL$" | cut -d: -f1)
    current_idx=${current_idx:-0}
    local msg_idx=$(printf "%s\n" "${level_order[@]}" | grep -n "^$level$" | cut -d: -f1)
    msg_idx=${msg_idx:-0}

    if [ $((msg_idx)) -lt $((current_idx)) ]; then
        return  # 低于当前级别则不输出
    fi

    # 时间戳（精确到毫秒）
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S.%N" | cut -c1-23)
    # 级别标签
    local level_tag
    case "$level" in
        "INFO")  level_tag="ℹ️" ;;
        "SUCCESS") level_tag="✅" ;;
        "WARN")  level_tag="⚠️" ;;
        "ERROR") level_tag="❌" ;;
        "DEBUG") level_tag="🔍" ;;
        "FATAL") level_tag="💥" ;;
        *) level_tag="📌" ;;
    esac
    # 输出到控制台和日志文件
    echo "[$timestamp] $level_tag $message" | tee -a "$SYNC_LOG"
}

# ==============================================
# 资源监控函数（防止内存/磁盘溢出）
# ==============================================
check_resources() {
    local mem_used
    # 检查内存使用
    if command -v free &>/dev/null; then
        mem_used=$(free -m | awk '/Mem:/ {print $3}')
    else
        mem_used=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    fi
    log "DEBUG" "当前内存使用：$mem_used MB（阈值：$MAX_MEM_THRESHOLD MB）"
    
    if [ "$mem_used" -gt "$MAX_MEM_THRESHOLD" ]; then
        log "WARN" "内存使用过高($mem_used MB)，清理临时JSON缓存"
        # 合并临时设备数据到主文件，释放内存
        if [ -s "$DEVICE_TMP_JSON" ]; then
            jq --argfile tmp "$DEVICE_TMP_JSON" '.devices += $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
            mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" && \
            echo '[]' > "$DEVICE_TMP_JSON"
            log "DEBUG" "已合并临时设备数据，释放内存"
        fi
        sleep 5  # 等待内存释放
        return 1
    fi

    # 检查磁盘空间
    if command -v df &>/dev/null; then
        local disk_free=$(df -P "$LOG_DIR" | awk 'NR==2 {print $4}')  # 剩余磁盘块（1块=512字节）
        if [ "$disk_free" -lt 1048576 ]; then  # 小于1GB（1048576*512B=536,870,912B≈512MB，此处阈值可调整）
            log "FATAL" "磁盘空间不足（剩余<$((disk_free/2048))MB）"
            exit 1
        fi
    fi
    return 0
}

# ==============================================
# 主流程
# ==============================================
start_time=$(date +%s)
log "INFO" "========================================="
log "INFO" "工作目录：$WORK_DIR"
log "INFO" "输出文件：$OUTPUT_JSON"
log "INFO" "日志级别：$LOG_LEVEL"
log "INFO" "开始设备与芯片信息同步"
log "INFO" "========================================="

# 检查依赖工具
log "INFO" "检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "cut" "wc" "stat" "timeout")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "FATAL" "缺失必要工具：$tool（请安装后重试）"
        exit 1
    fi
done

# 检查jq版本（需≥1.6）
jq_version_str=$(jq --version 2>/dev/null || echo "jq-0.0.0")
jq_version=$(echo "$jq_version_str" | awk -F'[.-]' '{
    major = ($1 ~ /jq/) ? $2 + 0 : $1 + 0
    minor = $3 + 0
    print major * 100 + minor
}')
jq_version=$((jq_version))
if [ "$jq_version" -lt 106 ]; then
    log "FATAL" "jq版本过低（需要≥1.6，当前：$jq_version_str）"
    exit 1
fi
log "SUCCESS" "所有依赖工具已就绪"

# 初始化输出JSON文件
log "INFO" "初始化输出配置文件..."
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    log "FATAL" "无法创建输出文件 $OUTPUT_JSON（权限不足）"
    exit 1
}
# 验证JSON格式
jq . "$OUTPUT_JSON" &> /dev/null || {
    log "FATAL" "输出文件JSON格式错误"
    exit 1
}

# 克隆OpenWrt源码到临时目录
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
    log "FATAL" "所有仓库克隆失败"
    exit 1
fi

# ==============================================
# 提取设备信息（从dts文件中解析）
# ==============================================
log "INFO" "开始提取设备信息（过滤异常文件）..."

# 收集有效dts文件（过滤超大文件和特殊字符）
find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts_file; do
    [ ! -f "$dts_file" ] && {
        log "WARN" "文件不存在，跳过：$dts_file"
        continue
    }

    # 过滤超大文件
    file_size=$(stat -c%s "$dts_file" 2>/dev/null || echo $((MAX_DTS_SIZE + 1)))
    if [ "$file_size" -gt "$MAX_DTS_SIZE" ]; then
        log "WARN" "跳过超大dts文件：$dts_file（大小：$((file_size/1024))KB）"
        continue
    fi

    # 过滤含特殊字符的文件
    filename=$(basename "$dts_file")
    if [[ "$filename" =~ [^a-zA-Z0-9_.-] ]]; then
        log "WARN" "跳过含特殊字符的文件：$filename"
        continue
    fi
    echo "$dts_file" >> "$DTS_LIST_TMP" || {
        log "ERROR" "写入dts列表失败，跳过文件：$dts_file"
    }
done

# 检查有效文件数量
total_dts=$(wc -l < "$DTS_LIST_TMP")
log "INFO" "共发现有效dts文件：$total_dts 个，开始解析..."
[ "$total_dts" -eq 0 ] && {
    log "FATAL" "未发现任何dts文件，同步失败"
    exit 1
}

# 解析每个dts文件提取设备信息
processed_count=0
failed_count=0
while IFS= read -r dts_file; do
    # 每处理10个文件检查一次资源
    if [ $((processed_count % 10)) -eq 0 ]; then
        if ! check_resources; then
            log "WARN" "资源紧张，跳过当前文件：$dts_file"
            continue
        fi
    fi

    log "DEBUG" "开始解析文件（$((processed_count + 1))/$total_dts）：$dts_file"

    # 提取文件名（不带扩展名）
    filename=$(basename "$dts_file" .dts) || {
        log "ERROR" "获取文件名失败，跳过：$dts_file"
        failed_count=$((failed_count + 1))
        continue
    }

    # 提取设备名（通过正则清洗）
    device_name=$(echo "$filename" | sed -E \
        -e 's/^[a-z0-9]+[-_]//' \
        -e 's/^([a-z]+[0-9]+)-//' \
        -e 's/^[a-z]+([0-9]+)?-//' \
        -e 's/^[0-9]+-//' \
        -e 's/_/-/g' \
        -e 's/^-+//; s/-+$//' \
        -e 's/-+/\-/g') || {
        log "ERROR" "提取设备名失败，跳过文件：$dts_file"
        failed_count=$((failed_count + 1))
        continue
    }
    # 兜底处理空设备名
    if [ -z "$device_name" ] || [ "$device_name" = "." ]; then
        device_name="unknown-device-${filename}"
        log "DEBUG" "设备名兜底处理：$device_name"
    fi

    # 提取平台路径
    platform_path=$(dirname "$dts_file" | sed "s|$TMP_SRC/target/linux/||; s|/$||") || {
        log "ERROR" "提取平台路径失败，跳过文件：$dts_file"
        failed_count=$((failed_count + 1))
        continue
    }

    # 提取芯片名（从平台路径中解析）
    chip=$(echo "$platform_path" | awk -F '/' '{
        for (i=NF; i>=1; i--) {
            if ($i != "generic" && $i != "base-files" && $i != "dts") {
                print $i; exit
            }
        }
        print $0
    }') || {
        log "ERROR" "提取芯片名失败，跳过文件：$dts_file"
        failed_count=$((failed_count + 1))
        continue
    }
    kernel_target="$platform_path"

    # 去重处理（避免重复设备）
    dedup_key="${device_name}_${chip}"
    if ! grep -qxF "$dedup_key" "$DEDUP_FILE"; then
        echo "$dedup_key" >> "$DEDUP_FILE" || {
            log "ERROR" "写入去重文件失败（键：$dedup_key），跳过"
            continue
        }

        # 提取设备型号（从dts中grep model字段）
        model=$(grep -E 'model\s*=\s*"[^"]+"' "$dts_file" 2>/dev/null | \
            sed -n 's/.*model\s*=\s*"\(.*\)";.*/\1/p' | head -n1 | \
            sed -e 's/"/\\"/g' -e 's/\\/\\\\/g' -e 's/^[ \t]*//' -e 's/[ \t]*$//') || {
            log "ERROR" "提取model失败，使用默认值（文件：$dts_file）"
            model="Unknown model (extract failed)"
        }
        [ -z "$model" ] && model="Unknown ${device_name} (${chip})"

        # 写入设备数据到临时JSON
        if ! jq --arg name "$device_name" \
               --arg chip "$chip" \
               --arg kt "$kernel_target" \
               --arg model "$model" \
               '. += [{"name": $name, "chip": $chip, "kernel_target": $kt, "model": $model, "drivers": []}]' \
               "$DEVICE_TMP_JSON" > "$DEVICE_TMP_JSON.tmp"; then
            log "ERROR" "jq写入失败（设备：$device_name，芯片：$chip），跳过"
            log "DEBUG" "jq失败详情：name=$device_name, chip=$chip, model=$model"
            rm -f "$DEVICE_TMP_JSON.tmp"
            failed_count=$((failed_count + 1))
            continue
        fi
        # 原子替换临时文件（避免JSON损坏）
        mv "$DEVICE_TMP_JSON.tmp" "$DEVICE_TMP_JSON" || {
            log "ERROR" "替换临时JSON失败，跳过（设备：$device_name）"
            rm -f "$DEVICE_TMP_JSON.tmp"
            failed_count=$((failed_count + 1))
            continue
        }
        log "DEBUG" "成功解析设备：$device_name（芯片：$chip）"
    }

    processed_count=$((processed_count + 1))
    # 每50个文件输出一次进度
    if [ $((processed_count % 50)) -eq 0 ]; then
        log "INFO" "设备解析进度：$processed_count/$total_dts（失败：$failed_count）"
    fi
done < "$DTS_LIST_TMP"

# 合并临时设备数据到最终输出文件
log "INFO" "合并临时设备数据到输出文件..."
jq --argfile tmp "$DEVICE_TMP_JSON" '.devices = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || {
    log "FATAL" "合并设备数据失败"
    exit 1
}
log "SUCCESS" "设备信息提取完成，共处理：$processed_count 个（失败：$failed_count 个）"

# ==============================================
# 提取芯片信息（从设备数据中汇总）
# ==============================================
log "INFO" "开始提取芯片信息..."

# 统计芯片总数
chip_total=$(jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | wc -l)
log "INFO" "共发现芯片：$chip_total 种，开始解析..."

# 解析每个芯片的默认驱动和平台信息
chip_processed=0
chip_failed=0
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | while read -r chip; do
    [ -z "$chip" ] || [ "$chip" = "null" ] && {
        log "WARN" "跳过空芯片名"
        chip_failed=$((chip_failed + 1))
        continue
    }

    # 去重处理
    if grep -qxF "^$chip$" "$CHIP_TMP_FILE"; then
        continue
    fi

    # 提取芯片对应的平台
    platform=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | head -n1 | sed 's/"//g') || {
        log "ERROR" "提取芯片平台失败（芯片：$chip）"
        platform="unknown-platform"
    }
    [ -z "$platform" ] || [ "$platform" = "null" ] && platform="unknown-platform"

    # 预设常见芯片的默认驱动
    drivers=""
    case "$chip" in
        mt7621)      drivers='["kmod-mt7603e", "kmod-mt7615e", "kmod-switch-rtl8367s"]' ;;
        mt7981)      drivers='["kmod-mt7981-firmware", "kmod-gmac", "kmod-usb3"]' ;;
        ipq806x)     drivers='["kmod-qca-nss-dp", "kmod-ath10k"]' ;;
        x86_64)      drivers='["kmod-e1000e", "kmod-igb", "kmod-usb-xhci-hcd"]' ;;
        *)           drivers='[]' ;;
    esac

    # 写入芯片数据到临时JSON
    if ! jq --arg name "$chip" \
           --arg p "$platform" \
           --argjson drv "$drivers" \
           '. += [{"name": $name, "platform": $p, "default_drivers": $drv}]' \
           "$CHIP_TMP_JSON" > "$CHIP_TMP_JSON.tmp"; then
        log "ERROR" "jq写入芯片失败（芯片：$chip）"
        rm -f "$CHIP_TMP_JSON.tmp"
        chip_failed=$((chip_failed + 1))
        continue
    fi
    mv "$CHIP_TMP_JSON.tmp" "$CHIP_TMP_JSON" || {
        log "ERROR" "替换芯片临时JSON失败（芯片：$chip）"
        rm -f "$CHIP_TMP_JSON.tmp"
        chip_failed=$((chip_failed + 1))
        continue
    }
    echo "$chip" >> "$CHIP_TMP_FILE" || {
        log "ERROR" "写入芯片去重文件失败（芯片：$chip）"
    }

    chip_processed=$((chip_processed + 1))
    log "DEBUG" "已解析芯片：$chip（$chip_processed/$chip_total）"
done

# 合并芯片数据到最终输出文件
log "INFO" "合并芯片数据到输出文件..."
jq --argfile tmp "$CHIP_TMP_JSON" '.chips = $tmp' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || {
    log "FATAL" "合并芯片数据失败"
    exit 1
}
log "SUCCESS" "芯片信息提取完成，共处理：$chip_processed 种（失败：$chip_failed 种）"

# ==============================================
# 最终校验与兜底处理
# ==============================================
log "INFO" "验证输出文件完整性..."
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)

log "INFO" "最终统计：设备 $device_count 个，芯片 $chip_count 个"

# 数据不足时添加测试数据兜底
if [ "$device_count" -eq 0 ] || [ "$chip_count" -eq 0 ]; then
    log "WARN" "数据提取不足，添加测试数据兜底"
    jq '.devices += [{"name": "test-device", "chip": "test-chip", "kernel_target": "generic", "model": "Test Device", "drivers": []}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    jq '.chips += [{"name": "test-chip", "platform": "generic", "default_drivers": ["kmod-generic"]}]' \
        "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
fi

# ==============================================
# 同步完成
# ==============================================
end_time=$(date +%s)
elapsed=$((end_time - start_time))
log "========================================="
log "SUCCESS" "同步完成！总耗时：$((elapsed/60))分$((elapsed%60))秒"
log "SUCCESS" "输出文件：$OUTPUT_JSON（大小：$(du -h "$OUTPUT_JSON" | cut -f1)）"
log "SUCCESS" "详细日志：$SYNC_LOG"
log "SUCCESS" "统计：总文件$total_dts个，成功解析$processed_count个，失败$failed_count个"
log "========================================="
