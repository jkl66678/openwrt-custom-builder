#!/bin/bash
set -uo pipefail

# 强制UTF-8编码（解决中文乱码核心配置）
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# ==============================================
# 基础配置与初始化（修复变量名笔误）
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"  # 修复：修正变量名（原OUTPUTPUT_JSON）
SYNC_LOG="$LOG_DIR/sync-detail.log"
PKG_REPO="https://git.openwrt.org/feed/packages.git"  # 驱动包仓库
TMP_SRC=$(mktemp -d -t openwrt-src-XXXXXX)            # 主源码临时目录
TMP_PKGS=$(mktemp -d -t openwrt-pkgs-XXXXXX)          # 驱动包临时目录
TMP_BATCH_DIR="$LOG_DIR/device_batches"               # 设备文件批处理目录

# 创建必要目录（确保权限正确）
mkdir -p "$LOG_DIR" "$TMP_BATCH_DIR" || { 
    echo "❌ 无法创建日志目录（权限不足）" >&2; 
    exit 1; 
}
> "$SYNC_LOG"  # 清空日志

# 日志函数（确保中文正常输出，避免截断）
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    # 使用printf确保特殊字符不被转义
    printf "[%s] %s\n" "$timestamp" "$1" | tee -a "$SYNC_LOG"
}

# 临时资源清理函数（确保安全删除）
cleanup() {
    log "🔧 开始清理临时资源..."
    # 仅删除脚本创建的临时目录，避免误删系统文件
    [ -d "$TMP_SRC" ] && rm -rf "$TMP_SRC"
    [ -d "$TMP_PKGS" ] && rm -rf "$TMP_PKGS"
    [ -d "$TMP_BATCH_DIR" ] && rm -rf "$TMP_BATCH_DIR"
    find "$LOG_DIR" -name "*.tmp" -delete
    log "✅ 临时资源清理完成"
}
trap cleanup EXIT  # 确保脚本退出时执行清理

# ==============================================
# 1. 依赖检查（新增编码工具检查）
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    # 新增iconv确保编码转换支持
    REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file" "gcc" "iconv")
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具：$tool（可能导致中文乱码或功能异常）"
            exit 1
        fi
    done
    
    # 检查jq版本（确保支持JSON操作）
    if ! jq --version &> /dev/null; then
        log "❌ jq工具版本不兼容，请安装jq 1.6+"
        exit 1
    fi
    
    log "✅ 依赖工具检查通过"
}

# ==============================================
# 2. 克隆源码仓库（增加超时控制）
# ==============================================
clone_repositories() {
    # 克隆OpenWrt主源码
    log "📥 克隆OpenWrt主源码..."
    local retries=3
    local timeout=300  # 5分钟超时
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
        log "❌ 主源码克隆失败（超时或网络问题）"
        exit 1
    fi

    # 克隆驱动包仓库
    log "📥 克隆OpenWrt packages仓库（驱动源）..."
    retries=3
    while [ $retries -gt 0 ]; do
        if timeout $timeout git clone --depth 10 "$PKG_REPO" "$TMP_PKGS" 2>> "$SYNC_LOG"; then
            log "✅ 驱动包仓库克隆成功"
            break
        fi
        retries=$((retries - 1))
        log "⚠️ 驱动包仓库克隆失败，剩余重试：$retries"
        sleep 5
    done
    if [ $retries -eq 0 ]; then
        log "❌ 驱动包仓库克隆失败（超时或网络问题）"
        exit 1
    fi
}

# ==============================================
# 3. 提取设备信息（修复中文设备名处理）
# ==============================================
extract_devices() {
    log "🔍 开始提取设备信息..."
    declare -A PROCESSED_DEVICES
    local BATCH_SIZE=1000
    
    # 收集所有设备相关文件
    find "$TMP_SRC/target/linux" \( -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \
        -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \
        -o -name "*.board" -o -name "*.profile" \) > "$LOG_DIR/device_files.tmp"
    
    local total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
    log "ℹ️ 共发现 $total_files 个设备相关文件"
    if [ "$total_files" -eq 0 ]; then
        log "❌ 未找到设备文件"
        exit 1
    fi

    # 分批处理避免内存溢出
    split -l $BATCH_SIZE "$LOG_DIR/device_files.tmp" "$TMP_BATCH_DIR/batch_"
    local processed=0
    
    for batch_file in "$TMP_BATCH_DIR"/batch_*; do
        [ -f "$batch_file" ] || continue
        local batch_name=$(basename "$batch_file")
        log "ℹ️ 处理批次：$batch_name"

        while IFS= read -r file; do
            [ -f "$file" ] || { log "⚠️ 跳过不存在文件：$file"; continue; }

            # 提取文件扩展名
            local file_ext=$(echo "$file" | awk -F '.' '{if (NF>1) print $NF; else print "none"}')
            local device_names=""
            local chip=""
            local vendor=""

            # 根据文件类型提取信息（保留中文设备名）
            case "$file_ext" in
                dts|dtsi|dtso)
                    # 从设备树文件提取型号和兼容性（保留中文）
                    local model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)  # 过滤无效UTF-8字符
                    local compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                      sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g' |
                                      iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$model $compatible"
                    vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                    chip=$(echo "$compatible" | grep -oE '[a-z0-9]+,[a-z0-9-]+' | awk -F ',' '{print $2}' | head -n1)
                    ;;

                mk|Makefile)
                    # 从Makefile提取设备名
                    device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d')
                    chip=$(grep -E '^SOC[[:space:]]*:=' "$file" 2>> "$SYNC_LOG" | 
                          sed -E 's/SOC[[:space:]]*:=[[:space:]]*//; s/["'\'']//g' | head -n1)
                    ;;

                conf|config)
                    # 从配置文件提取设备名
                    device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    chip=$(grep -E '^CONFIG_TARGET_[a-z0-9-]+=y' "$file" 2>> "$SYNC_LOG" | 
                          sed -E 's/CONFIG_TARGET_//; s/=y//' | head -n1)
                    ;;
            esac

            # 从路径补充芯片型号
            local platform_path=$(dirname "$file" | sed "s|$TMP_SRC/target/linux/||")
            local chip_from_dir=$(echo "$platform_path" | awk -F '/' '{if (NF >= 2) print $2; else print $1}')
            chip=${chip:-$chip_from_dir}
            chip=$(echo "$chip" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g')

            # 处理设备名并写入JSON（保留中文）
            for name in $device_names; do
                [ -z "$name" ] && continue
                # 处理中文设备名：仅替换特殊字符，保留中文字符
                local device_name=$(echo "$name" | 
                                  sed -E 's/[_,:;\/]+/-/g; s/[^a-zA-Z0-9 一-龥-]//g; s/[[:space:]]+/-/g; s/--+/-/g')
                [ -z "$device_name" ] && continue

                if ! [[ -v PROCESSED_DEVICES["$device_name"] ]]; then
                    PROCESSED_DEVICES["$device_name"]=1
                    # 原子操作写入JSON（确保中文被正确编码）
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

            # 显示进度
            processed=$((processed + 1))
            [ $((processed % 100)) -eq 0 ] && log "ℹ️ 已处理 $processed/$total_files 个文件（$((processed*100/total_files))%）"
        done < "$batch_file"
    done

    rm -f "$LOG_DIR/device_files.tmp"
    local device_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    log "✅ 设备提取完成，共 $device_count 个"
}

# ==============================================
# 4. 提取芯片信息
# ==============================================
extract_chips() {
    log "🔍 开始提取芯片信息..."
    jq -r '.devices[].chip' "$OUTPUT_JSON" | sort | uniq | grep -v '^$' > "$LOG_DIR/all_chips.tmp"
    local chip_count_total=$(wc -l < "$LOG_DIR/all_chips.tmp")
    
    if [ "$chip_count_total" -eq 0 ]; then
        log "❌ 未提取到任何芯片信息"
        exit 1
    fi

    # 写入芯片基础信息
    while read -r chip; do
        local platforms=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .kernel_target' "$OUTPUT_JSON" | 
                         sort | uniq | tr '\n' ',' | sed 's/,$//')
        local vendors=$(jq --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$OUTPUT_JSON" | 
                       sort | uniq | tr '\n' ',' | sed 's/,$//')
        
        jq --arg name "$chip" --arg p "$platforms" --arg v "$vendors" \
           '.chips += [{"name": $name, "platforms": $p, "vendors": $v, "default_drivers": []}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
           [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
           { log "⚠️ 芯片 $chip 写入失败"; rm -f "$OUTPUT_JSON.tmp"; }
    done < "$LOG_DIR/all_chips.tmp"

    local final_chip_count=$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    log "✅ 芯片提取完成，共 $final_chip_count 个"
}

# ==============================================
# 5. 匹配驱动程序（扩展搜索路径）
# ==============================================
match_drivers() {
    log "🔍 开始匹配驱动程序..."
    local DRIVER_TMP="$LOG_DIR/driver_metadata.tmp"
    > "$DRIVER_TMP"

    # 解析驱动包元数据（扩展搜索路径）
    log "ℹ️ 解析驱动包元数据（可能需要几分钟）..."
    # 搜索多个可能包含驱动的目录
    find "$TMP_PKGS" \( -path "$TMP_PKGS/kernel" -o -path "$TMP_PKGS/net" -o \
         -path "$TMP_PKGS/wireless" -o -path "$TMP_PKGS/utils" \) \
         -name "Makefile" -type f | grep -v -E 'doc|tools|examples|test' | while read -r pkg_makefile; do
        # 提取驱动名称
        local pkg_name=$(grep -E '^PKG_NAME:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/PKG_NAME:=//')
        [ -z "$pkg_name" ] && continue

        # 提取版本
        local pkg_version=$(grep -E '^PKG_VERSION:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/PKG_VERSION:=//')
        [ -z "$pkg_version" ] && pkg_version="unknown"

        # 提取适用芯片（全词匹配）
        local pkg_desc=$(grep -E '^TITLE:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/TITLE:=//; s/[^a-zA-Z0-9 ,-]//g')
        local pkg_deps=$(grep -E '^DEPENDS:=' "$pkg_makefile" 2>> "$SYNC_LOG" | sed -E 's/DEPENDS:=//')
        
        local compatible_chips=$(echo "$pkg_desc $pkg_deps" | 
                               grep -oE '\b(mt|ipq|qca|rtl|ath|bcm|sun|exynos|imx)[0-9-]+\b' | 
                               sort | uniq | tr '\n' ',' | sed 's/,$//')

        # 写入临时驱动表
        if [ -n "$compatible_chips" ]; then
            echo "$pkg_name|$pkg_version|$compatible_chips|$pkg_desc" >> "$DRIVER_TMP"
        fi
    done

    local driver_count=$(wc -l < "$DRIVER_TMP")
    log "ℹ️ 共解析到 $driver_count 个驱动包元数据"
    
    if [ "$driver_count" -eq 0 ]; then
        log "⚠️ 未找到任何驱动包，跳过驱动匹配"
        return
    fi

    # 写入驱动信息到JSON
    log "ℹ️ 写入驱动信息到JSON..."
    while IFS='|' read -r name version chips desc; do
        jq --arg n "$name" --arg v "$version" --arg c "$chips" --arg d "$desc" \
           '.drivers += [{"name": $n, "version": $v, "compatible_chips": $c, "description": $d}]' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
           [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
           { log "⚠️ 驱动 $name 写入失败"; rm -f "$OUTPUT_JSON.tmp"; }
    done < "$DRIVER_TMP"

    # 为芯片匹配驱动
    log "ℹ️ 为芯片自动匹配驱动..."
    jq -r '.chips[].name' "$OUTPUT_JSON" | while read -r chip; do
        local compatible_drivers=$(jq -r --arg chip "$chip" '
            .drivers[] | 
            select( (.compatible_chips | split(",") | index($chip)) or 
                    ($chip | contains(.compatible_chips | split(",")[])) ) |
            .name + "@" + .version
        ' "$OUTPUT_JSON" 2>> "$SYNC_LOG" | sort | uniq | tr '\n' ',' | sed 's/,$//')

        if [ -n "$compatible_drivers" ]; then
            local drivers_array=$(echo "$compatible_drivers" | sed -E 's/([^,]+)/"\1"/g; s/,/", "/g; s/^/[/; s/$/]/')
            # 更新芯片的默认驱动
            jq --arg chip "$chip" --argjson drivers "$drivers_array" \
               '.chips[] |= (if .name == $chip then .default_drivers = $drivers else . end)' \
               "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && \
               [ -s "$OUTPUT_JSON.tmp" ] && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON" || \
               { log "⚠️ 芯片 $chip 驱动更新失败"; rm -f "$OUTPUT_JSON.tmp"; }
            log "ℹ️ 芯片 $chip 匹配驱动：$compatible_drivers"
        fi
    done

    # 为设备关联芯片的驱动
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
# 6. 自动生成核心功能配置（core-features.json）
# ==============================================
generate_core_features() {
    log "🔍 自动生成核心功能配置..."
    local core_features_file="configs/core-features.json"
    local tmp_features=$(mktemp -t openwrt-features-XXXXXX)
    mkdir -p "$(dirname "$core_features_file")"
    
    # 从源码提取网络功能关键词
    log "ℹ️ 从源码提取功能模块..."
    find "$TMP_SRC/package" -name "Makefile" | grep -E 'accelerate|ipv6|qos|nat|flow' | while read -r file; do
        grep -E 'TITLE|DESCRIPTION' "$file" | grep -oE 'ipv6|accel|accelerate|qos|nat|flow' | 
        tr '[:upper:]' '[:lower:]' | sort | uniq
    done >> "$tmp_features"
    
    # 添加基础功能
    cat <<EOF >> "$tmp_features"
ipv6
accel
qos
nat
flow
none
EOF
    
    # 保留用户自定义功能（如果文件已存在）
    if [ -f "$core_features_file" ]; then
        jq -r '.features[]' "$core_features_file" | while read -r user_feat; do
            if ! grep -q "$user_feat" "$tmp_features" && [ "$user_feat" != "none" ]; then
                echo "$user_feat" >> "$tmp_features"
                log "ℹ️ 保留用户自定义功能：$user_feat"
            fi
        done
    fi
    
    # 去重并生成组合
    sort -u "$tmp_features" | grep -v '^$' > "$tmp_features.uniq"
    local basic_features=$(cat "$tmp_features.uniq" | tr '\n' ' ')
    
    # 生成JSON
    echo '{"features": [' > "$core_features_file"
    echo "\"none\"," >> "$core_features_file"  # 基础选项
    
    # 单个功能选项
    for feat in $basic_features; do
        [ "$feat" = "none" ] && continue
        echo "\"$feat-only\"," >> "$core_features_file"
    done
    
    # 功能组合（最多2个组合）
    local feats_array=($basic_features)
    for i in "${!feats_array[@]}"; do
        for j in $(seq $((i+1)) $(( ${#feats_array[@]} - 1 )) ); do
            echo "\"${feats_array[$i]}+${feats_array[$j]}\"," >> "$core_features_file"
        done
    done
    
    # 修复JSON格式
    sed -i '$ s/,$//' "$core_features_file"
    echo ']}' >> "$core_features_file"
    
    log "✅ 核心功能配置生成完成，共 $(jq '.features | length' "$core_features_file") 个选项"
    rm -f "$tmp_features" "$tmp_features.uniq"
}

# ==============================================
# 7. 自动生成主题+优化配置（修复JSON语法）
# ==============================================
discover_themes() {
    # 使用带前缀的临时文件，避免冲突
    local themes_dir=$(mktemp -d -t openwrt-themes-XXXXXX)
    local theme_list=$(mktemp -t openwrt-theme-list-XXXXXX)
    
    # 主流主题仓库
    local theme_repos=(
        "https://github.com/jerrykuku/luci-theme-argon.git"
        "https://github.com/LuttyYang/luci-theme-material.git"
        "https://github.com/openwrt/luci.git"  # bootstrap主题在luci仓库
        "https://github.com/rosywrt/luci-theme-rosy.git"
    )
    
    # 克隆并提取主题名称
    for repo in "${theme_repos[@]}"; do
        local repo_name=$(basename "$repo" .git)
        if git clone --depth 1 "$repo" "$themes_dir/$repo_name" 2>> "$SYNC_LOG"; then
            # 特殊处理bootstrap主题（在luci仓库的themes目录）
            if [ "$repo_name" = "luci" ]; then
                find "$themes_dir/$repo_name/themes" -name "luci-theme-*" | while read -r theme_path; do
                    local name=$(basename "$theme_path" | sed 's/luci-theme-//')
                    echo "$name" >> "$theme_list"
                done
            else
                local name=$(grep -E '^PKG_NAME:=' "$themes_dir/$repo_name/Makefile" 2>> "$SYNC_LOG" | 
                            sed -E 's/PKG_NAME:=luci-theme-//; s/-/_/g')
                [ -n "$name" ] && echo "$name" >> "$theme_list"
            fi
        fi
    done
    
    # 去重
    sort -u "$theme_list" > "$theme_list.uniq"
    echo "$theme_list.uniq"
    
    # 清理当前函数创建的临时文件
    rm -rf "$themes_dir" "$theme_list"
}

generate_theme_optimizations() {
    log "🔍 自动生成主题+优化配置..."
    local theme_opt_file="configs/theme-optimizations.json"
    local theme_list_path=$(discover_themes)
    mkdir -p "$(dirname "$theme_opt_file")"
    
    # 检测GCC支持的优化级别（正确提取优化选项）
    local gcc_opts=$(gcc --help=optimizers 2>/dev/null | 
                    grep -oE '--param=O[0-9s]| -O[0-9s]' |  # 只匹配带空格或--param=前缀的-O选项
                    grep -oE 'O[0-9s]' |  # 提取O+数字/s
                    sort | uniq)
    
    # 从设备提取支持的架构
    local architectures=$(jq -r '.devices[].kernel_target' "$OUTPUT_JSON" | 
                         grep -oE 'armv8|x86|generic|mips' | sort | uniq | tr '\n' ' ')
    
    # 保留用户自定义主题
    if [ -f "$theme_opt_file" ]; then
        jq -r '.themes[].name' "$theme_opt_file" | while read -r user_theme; do
            if ! grep -q "$user_theme" "$theme_list_path"; then
                echo "$user_theme" >> "$theme_list_path"
                log "ℹ️ 保留用户自定义主题：$user_theme"
            fi
        done
    fi
    
    # 生成JSON（确保字符串正确加引号）
    echo '{"themes": [' > "$theme_opt_file"
    local first=1
    
    while read -r theme; do
        [ -z "$theme" ] && continue
        
        # 主题特殊配置
        local theme_arches=$architectures
        local theme_opts=$gcc_opts
        
        case "$theme" in
            "bootstrap") theme_opts="O2";;  # 官方主题默认O2
            "material") theme_arches="generic x86";;
            "argon") theme_opts="O2 O3";;   # 热门主题支持更高优化
        esac
        
        # 将数组元素用双引号包裹
        local arch_array=$(echo "$theme_arches" | tr ' ' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        local opts_array=$(echo "$theme_opts" | tr ' ' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        
        # 写入JSON
        [ $first -eq 0 ] && echo "," >> "$theme_opt_file"
        first=0
        
        echo "  {" >> "$theme_opt_file"
        echo "    \"name\": \"$theme\"," >> "$theme_opt_file"
        echo "    \"architectures\": [$arch_array]," >> "$theme_opt_file"
        echo "    \"opts\": [$opts_array]" >> "$theme_opt_file"
        echo "  }" >> "$theme_opt_file"
    done < "$theme_list_path"
    
    echo ']}' >> "$theme_opt_file"
    # 验证生成的JSON有效性
    if ! jq . "$theme_opt_file" &> /dev/null; then
        log "⚠️ 主题配置JSON格式语法错误，尝试手动检查 $theme_opt_file"
    fi
    local theme_count=$(jq '.themes | length' "$theme_opt_file" 2>/dev/null || echo 0)
    log "✅ 主题+优化配置生成完成，共 $theme_count 个主题"
    rm -f "$theme_list_path"  # 只删除临时文件
}

# ==============================================
# 8. 同步源码分支（修复变量名和命令错误）
# ==============================================
sync_source_branches() {
    log "🔍 同步最新源码分支..."
    local branches_file="$LOG_DIR/source_branches.tmp"  # 修复：修正变量名（原branchesches_file）
    > "$branches_file"

    # OpenWrt官方分支
    log "ℹ️ 获取OpenWrt分支..."
    git ls-remote --heads https://git.openwrt.org/openwrt/openwrt.git 2>> "$SYNC_LOG" | 
        grep -E 'openwrt-[0-9]+\.[0-9]+|master' | 
        sed -E 's/.*refs\/heads\///; s/^/openwrt-/g' >> "$branches_file"

    # ImmortalWrt分支
    log "ℹ️ 获取ImmortalWrt分支..."
    git ls-remote --heads https://github.com/immortalwrt/immortalwrt.git 2>> "$SYNC_LOG" | 
        grep -E 'openwrt-[0-9]+\.[0-9]+|master' | 
        sed -E 's/.*refs\/heads\///; s/^/immortalwrt-/g' >> "$branches_file"

    # 去重排序（修复：移除重复的mv命令）
    sort -u "$branches_file" | sort -r > "$branches_file.tmp" && mv "$branches_file.tmp" "$branches_file"
    log "✅ 源码分支同步完成，共 $(wc -l < "$branches_file") 个"
}

# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt设备同步系统启动"
log "📅 同步时间：$(date +"%Y-%m-%d %H:%M:%S")"
log "========================================="

# 初始化输出JSON
echo '{"devices": [], "chips": [], "drivers": [], "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'"}}' > "$OUTPUT_JSON"

# 执行同步流程
check_dependencies
clone_repositories
extract_devices
extract_chips
match_drivers
generate_core_features
generate_theme_optimizations
sync_source_branches

# 最终验证（确保中文统计正常）
log "========================================="
log "✅ 所有同步任务完成"
log "📊 设备总数：$(jq '.devices | length' "$OUTPUT_JSON")"
log "📊 芯片总数：$(jq '.chips | length' "$OUTPUT_JSON")"
log "📊 驱动总数：$(jq '.drivers | length' "$OUTPUT_JSON")"
log "📊 核心功能数：$(jq '.features | length' "configs/core-features.json" 2>/dev/null || echo 0)"
log "📊 主题数：$(jq '.themes | length' "configs/theme-optimizations.json" 2>/dev/null || echo 0)"
log "========================================="
    
