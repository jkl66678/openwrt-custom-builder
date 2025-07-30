#!/bin/bash
set -uo pipefail

# 强制UTF-8编码（彻底解决中文乱码）
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# ==============================================
# 基础配置与初始化
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_JSON="$WORK_DIR/device-drivers.json"
SYNC_LOG="$LOG_DIR/sync-detail.log"
PKG_REPO="https://git.openwrt.org/feed/packages.git"
TMP_SRC=$(mktemp -d -t openwrt-src-XXXXXX)
TMP_PKGS=$(mktemp -d -t openwrt-pkgs-XXXXXX)
TMP_BATCH_DIR="$LOG_DIR/device_batches"

# 创建必要目录
mkdir -p "$LOG_DIR" "$TMP_BATCH_DIR" || { 
    echo "❌ 无法创建日志目录（权限不足）" >&2; 
    exit 1; 
}
> "$SYNC_LOG"  # 清空日志

# 日志函数（确保中文正常输出）
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$timestamp" "$1" | tee -a "$SYNC_LOG"
}

# 临时资源清理函数（保留分支文件供工作流使用）
cleanup() {
    log "🔧 开始清理临时资源..."
    [ -d "$TMP_SRC" ] && rm -rf "$TMP_SRC"
    [ -d "$TMP_PKGS" ] && rm -rf "$TMP_PKGS"
    [ -d "$TMP_BATCH_DIR" ] && rm -rf "$TMP_BATCH_DIR"
    find "$LOG_DIR" -name "*.tmp" -not -name "source_branches.tmp" -delete
    log "✅ 临时资源清理完成"
}
trap cleanup EXIT

# ==============================================
# 1. 依赖检查（新增GNU grep兼容性检查）
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file" "gcc" "iconv")
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具：$tool（可能导致功能异常）"
            exit 1
        fi
    done

    # 检查jq版本（确保支持JSON操作）
    if! jq --version &> /dev/null || [ "$(jq --version | cut -d''-f3 | cut -d'.' -f1)" -lt 1 ] || [ "$(jq --version | cut -d''-f3 | cut -d'.' -f2)" -lt 6 ]; then
        log "❌ jq工具版本不兼容，请安装jq 1.6+"
        exit 1
    fi

    # 检查grep是否支持-E选项（避免正则错误）
    if! grep -E --help &> /dev/null; then
        log "❌ grep工具不支持扩展正则表达式，请使用GNU grep"
        exit 1
    fi
    
    log "✅ 依赖工具检查通过"
}

# ==============================================
# 2. 克隆源码仓库（增加网络容错）
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
# 3. 提取设备信息（优化中文处理）
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

            # 根据文件类型提取信息（保留中文）
            case "$file_ext" in
                dts|dtsi|dtso)
                    # 从设备树文件提取型号和兼容性
                    local model=$(grep -E'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)  # 过滤无效UTF-8字符
                    local compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                      sed -E's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g' |
                                      iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$model $compatible"
                    vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1)
                    chip=$(echo "$compatible" | grep -oE '[a-z0-9]+,[a-z0-9-]+' | awk -F ',' '{print $2}' | head -n1)
                    ;;

                mk|Makefile)
                    # 从Makefile提取设备名
                    local make_targets=$(grep -E '^define Device/' "$file" 2>> "$SYNC_LOG" | 
                                         sed -E 's/^define Device\/([^ ]+).*/\1/' |
                                         iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$make_targets"
                    ;;

                conf|board|profile)
                    # 从配置文件提取设备名
                    local config_names=$(grep -E '^DEVICE_NAME=' "$file" 2>> "$SYNC_LOG" | 
                                         sed -E 's/^DEVICE_NAME=//' |
                                         iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$config_names"
                    ;;

                *)
                    log "⚠️ 跳过未知文件类型：$file_ext"
                    continue
                    ;;
            esac

            # 处理设备名（去重并过滤空值）
            local unique_names=$(echo "$device_names" | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | grep -vE '^$' | sort | uniq)
            for name in $unique_names; do
                [ -z "$name" ] && continue
                if [ -z "${PROCESSED_DEVICES[$name]}" ]; then
                    PROCESSED_DEVICES[$name]="$chip|$vendor"
                else
                    log "⚠️ 设备 $name 已存在，跳过重复条目"
                fi
            done
            processed=$((processed + 1))
        done < "$batch_file"
    done

    # 写入JSON
    log "📝 写入设备信息到 $OUTPUT_JSON..."
    jq -n --argjson devices "$(declare -p PROCESSED_DEVICES | sed -E 's/^declare -A //; s/([^=]+)=([^ ]+)/"\1": "\2"/g')" '
        { devices: $devices | to_entries[] | { name: .key, chip: (.value | split("|")[0]), vendor: (.value | split("|")[1]) } }' >> "$OUTPUT_JSON"
}

# ==============================================
# 4. 提取芯片信息
# ==============================================
extract_chips() {
    log "🔍 开始提取芯片信息..."
    local unique_chips=$(jq -r '.devices[].chip' "$OUTPUT_JSON" | grep -vE '^$' | sort | uniq)
    
    # 去重并生成芯片列表
    echo '{"chips": [' > "$OUTPUT_JSON.tmp"
    local first=1
    while read -r chip; do
        [ -z "$chip" ] && continue
        [ $first -eq 0 ] && echo "," >> "$OUTPUT_JSON.tmp"
        first=0
        echo "  {\"name\": \"$chip\"}" >> "$OUTPUT_JSON.tmp"
    done < <(echo "$unique_chips")
    echo ']}' >> "$OUTPUT_JSON.tmp"

    # 合并芯片信息到主JSON
    jq -s '.[0] * .[1]' "$OUTPUT_JSON" "$OUTPUT_JSON.tmp" > "$OUTPUT_JSON.new" && mv "$OUTPUT_JSON.new" "$OUTPUT_JSON"
    rm -f "$OUTPUT_JSON.tmp"
}

# ==============================================
# 5. 匹配驱动（核心优化部分）
# ==============================================
match_drivers() {
    log "🔍 开始匹配驱动..."
    local drivers_array=$(find "$TMP_PKGS" -name "Makefile" -exec grep -H '^PKG_NAME=' {} + 2>> "$SYNC_LOG" |
                          sed -E 's/^([^:]+):PKG_NAME=(.*)/\1 \2/' |
                          awk '{print $2 " " $1}' |
                          sort | uniq)

    # 初始化驱动列表
    echo '{"drivers": []}' > "$OUTPUT_JSON.drivers.tmp"

    for driver_info in $drivers_array; do
        local driver_name=$(echo "$driver_info" | awk '{print $1}')
        local driver_path=$(echo "$driver_info" | awk '{print $2}')

        # 提取驱动描述和依赖
        local pkg_desc=$(grep -E '^PKG_DESCRIPTION=' "$driver_path" 2>> "$SYNC_LOG" |
                         sed -E 's/^PKG_DESCRIPTION=//' |
                         iconv -f UTF-8 -t UTF-8//IGNORE)
        local pkg_deps=$(grep -E '^PKG_DEPENDS=' "$driver_path" 2>> "$SYNC_LOG" |
                        sed -E 's/^PKG_DEPENDS=//' |
                        iconv -f UTF-8 -t UTF-8//IGNORE)
        local pkg_config=$(grep -E '^CONFIG_' "$driver_path" 2>> "$SYNC_LOG" |
                          sed -E 's/^CONFIG_([^=]+)=.*/\1/' |
                          iconv -f UTF-8 -t UTF-8//IGNORE)

        # 提取兼容芯片（优化正则表达式）
        local compatible_chips=$(echo "$pkg_desc $pkg_deps $pkg_config" |
                                grep -oE '\b(bcm|brcm|mtk|mt|ipq|qca|rtl|ath|sunxi|sun|exynos|imx|rk|rockchip|mvebu|qualcomm|realtek)-[a-z0-9-]+\b' |
                                sed -E 's/^([a-z]+)-/\1,/' |  # 格式化为 "vendor,model"
                                sort | uniq | tr '\n' ',' | sed 's/,$//')

        # 严格限制通用驱动
        if [ -z "$compatible_chips" ] && echo "$pkg_desc $pkg_deps $pkg_config" | grep -qE '\bgeneric\b'; then
            compatible_chips="generic"
        elif [ -z "$compatible_chips" ]; then
            compatible_chips="unknown"
        fi

        # 写入驱动信息
        jq -n --arg name "$driver_name" --arg compatible "$compatible_chips" '
            { name: $name, compatible_chips: $compatible }' >> "$OUTPUT_JSON.drivers.tmp"
    done

    # 合并驱动列表到主JSON
    jq -s '.[0] * .[1]' "$OUTPUT_JSON" "$OUTPUT_JSON.drivers.tmp" > "$OUTPUT_JSON.new" && mv "$OUTPUT_JSON.new" "$OUTPUT_JSON"
    rm -f "$OUTPUT_JSON.drivers.tmp"

    # 关联驱动与芯片（优化匹配逻辑）
    jq --argjson chips "$(jq -r '.chips[] | .name' "$OUTPUT_JSON" | jq -R -s -c '{"chips": .}')" '
        .drivers[] |= (
            select(
                (.compatible_chips == "generic") or
                ($chips.chips[] | contains(.compatible_chips))
            )
        )' "$OUTPUT_JSON" > "$OUTPUT_JSON.new" && mv "$OUTPUT_JSON.new" "$OUTPUT_JSON"
}

# ==============================================
# 6. 生成核心功能（保留原逻辑）
# ==============================================
generate_core_features() {
    log "🔍 生成核心功能配置..."
    local core_features=$(find "$TMP_SRC/package" -name "Makefile" -exec grep -H '^define Package/' {} + 2>> "$SYNC_LOG" |
                          sed -E 's/^define Package\/([^ ]+).*/\1/' |
                          iconv -f UTF-8 -t UTF-8//IGNORE |
                          sort | uniq)
    
    echo '{"features": [' > "configs/core-features.json"
    local first=1
    for feature in $core_features; do
        [ -z "$feature" ] && continue
        [ $first -eq 0 ] && echo "," >> "configs/core-features.json"
        first=0
        echo "  {\"name\": \"$feature\"}" >> "configs/core-features.json"
    done
    echo ']}' >> "configs/core-features.json"
}

# ==============================================
# 7. 生成主题优化配置（保留原逻辑）
# ==============================================
generate_theme_optimizations() {
    log "🔍 生成主题优化配置..."
    local theme_list_path="$LOG_DIR/theme_list.tmp"
    local theme_opt_file="configs/theme-optimizations.json"
    local architectures="armv8 x86 generic mips armv7"
    local gcc_opts="O2 O3 -march=native"
    
    # 收集默认主题
    find "$TMP_SRC/package/feeds/luci/luci-theme-*" -maxdepth 0 -type d |
        sed -E 's/.*luci-theme-//' |
        sort | uniq > "$theme_list_path"
    
    # 保留用户自定义主题
    if [ -f "$theme_opt_file" ]; then
        jq -r '.themes[].name' "$theme_opt_file" 2>/dev/null | while read -r user_theme; do
            if [ -n "$user_theme" ] &&! grep -q "$user_theme" "$theme_list_path"; then
                echo "$user_theme" >> "$theme_list_path"
                log "ℹ️ 保留用户自定义主题：$user_theme"
            fi
        done
    fi
    
    # 生成JSON（确保格式正确）
    echo '{"themes": [' > "$theme_opt_file"
    local first=1
    
    while read -r theme; do
        [ -z "$theme" ] && continue
        
        # 主题特殊配置
        local theme_arches=$architectures
        local theme_opts=$gcc_opts
        
        case "$theme" in
            "bootstrap") theme_opts="O2";;
            "material") theme_arches="generic x86 armv8";;
            "argon") theme_opts="O2 O3";;
            "rosy") theme_opts="O2";;
        esac
        
        # 数组元素用双引号包裹
        local arch_array=$(echo "$theme_arches" | tr'' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed's/,$//')
        local opts_array=$(echo "$theme_opts" | tr'' '\n' | grep -v '^$' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed's/,$//')
        
        # 写入JSON（避免最后一个元素有逗号）
        [ $first -eq 0 ] && echo "," >> "$theme_opt_file"
        first=0
        
        echo "  {" >> "$theme_opt_file"
        echo "    \"name\": \"$theme\"," >> "$theme_opt_file"
        echo "    \"architectures\": [$arch_array]," >> "$theme_opt_file"
        echo "    \"opts\": [$opts_array]" >> "$theme_opt_file"
        echo "  }" >> "$theme_opt_file"
    done < "$theme_list_path"
    
    echo ']}' >> "$theme_opt_file"
    
    # 验证JSON有效性
    if! jq. "$theme_opt_file" &> /dev/null; then
        log "⚠️ 主题配置JSON格式错误，尝试修复"
        sed -i ':a;N;$!ba;s/,\n  }/\n  }/' "$theme_opt_file"  # 移除最后一个逗号
    fi
    
    local theme_count=$(jq '.themes | length' "$theme_opt_file" 2>/dev/null || echo 0)
    log "✅ 主题+优化配置生成完成，共 $theme_count 个主题"
    rm -f "$theme_list_path"
}

# ==============================================
# 8. 同步源码分支（确保分支文件正确生成）
# ==============================================
sync_source_branches() {
    log "🔍 同步最新源码分支..."
    local branches_file="$LOG_DIR/source_branches.tmp"
    > "$branches_file"  # 初始化空文件

    # 定义仓库列表（前缀|仓库地址）
    local repo_list=(
        "openwrt|https://git.openwrt.org/openwrt/openwrt.git"
        "immortalwrt|https://github.com/immortalwrt/immortalwrt.git"
    )

    # 循环获取每个仓库的分支
    for repo in "${repo_list[@]}"; do
        local repo_prefix=$(echo "$repo" | cut -d'|' -f1)
        local repo_url=$(echo "$repo" | cut -d'|' -f2)
        local temp_branch=$(mktemp -t ${repo_prefix}-branches-XXXXXX)
        
        log "ℹ️ 获取 $repo_prefix 分支（仓库：$repo_url）..."
        local retries=3
        local success=0

        while [ $retries -gt 0 ]; do
            > "$temp_branch"  # 清空临时文件
            # 获取分支并过滤有效分支
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

        rm -f "$temp_branch"  # 清理临时文件

        if [ $success -eq 0 ]; then
            log "❌ 无法获取 $repo_prefix 分支（仓库不可达）"
            exit 1
        fi
    done

    # 去重排序
    sort -u "$branches_file" | sort -r > "$branches_file.tmp" && mv "$branches_file.tmp" "$branches_file"

    # 最终检查
    if [! -s "$branches_file" ]; then
        log "❌ 分支文件生成失败或为空：$branches_file"
        exit 1
    fi
    
    log "✅ 源码分支同步完成，共 $(wc -l < "$branches_file") 个有效分支"
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
match_drivers  # 核心修复：确保驱动正常提取
generate_core_features
generate_theme_optimizations
sync_source_branches

# 最终验证
log "========================================="
log "✅ 所有同步任务完成"
log "📊 设备总数：$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 芯片总数：$(jq '.chips | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 驱动总数：$(jq '.drivers | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 核心功能数：$(jq '.features | length' "configs/core-features.json" 2>/dev/null || echo 0)"
log "📊 主题数：$(jq '.themes | length' "configs/theme-optimizations.json" 2>/dev/null || echo 0)"
log "========================================="
