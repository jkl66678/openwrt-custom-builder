#!/bin/bash
set -uo pipefail

# ==============================================
# 基础配置
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"
# 新增：OpenWrt packages仓库（驱动源）
PKG_REPO="https://git.openwrt.org/feed/packages.git"
TMP_PKGS=$(mktemp -d)  # 临时存放驱动包源码

mkdir -p "$LOG_DIR" || { echo "❌ 无法创建日志目录" >&2; exit 1; }
> "$SYNC_LOG"

log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$SYNC_LOG"
}

# ==============================================
# 启动同步
# ==============================================
log "========================================="
log "📌 工作目录：$WORK_DIR"
log "📌 输出文件：$OUTPUT_JSON"
log "📥 开始OpenWrt设备同步（自动匹配最新驱动）"
log "========================================="

# ==============================================
# 1. 检查依赖
# ==============================================
log "🔍 检查依赖工具..."
REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ 缺失工具：$tool"
        exit 1
    fi
done
log "✅ 依赖齐全"

# ==============================================
# 2. 初始化JSON
# ==============================================
log "🔧 初始化配置文件..."
echo '{"devices": [], "chips": [], "drivers": [], "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'"}}' > "$OUTPUT_JSON" || {
    log "❌ 无法创建输出文件"
    exit 1
}

# ==============================================
# 3. 克隆源码（核心新增：同步驱动包仓库）
# ==============================================
# 克隆OpenWrt主源码
TMP_SRC=$(mktemp -d)
log "📥 克隆OpenWrt主源码到临时目录：$TMP_SRC"
retries=5
while [ $retries -gt 0 ]; do
    if git clone --depth 10 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
        log "✅ 主源码克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 主源码克隆失败，剩余重试：$retries"
    sleep 3
done
if [ $retries -eq 0 ]; then
    log "❌ 主源码克隆失败"
    exit 1
fi

# 克隆驱动包仓库（获取最新驱动信息）
log "📥 克隆OpenWrt packages仓库（驱动源）到：$TMP_PKGS"
retries=5
while [ $retries -gt 0 ]; do
    if git clone --depth 10 "$PKG_REPO" "$TMP_PKGS" 2>> "$SYNC_LOG"; then
        log "✅ 驱动包仓库克隆成功"
        break
    fi
    retries=$((retries - 1))
    log "⚠️ 驱动包仓库克隆失败，剩余重试：$retries"
    sleep 3
done
if [ $retries -eq 0 ]; then
    log "❌ 驱动包仓库克隆失败"
    exit 1
fi

# ==============================================
# 4. 提取设备信息（保留具体芯片型号）
# ==============================================
log "🔍 提取设备信息..."
declare -A PROCESSED_DEVICES
BATCH_SIZE=1000
TMP_BATCH_DIR="$LOG_DIR/device_batches"
mkdir -p "$TMP_BATCH_DIR" && rm -rf "$TMP_BATCH_DIR"/*

# 收集设备文件
find "$TMP_SRC/target/linux" \( -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \
    -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \
    -o -name "*.board" -o -name "*.profile" \) > "$LOG_DIR/device_files.tmp"

total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
log "ℹ️ 共发现 $total_files 个设备文件"
if [ "$total_files" -eq 0 ]; then
    log "❌ 未找到设备文件"
    exit 1
fi

# 分批处理设备
split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"
for batch_file in "$TMP_BATCH_DIR"/batch_*; do
    [ -f "$batch_file" ] || continue
    batch_name=$(basename "$batch_file")
    log "ℹ️ 处理批次：$batch_name"

    while IFS= read -r file; do
        [ -f "$file" ] || { log "⚠️ 跳过不存在文件：$file"; continue; }

        set +e
        file_ext=$(echo "$file" | awk -F '.' '{if (NF>1) print $NF; else print "none"}')
        device_names=""
        chip=""
        vendor=""

        case "$file_ext" in
            dts|dtsi|dtso)
                model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                        sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//')
                compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                            sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g')
                device_names="$model $compatible"
                vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                chip=$(echo "$compatible" | grep -oE '[a-z0-9]+,[a-z0-9-]+' | awk -F ',' '{print $2}' | head -n1)
                ;;

            mk|Makefile)
                device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g')
                vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d')
                chip=$(grep -E '^SOC[[:space:]]*:=' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/SOC[[:space:]]*:=[[:space:]]*//; s/["'\'']//g' | head -n1)
                ;;

            conf|config)
                device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                              sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g')
                chip=$(grep -E '^CONFIG_TARGET_[a-z0-9-]+=y' "$file" 2>> "$SYNC_LOG" | 
                      sed -E 's/CONFIG_TARGET_//; s/=y//' | head -n1)
                ;;
        esac

        # 从路径补充芯片型号
        platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
        chip_from_dir=$(echo "$platform_path" | awk -F '/' '{if (NF >= 2) print $2; else print $1}')
        chip=${chip:-$chip_from_dir}
        chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g')

        # 处理设备名
        for name in $device_names; do
            [ -z "$name" ] && continue
            device_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | 
                         sed -E 's/[_,:;\/]+/-/g; s/[^a-z0-9 -]//g; s/[[:space:]]+/-/g; s/--+/-/g')
            [ -z "$device_name" ] && continue

            if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                PROCESSED_DEVICES["$device_name"]=1
                jq --arg name "$device_name" \
                   --arg chip "$chip" \
                   --arg vendor "$vendor" \
                   --arg kt "$platform_path" \
                   '.devices += [{"name": $name, "chip": $chip, "vendor": $vendor, "kernel_target": $kt, "drivers": []}]' \
                   "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
                log "ℹ️ 提取设备：$device_name（芯片：$chip）"
            fi
        done
        set -uo pipefail
    done < "$batch_file"
done

rm -f "$LOG_DIR/device_files.tmp"
device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
log "✅ 设备提取完成，共 $device_count 个"

# ==============================================
# 5. 提取芯片信息
# ==============================================
log "🔍 提取芯片信息..."
jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | grep -v '^$' > "$LOG_DIR/all_chips.tmp"
chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
if [ "$chip_count_total" -eq 0 ]; then
    log "❌ 未提取到任何芯片"
    exit 1
fi

# 写入芯片基础信息
while read -r chip; do
    platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | 
                sort | uniq | tr '\n' ',' | sed 's/,$//')
    vendors=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$OUTPUT_JSON" | 
              sort | uniq | tr '\n' ',' | sed 's/,$//')
    jq --arg name "$chip" --arg p "$platforms" --arg v "$vendors" \
       '.chips += [{"name": $name, "platforms": $p, "vendors": $v, "default_drivers": []}]' \
       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
done < "$LOG_DIR/all_chips.tmp"

final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
log "✅ 芯片提取完成，共 $final_chip_count 个"

# ==============================================
# 6. 核心功能：自动匹配最新驱动（新增逻辑）
# ==============================================
log "🔍 从packages仓库提取最新驱动信息..."

# 6.1 解析驱动包元数据（从Makefile提取芯片兼容性和版本）
log "ℹ️ 解析驱动包元数据（可能需要几分钟）..."
DRIVER_TMP="$LOG_DIR/driver_metadata.tmp"
> "$DRIVER_TMP"

# 扫描所有kmod驱动包（内核模块）
find "$TMP_PKGS/kernel" -name "Makefile" -type f | while read -r pkg_makefile; do
    # 提取驱动名称（如kmod-mt76）
    pkg_name=$(grep -E '^PKG_NAME:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/PKG_NAME:=//')
    [ -z "$pkg_name" ] && continue

    # 提取最新版本
    pkg_version=$(grep -E '^PKG_VERSION:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/PKG_VERSION:=//')
    [ -z "$pkg_version" ] && pkg_version="unknown"

    # 提取适用芯片（从描述或依赖中解析）
    pkg_desc=$(grep -E '^TITLE:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/TITLE:=//; s/[^a-zA-Z0-9 ,-]//g')
    pkg_deps=$(grep -E '^DEPENDS:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/DEPENDS:=//')
    
    # 从描述和依赖中提取芯片关键词（如mt76、ipq、ath10k）
    compatible_chips=$(echo "$pkg_desc $pkg_deps" | 
                      grep -oE '(mt|ipq|qca|rtl|ath|bcm|sun|exynos|imx)[0-9-]+' | 
                      sort | uniq | tr '\n' ',' | sed 's/,$//')

    # 写入临时驱动表
    if [ -n "$compatible_chips" ]; then
        echo "$pkg_name|$pkg_version|$compatible_chips|$pkg_desc" >> "$DRIVER_TMP"
    fi
done

log "ℹ️ 共解析到 $(wc -l < "$DRIVER_TMP") 个驱动包元数据"
if [ $(wc -l < "$DRIVER_TMP") -eq 0 ]; then
    log "⚠️ 未找到任何驱动包，将跳过驱动匹配"
else
    # 6.2 将驱动信息写入JSON
    log "ℹ️ 写入驱动信息到JSON..."
    while IFS='|' read -r name version chips desc; do
        jq --arg n "$name" --arg v "$version" --arg c "$chips" --arg d "$desc" \
           '.drivers += [{"name": $n, "version": $v, "compatible_chips": $c, "description": $d}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    done < "$DRIVER_TMP"

    # 6.3 为芯片匹配驱动（核心关联逻辑）
    log "ℹ️ 为芯片自动匹配最新驱动..."
    jq -r '.chips[].name' "$OUTPUT_JSON" | while read -r chip; do
        # 查找与芯片兼容的驱动（芯片名包含驱动支持的关键词）
        compatible_drivers=$(jq -r --arg chip "$chip" '
            .drivers[] | 
            select( (.compatible_chips | split(",") | index($chip)) or 
                    ($chip | contains(.compatible_chips | split(",")[])) ) |
            .name + "@" + .version
        ' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | sort | uniq | tr '\n' ',' | sed 's/,$//')

        if [ -n "$compatible_drivers" ]; then
            # 将驱动列表转换为JSON数组
            drivers_array=$(echo "$compatible_drivers" | sed -E 's/([^,]+)/"\1"/g; s/,/", "/g; s/^/[/; s/$/]/')
            # 更新芯片的默认驱动
            jq --arg chip "$chip" --argjson drivers "$drivers_array" \
               '.chips[] |= (if .name == $chip then .default_drivers = $drivers else . end)' \
               "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
            log "ℹ️ 芯片 $chip 匹配驱动：$compatible_drivers"
        fi
    done

    # 6.4 为设备关联芯片的驱动
    log "ℹ️ 为设备关联驱动..."
    jq -c '.devices[]' "$OUTPUT_JSON" | while read -r device; do
        device_name=$(echo "$device" | jq -r '.name')
        chip=$(echo "$device" | jq -r '.chip')
        # 获取芯片对应的驱动
        drivers=$(jq --arg c "$chip" '.chips[] | select(.name == $c) | .default_drivers' "$OUTPUT_JSON" 2>> "$SYNC_LOG")
        # 更新设备的驱动列表
        jq --arg name "$device_name" --argjson d "$drivers" \
           '.devices[] |= (if .name == $name then .drivers = $d else . end)' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    done
fi

# ==============================================
# 7. 清理与完成
# ==============================================
rm -rf "$TMP_SRC" "$TMP_PKGS" "$TMP_BATCH_DIR" "$LOG_DIR"/*.tmp
log "========================================="
log "✅ 同步完成：设备 $device_count 个，芯片 $final_chip_count 个"
log "📊 驱动匹配：共 $(jq '.drivers | length' "$OUTPUT_JSON") 个驱动包"
log "📄 配置文件：$OUTPUT_JSON"
log "========================================="
