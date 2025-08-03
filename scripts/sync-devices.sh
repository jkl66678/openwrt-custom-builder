#!/bin/bash
set -uo pipefail

# 编码设置
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# ==============================================
# 基础配置
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"

# 扩展驱动来源仓库
PKG_REPOS=(
    "https://git.openwrt.org/feed/packages.git"
    "https://git.openwrt.org/project/luci.git"
    "https://git.openwrt.org/feed/routing.git"
    "https://git.openwrt.org/feed/telephony.git"
    "https://github.com/coolsnowwolf/lede-packages.git"
    "https://github.com/immortalwrt/packages.git"
    "https://github.com/openwrt/packages.git"
)

TMP_SRC=$(mktemp -d -t openwrt-src-XXXXXX)
TMP_PKGS_BASE=$(mktemp -d -t openwrt-pkgs-XXXXXX)
TMP_BATCH_DIR="$LOG_DIR/device_batches"

mkdir -p "$LOG_DIR" "$TMP_BATCH_DIR" || { 
    echo "❌ 无法创建日志目录" >&2; 
    exit 1; 
}
> "$SYNC_LOG"

# ==============================================
# 工具函数
# ==============================================
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$timestamp" "$1" | tee -a "$SYNC_LOG"
}

cleanup() {
    log "🔧 清理临时资源..."
    [ -d "$TMP_SRC" ] && rm -rf "$TMP_SRC"
    [ -d "$TMP_PKGS_BASE" ] && rm -rf "$TMP_PKGS_BASE"
    [ -d "$TMP_BATCH_DIR" ] && rm -rf "$TMP_BATCH_DIR"
    find "$LOG_DIR" -name "*.tmp" -not -name "source_branches.tmp" -delete
    log "✅ 临时资源清理完成"
}
trap cleanup EXIT

# ==============================================
# 依赖检查
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file" "gcc" "iconv")
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具：$tool"
            exit 1
        fi
    done

    if ! jq --version &> /dev/null || [ "$(jq --version | cut -d' ' -f3 | cut -d'.' -f1)" -lt 1 ] || [ "$(jq --version | cut -d' ' -f3 | cut -d'.' -f2)" -lt 6 ]; then
        log "❌ 请安装jq 1.6+"
        exit 1
    fi

    if ! grep -E --help &> /dev/null; then
        log "❌ 请使用GNU grep"
        exit 1
    fi
    
    log "✅ 依赖工具检查通过"
}

# ==============================================
# 仓库克隆
# ==============================================
clone_repositories() {
    log "📥 克隆OpenWrt主源码..."
    local retries=3
    local timeout=300
    while [ $retries -gt 0 ]; do
        if timeout $timeout git clone --depth 10 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
            log "✅ 主源码克隆成功"
            break
        fi
        retries=$((retries - 1))
        log "⚠️ 主源码克隆失败，剩余重试：$retries"
        sleep 5
    done
    if [ $retries -eq 0 ]; then
        log "❌ 主源码克隆失败"
        exit 1
    fi

    log "📥 克隆扩展驱动仓库（共 ${#PKG_REPOS[@]} 个）..."
    local repo_idx=1
    for repo in "${PKG_REPOS[@]}"; do
        local repo_name=$(basename "$repo" .git)
        local repo_dir="$TMP_PKGS_BASE/$repo_name"
        
        retries=3
        while [ $retries -gt 0 ]; do
            if timeout $timeout git clone --depth 10 "$repo" "$repo_dir" 2>> "$SYNC_LOG"; then
                log "✅ 驱动仓库 $repo_idx/${#PKG_REPOS[@]} 克隆成功：$repo_name"
                break
            fi
            retries=$((retries - 1))
            log "⚠️ 驱动仓库 $repo_idx/${#PKG_REPOS[@]} 克隆失败（剩余重试：$retries）：$repo_name"
            sleep 5
        done
        if [ $retries -eq 0 ]; then
            log "⚠️ 驱动仓库 $repo_name 克隆失败，跳过"
        fi
        repo_idx=$((repo_idx + 1))
    done
}

# ==============================================
# 设备信息提取
# ==============================================
extract_devices() {
    log "🔍 提取设备信息..."
    declare -A PROCESSED_DEVICES
    local BATCH_SIZE=1000
    
    find "$TMP_SRC/target/linux" \( -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \
        -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \
        -o -name "*.board" -o -name "*.profile" \) > "$LOG_DIR/device_files.tmp"
    
    local total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
    log "ℹ️ 发现 $total_files 个设备相关文件"
    if [ "$total_files" -eq 0 ]; then
        log "❌ 未找到设备文件"
        exit 1
    fi

    split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"
    local processed=0
    
    for batch_file in "$TMP_BATCH_DIR"/batch_*; do
        [ -f "$batch_file" ] || continue
        local batch_name=$(basename "$batch_file")
        log "ℹ️ 处理批次：$batch_name"

        while IFS= read -r file; do
            [ -f "$file" ] || { log "⚠️ 跳过不存在文件：$file"; continue; }

            local file_ext=$(echo "$file" | awk -F '.' '{if (NF>1) print $NF; else print "none"}')
            local device_names=""
            local chip=""
            local vendor=""

            case "$file_ext" in
                dts|dtsi|dtso)
                    local model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    local compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                      sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g' |
                                      iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$model $compatible"
                    vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                    chip=$(echo "$compatible" | grep -oE '[a-z0-9]+,[a-z0-9-]+' | awk -F ',' '{print $2}' | head -n1)
                    ;;

                mk|Makefile)
                    device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d')
                    chip=$(grep -E '^SOC[[:space:]]*:=' "$file" 2>> "$SYNC_LOG" | 
                          sed -E 's/SOC[[:space:]]*:=[[:space:]]*//; s/["'\'']//g' | head -n1)
                    ;;

                conf|config)
                    device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    chip=$(grep -E '^CONFIG_TARGET_[a-z0-9-]+=y' "$file" 2>> "$SYNC_LOG" | 
                          sed -E 's/CONFIG_TARGET_//; s/=y//' | head -n1)
                    ;;
            esac

            local platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
            local chip_from_dir=$(echo "$platform_path" | awk -F '/' '{if (NF >= 2) print $2; else print $1}')
            chip=${chip:-$chip_from_dir}
            chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g')

            for name in $device_names; do
                [ -z "$name" ] && continue
                local device_name=$(echo "$name" | 
                                  sed -E 's/[_,:;\/]+/-/g; s/[^a-zA-Z0-9 一-龥-]//g; s/[[:space:]]+/-/g; s/--+/-/g')
                [ -z "$device_name" ] && continue

                if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                    PROCESSED_DEVICES["$device_name"]=1
                    jq --arg name "$device_name" \
                       --arg chip "$chip" \
                       --arg vendor "$vendor" \
                       --arg kt "$platform_path" \
                       '.devices += [{"name": $name, "chip": $chip, "vendor": $vendor, "kernel_target": $kt, "drivers": []}]' \
                       "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
                       [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
                       { log "⚠️ 设备 $device_name 写入失败"; rm -f "$OUTPUT_JSON.tmp"; }
                    log "ℹ️ 提取设备：$device_name（芯片：$chip）"
                fi
            done

            processed=$((processed + 1))
            [ $((processed % 100)) -eq 0 ] && log "ℹ️ 已处理 $processed/$total_files 个文件"
        done < "$batch_file"
    done

    rm -f "$LOG_DIR/device_files.tmp"
    local device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    log "✅ 设备提取完成，共 $device_count 个"
}

# ==============================================
# 芯片信息提取（优化版）
# ==============================================
extract_chips() {
    log "🔍 提取芯片信息..."
    jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | grep -v '^$' > "$LOG_DIR/all_chips.tmp"
    local chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
    
    if [ "$chip_count_total" -eq 0 ]; then
        log "❌ 未提取到任何芯片信息"
        exit 1
    fi

    while read -r chip; do
        # 扩展架构识别
        local arch=$(echo "$chip" | grep -oE 'armv[0-9]+|x86|x86_64|mips|mipsel|riscv|riscv64|powerpc|aarch64' | head -n1)
        # 扩展厂商系列识别
        local family=$(echo "$chip" | grep -oE 'bcm|brcm|mtk|ipq|qca|rtl|ath|rk|rockchip|sunxi|exynos|imx|mvebu|qualcomm|realtek|awm|zlt|zr|zte|huawei' | head -n1)
        # 补充：从芯片名前缀提取厂商
        if [ -z "$family" ]; then
            family=$(echo "$chip" | grep -oE '^[a-z0-9]+' | head -n1)
        fi
        
        local platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | 
                         sort | uniq | tr '\n' ',' | sed 's/,$//')
        local vendors=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$OUTPUT_JSON" | 
                       sort | uniq | tr '\n' ',' | sed 's/,$//')
        
        jq --arg name "$chip" --arg p "$platforms" --arg v "$vendors" \
           --arg arch "$arch" --arg family "$family" \
           '.chips += [{"name": $name, "platforms": $p, "vendors": $v, 
                        "architecture": $arch, "family": $family, "default_drivers": []}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
           [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
           { log "⚠️ 芯片 $chip 写入失败"; rm -f "$OUTPUT_JSON.tmp"; }
    done < "$LOG_DIR/all_chips.tmp"

    local final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    log "✅ 芯片提取完成，共 $final_chip_count 个"
}

# ==============================================
# 驱动匹配（增强版）
# ==============================================
match_drivers() {
    log "🔍 开始匹配驱动程序（扩展模式）..."
    local DRIVER_TMP="$LOG_DIR/driver_metadata.tmp"
    > "$DRIVER_TMP"

    log "ℹ️ 解析驱动包元数据（多仓库+多文件类型）..."
    (
        # 搜索所有克隆的驱动仓库
        find "$TMP_PKGS_BASE" \( -name "Makefile" -o -name "*.mk" \)
        
        # 搜索主源码中的驱动相关文件
        find "$TMP_SRC/package" \( -name "Makefile" -o -name "*.mk" \)
        find "$TMP_SRC/drivers" -name "*.c"
        find "$TMP_SRC/include/linux" -name "*.h"
    ) | grep -v -E 'doc/|test/|examples/|README' |
        while read -r pkg_file; do
        
        # 提取驱动基本信息
        local pkg_name=""
        local pkg_version="unknown"
        local pkg_desc=""
        local pkg_path=$(dirname "$pkg_file")

        # 根据文件类型解析
        if [[ "$pkg_file" == *.c || "$pkg_file" == *.h ]]; then
            # 从C源码中提取驱动名
            pkg_name=$(grep -E 'MODULE_NAME|DRIVER_NAME|MODULE_DESCRIPTION' "$pkg_file" 2>> "$SYNC_LOG" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
            [ -z "$pkg_name" ] && pkg_name=$(basename "$pkg_path")
            
            # 从源码中提取支持的设备/芯片
            pkg_desc=$(grep -E 'SUPPORTED_DEVICES|COMPATIBLE_DEVICES|DEVICE_TABLE' "$pkg_file" 2>> "$SYNC_LOG" | sed -E 's/.*"([^"]+)".*/\1/')
        else
            # 从Makefile/.mk中提取
            pkg_name=$(grep -E '^PKG_NAME:=' "$pkg_file" 2>> "$SYNC_LOG" | sed -E 's/PKG_NAME:=//')
            [ -z "$pkg_name" ] && pkg_name=$(basename "$pkg_path")
            
            pkg_version=$(grep -E '^PKG_VERSION:=' "$pkg_file" 2>> "$SYNC_LOG" | sed -E 's/PKG_VERSION:=//')
            pkg_desc=$(grep -E '^TITLE:=' "$pkg_file" 2>> "$SYNC_LOG" | sed 's/TITLE:=//')
        fi

        [ -z "$pkg_name" ] && continue

        # 提取兼容性信息
        local pkg_deps=$(grep -E '^DEPENDS:=' "$pkg_file" 2>> "$SYNC_LOG" | sed 's/DEPENDS:=//')
        local pkg_config=$(grep -E '^CONFIG_' "$pkg_file" 2>> "$SYNC_LOG" | sed 's/CONFIG_//')
        local pkg_source=$(grep -E '^PKG_SOURCE:=' "$pkg_file" 2>> "$SYNC_LOG" | sed 's/PKG_SOURCE:=//')
        local code_comments=$(grep -E '/\*.*\*/' "$pkg_file" 2>> "$SYNC_LOG" | sed -E 's/\/\*|\*\///g')

        # 合并所有关键词
        local supported_chips=$(echo "$pkg_desc $pkg_deps $pkg_config $pkg_source $code_comments $pkg_path" | 
                              grep -oE '[a-z0-9-]+' | grep -v -E '^$|make|file|git|tar|gz|zip' | sort | uniq | tr '\n' ',' | sed 's/,$//')
        local supported_arch=$(echo "$pkg_desc $pkg_deps $pkg_config $code_comments" | 
                             grep -oE 'armv[0-9]+|x86|x86_64|mips|mipsel|riscv|riscv64|powerpc|aarch64' | sort | uniq | tr '\n' ',' | sed 's/,$//')
        local supported_family=$(echo "$pkg_desc $pkg_deps $pkg_config $code_comments" | 
                               grep -oE 'bcm|brcm|mtk|ipq|qca|rtl|ath|rk|rockchip|sunxi|exynos|imx|mvebu|qualcomm|realtek|awm|zlt|zr|zte|huawei' | 
                               sort | uniq | tr '\n' ',' | sed 's/,$//')

        echo "$pkg_name|$pkg_version|$supported_chips|$supported_arch|$supported_family|$pkg_desc" >> "$DRIVER_TMP"
    done

    local driver_count_count=$(=$(wc -l < "$DRIVER_TMP")
    log "ℹ️ 共解析到 $driver_count 个驱动包元数据（扩展模式）"
    
    if [ "$driver_count" -eq 0 ]; then
        log "⚠️ 未找到任何驱动包，尝试无过滤搜索"
        (find "$TMP_PKGS_BASE" -name "Makefile" -type f;
         find "$TMP_SRC/package" -name "Makefile" -type f) | while read -r pkg_makefile; do
            local pkg_name=$(basename "$(dirname "$pkg_makefile")")
            [ -z "$pkg_name" ] && continue
            echo "$pkg_name|unknown|generic|all|all|最后尝试提取的驱动" >> "$DRIVER_TMP"
        done
        driver_count=$(wc -l < "$DRIVER_TMP")
        if [ "$driver_count" -eq 0 ]; then
            log "❌ 彻底未找到驱动包，请检查仓库克隆"
            return
        fi
    fi

    # 写入驱动信息到JSON
    jq '.drivers = []' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    
    while IFS='|' read -r name version chips arch family desc; do
        name=$(echo "$name" | sed -E 's/["\\]/\\&/g')
        desc=$(echo "$desc" | sed -E 's/["\\]/\\&/g')
        
        jq --arg n "$name" --arg v "$version" --arg c "$chips" \
           --arg a "$arch" --arg f "$family" --arg d "$desc" \
           '.drivers += [{"name": $n, "version": $v, 
                         "supported_chips": $c, 
                         "supported_arch": $a, 
                         "supported_family": $f, 
                         "description": $d}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
           [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
           { log "⚠️ 驱动 $name 写入失败"; rm -f "$OUTPUT_JSON.tmp"; }
    done < "$DRIVER_TMP"

    # 分级匹配驱动
    log "ℹ️ 为芯片自动匹配驱动（分级匹配）..."
    jq -r '.chips[] | .name + "|" + .architecture + "|" + .family' "$OUTPUT_JSON" | while IFS='|' read -r chip arch family; do
        log "ℹ️ 调试：芯片 $chip（架构：$arch，系列：$family）"
        
        # 1. 精确匹配
        local exact_matches=$(jq --arg chip "$chip" '
            [.drivers[] | 
            select(.supported_chips | split(",") | index($chip)) |
            .name + "@" + .version] | unique
        ' "$OUTPUT_JSON" 2>> "$SYNC_LOG")

        # 2. 系列匹配
        local family_matches="[]"
        if [ "$(echo "$exact_matches" | jq length)" -eq 0 ] && [ -n "$family" ]; then
            family_matches=$(jq --arg family "$family" '
                [.drivers[] | 
                select(.supported_family | split(",") | index($family)) |
                .name + "@" + .version] | unique
            ' "$OUTPUT_JSON" 2>> "$SYNC_LOG")
        fi

        # 3. 架构匹配
        local arch_matches="[]"
        if [ "$(echo "$exact_matches" | jq length)" -eq 0 ] && 
           [ "$(echo "$family_matches" | jq length)" -eq 0 ] && 
           [ -n "$arch" ]; then
            arch_matches=$(jq --arg arch "$arch" '
                [.drivers[] | 
                select(.supported_arch | split(",") | index($arch)) |
                .name + "@" + .version] | unique
            ' "$OUTPUT_JSON" 2>> "$SYNC_LOG")
        fi

        # 4. 通用驱动（放宽条件）
        local generic_matches="[]"
        if [ "$(echo "$exact_matches" | jq length)" -eq 0 ] && 
           [ "$(echo "$family_matches" | jq length)" -eq 0 ] && 
           [ "$(echo "$arch_matches" | jq length)" -eq 0 ]; then
            generic_matches=$(jq '
                [.drivers[] | 
                select(
                    .supported_chips | split(",") | index("generic") or 
                    .supported_chips | split(",") | index("common") or
                    .supported_chips | split(",") | index("base") or
                    .name | contains("core") or .name | contains("base")
                ) |
                .name + "@" + .version] | unique
            ' "$OUTPUT_JSON" 2>> "$SYNC_LOG")
        fi

        # 合并结果
        local drivers_array=$(jq -n --argjson e "$exact_matches" \
                                   --argjson f "$family_matches" \
                                   --argjson a "$arch_matches" \
                                   --argjson g "$generic_matches" \
                                   '$e + $f + $a + $g | unique')

        # 验证JSON格式
        if ! echo "$drivers_array" | jq . > /dev/null 2>&1; then
            log "⚠️ 芯片 $chip 驱动数组无效，已修复"
            drivers_array="[]"
        fi

        # 更新芯片的驱动列表
        if ! jq --arg chip "$chip" --argjson drivers "$drivers_array" \
           '.chips[] |= (if .name == $chip then .default_drivers = $drivers else . end)' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" 2>> "$SYNC_LOG"; then
            log "⚠️ 芯片 $chip 驱动更新失败"
            rm -f "$OUTPUT_JSON.tmp"
        else
            [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
        fi
        
        # 显示匹配统计
        local e_count=$(echo "$exact_matches" | jq length 2>/dev/null || echo 0)
        local f_count=$(echo "$family_matches" | jq length 2>/dev/null || echo 0)
        local a_count=$(echo "$arch_matches" | jq length 2>/dev/null || echo 0)
        local g_count=$(echo "$generic_matches" | jq length 2>/dev/null || echo 0)
        log "ℹ️ 芯片 $chip 匹配驱动数：总=$((e_count + f_count + a_count + g_count))（精确=$e_count, 系列=$f_count, 架构=$a_count, 通用=$g_count）"
    done

    # 为设备关联驱动
    log "ℹ️ 为设备关联驱动..."
    jq -c '.devices[]' "$OUTPUT_JSON" | while read -r device; do
        local device_name=$(echo "$device" | jq -r '.name')
        local chip=$(echo "$device" | jq -r '.chip')
        local drivers=$(jq --arg c "$chip" '.chips[] | select(.name == $c) | .default_drivers' "$OUTPUT_JSON" 2>> "$SYNC_LOG")
        
        jq --arg name "$device_name" --argjson d "$drivers" \
           '.devices[] |= (if .name == $name then .drivers = $d else . end)' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
           [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
           { log "⚠️ 设备 $device_name 驱动关联失败"; rm -f "$OUTPUT_JSON.tmp"; }
    done
}

# ==============================================
# 核心功能配置生成
# ==============================================
generate_core_features() {
    log "🔍 生成核心功能配置..."
    local core_features_file="configs/core-features.json"
    local tmp_features=$(mktemp -t openwrt-features-XXXXXX)
    mkdir -p "$(dirname "$core_features_file")"
    
    find "$TMP_SRC/package" -name "Makefile" | grep -E 'accelerate|ipv6|qos|nat|flow|vpn|wifi' | while read -r file; do
        grep -E 'TITLE|DESCRIPTION' "$file" | grep -oE 'ipv6|accel|accelerate|qos|nat|flow|vpn|wifi' | 
        tr '[:upper:]' '[:lower:]' | sort | uniq
    done >> "$tmp_features"
    
    cat <<EOF >> "$tmp_features"
ipv6
accel
qos
nat
flow
vpn
wifi
none
EOF
    
    if [ -f "$core_features_file" ]; then
        jq -r '.features[]' "$core_features_file" 2>/dev/null | while read -r user_feat; do
            if ! grep -q "$user_feat" "$tmp_features" && [ "$user_feat" != "none" ] && [ -n "$user_feat" ]; then
                echo "$user_feat" >> "$tmp_features"
                log "ℹ️ 保留用户自定义功能：$user_feat"
            fi
        done
    fi
    
    sort -u "$tmp_features" | grep -v '^$' > "$tmp_features.uniq"
    local basic_features=$(cat "$tmp_features.uniq" | tr '\n' ' ')
    
    echo '{"features": [' > "$core_features_file"
    local first=1
    
    echo '  "none"' >> "$core_features_file"
    first=0
    
    for feat in $basic_features; do
        [ "$feat" = "none" ] && continue
        [ $first -eq 0 ] && echo ',' >> "$core_features_file"
        first=0
        echo "  \"$feat-only\"" >> "$core_features_file"
    done
    
    local feats_array=($basic_features)
    for i in "${!feats_array[@]}"; do
        for j in $(seq $((i+1)) $(( ${#feats_array[@]} - 1 )) ); do
            [ $first -eq 0 ] && echo ',' >> "$core_features_file"
            first=0
            echo "  \"${feats_array[$i]}+${feats_array[$j]}\"" >> "$core_features_file"
        done
    done
    
    echo ']}' >> "$core_features_file"
    
    if ! jq . "$core_features_file" &> /dev/null; then
        log "⚠️ 核心功能配置JSON格式错误，尝试修复"
        sed -i ':a;N;$!ba;s/,\n]/\n]/' "$core_features_file"
    fi
    
    log "✅ 核心功能配置生成完成，共 $(jq '.features | length' "$core_features_file" 2>/dev/null || echo 0) 个选项"
    rm -f "$tmp_features" "$tmp_features.uniq"
}

# ==============================================
# 主题发现与优化配置
# ==============================================
discover_themes() {
    local themes_dir=$(mktemp -d -t openwrt-themes-XXXXXX)
    local theme_list=$(mktemp -t openwrt-theme-list-XXXXXX)
    
    local theme_repos=(
        "https://github.com/jerrykuku/luci-theme-argon.git"
        "https://github.com/LuttyYang/luci-theme-material.git"
        "https://github.com/openwrt/luci.git"
        "https://github.com/rosywrt/luci-theme-rosy.git"
        "https://github.com/thinktip/luci-theme-neobird.git"
    )
    
    for repo in "${theme_repos[@]}"; do
        local repo_name=$(basename "$repo" .git)
        if git clone --depth 1 "$repo" "$themes_dir/$repo_name" 2>> "$SYNC_LOG"; then
            if [ "$repo_name" = "luci" ]; then
                find "$themes_dir/$repo_name/themes" -name "luci-theme-*" | while read -r theme_path; do
                    local name=$(basename "$theme_path" | sed 's/luci-theme-//')
                    [ -n "$name" ] && echo "$name" >> "$theme_list"
                done
            else
                local name=$(grep -E '^PKG_NAME:=' "$themes_dir/$repo_name/Makefile" 2>> "$SYNC_LOG" | 
                            sed -E 's/PKG_NAME:=luci-theme-//; s/-/_/g')
                [ -n "$name" ] && echo "$name" >> "$theme_list"
            fi
        fi
    done
    
    sort -u "$theme_list" > "$theme_list.uniq"
    echo "$theme_list.uniq"
    
    rm -rf "$themes_dir" "$theme_list"
}

generate_theme_optimizations() {
    log "🔍 生成主题+优化配置..."
    local theme_opt_file="configs/theme-optimizations.json"
    local theme_list_path=$(discover_themes)
    mkdir -p "$(dirname "$theme_opt_file")"
    
    local gcc_opts=$(gcc --help=optimizers 2>/dev/null | 
                    grep -E -- ' -O[0-9s]|--param=O[0-9s]' | 
                    grep -oE 'O[0-9s]' | 
                    sort | uniq)
    [ -z "$gcc_opts" ] && gcc_opts="O0 O1 O2 O3 Os"
    
    local architectures=$(jq -r '.devices[].kernel_target' "$OUTPUT_JSON" 2>/dev/null | 
                         grep -oE 'armv8|x86|generic|mips|armv7' | sort | uniq | tr '\n' ' ')
    [ -z "$architectures" ] && architectures="generic x86 armv8 mips"
    
    if [ -f "$theme_opt_file" ]; then
        jq -r '.themes[].name' "$theme_opt_file" 2>/dev/null | while read -r user_theme; do
            if [ -n "$user_theme" ] && ! grep -q "$user_theme" "$theme_list_path"; then
                echo "$user_theme" >> "$theme_list_path"
                log "ℹ️ 保留用户自定义主题：$user_theme"
            fi
        done
    fi
    
    echo '{"themes": [' > "$theme_opt_file"
    local first=1
    
    while read -r theme; do
        [ -z "$theme" ] && continue
        
        local theme_arches=$architectures
        local theme_opts=$gcc_opts
        
        case "$theme" in
            "bootstrap") theme_opts="O2";;
            "material") theme_arches="generic x86 armv8";;
            "argon") theme_opts="O2 O3";;
            "rosy") theme_opts="O2";;
        esac
        
        local arch_array=$(echo "$theme_arches" | tr ' ' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        local opts_array=$(echo "$theme_opts" | tr ' ' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        
        [ $first -eq 0 ] && echo "," >> "$theme_opt_file"
        first=0
        
        echo "  {" >> "$theme_opt_file"
        echo "    \"name\": \"$theme\"," >> "$theme_opt_file"
        echo "    \"architectures\": [$arch_array]," >> "$theme_opt_file"
        echo "    \"opts\": [$opts_array]" >> "$theme_opt_file"
        echo "  }" >> "$theme_opt_file"
    done < "$theme_list_path"
    
    echo ']}' >> "$theme_opt_file"
    
    if ! jq . "$theme_opt_file" &> /dev/null; then
        log "⚠️ 主题配置JSON格式错误，尝试修复"
        sed -i ':a;N;$!ba;s/,\n  }/\n  }/' "$theme_opt_file"
    fi
    
    local theme_count=$(jq '.themes | length' "$theme_opt_file" 2>/dev/null || echo 0)
    log "✅ 主题+优化配置生成完成，共 $theme_count 个主题"
    rm -f "$theme_list_path"
}

# ==============================================
# 源码分支同步
# ==============================================
sync_source_branches() {
    log "🔍 同步源码分支..."
    local branches_file="$LOG_DIR/source_branches.tmp"
    > "$branches_file"

    local repo_list=(
        "openwrt|https://git.openwrt.org/openwrt/openwrt.git"
        "immortalwrt|https://github.com/immortalwrt/immortalwrt.git"
    )

    for repo in "${repo_list[@]}"; do
        local repo_prefix=$(echo "$repo" | cut -d'|' -f1)
        local repo_url=$(echo "$repo" | cut -d'|' -f2)
        local temp_branch=$(mktemp -t ${repo_prefix}-branches-XXXXXX)
        
        log "ℹ️ 获取 $repo_prefix 分支..."
        local retries=3
        local success=0

        while [ $retries -gt 0 ]; do
            > "$temp_branch"
            git ls-remote --heads "$repo_url" 2>> "$SYNC_LOG" | 
                grep -E 'openwrt-[0-9]+\.[0-9]+|master|main|dev' | 
                sed -E "s/.*refs\/heads\///; s/^/$repo_prefix-/" >> "$temp_branch"

            if [ -s "$temp_branch" ]; then
                log "✅ $repo_prefix 分支获取成功（$(wc -l < "$temp_branch") 个）"
                cat "$temp_branch" >> "$branches_file"
                success=1
                break
            fi

            retries=$((retries - 1))
            log "⚠️ $repo_prefix 分支获取失败，剩余重试：$retries"
            sleep 3
        done

        rm -f "$temp_branch"

        if [ $success -eq 0 ]; then
            log "❌ 无法获取 $repo_prefix 分支"
            exit 1
        fi
    done

    sort -u "$branches_file" | sort -r > "$branches_file.tmp" && mv "$branches_file.tmp" "$branches_file"

    if [ ! -s "$branches_file" ]; then
        log "❌ 分支文件生成失败"
        exit 1
    fi
    
    log "✅ 源码分支同步完成，共 $(wc -l < "$branches_file") 个有效分支"
}

# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt设备同步系统启动（扩展驱动模式）"
log "📅 同步时间：$(date +"%Y-%m-%d %H:%M:%S")"
log "========================================="

echo '{"devices": [], "chips": [], "drivers": [], "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'"}}' > "$OUTPUT_JSON"

check_dependencies
clone_repositories
extract_devices
extract_chips
match_drivers
generate_core_features
generate_theme_optimizations
sync_source_branches

log "========================================="
log "✅ 所有同步任务完成"
log "📊 设备总数：$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 芯片总数：$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 驱动总数：$(jq '.drivers | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "========================================="
