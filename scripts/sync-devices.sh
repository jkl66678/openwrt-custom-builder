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

# 确保日志和临时目录存在
mkdir -p "$LOG_DIR" "$TMP_BATCH_DIR" || { 
    echo "❌ 无法创建日志目录" >&2; 
    exit 1; 
}
> "$SYNC_LOG"  # 清空日志文件


# ==============================================
# 工具函数
# ==============================================
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$timestamp" "$1" | tee -a "$SYNC_LOG"
}

# 清理临时资源
cleanup() {
    log "🔧 清理临时资源..."
    if [ -n "$TMP_SRC" ] && [ -d "$TMP_SRC" ]; then
        rm -rf "$TMP_SRC"
        log "✅ 主源码临时目录清理完成"
    fi
    if [ -n "$TMP_PKGS_BASE" ] && [ -d "$TMP_PKGS_BASE" ]; then
        rm -rf "$TMP_PKGS_BASE"
        log "✅ 驱动仓库临时目录清理完成"
    fi
    [ -d "$TMP_BATCH_DIR" ] && rm -rf "$TMP_BATCH_DIR"
    # 保留source_branches.tmp外的临时文件
    find "$LOG_DIR" -name "*.tmp" -not -name "source_branches.tmp" -delete
    log "✅ 临时资源清理完成"
}
trap cleanup EXIT  # 脚本退出时自动清理


# ==============================================
# 1. 依赖检查
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    REQUIRED_TOOLS=("git" "jq" "grep" "sed" "awk" "find" "wc" "tr" "sort" "uniq" "file" "gcc" "iconv")
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具：$tool（请先安装）"
            exit 1
        fi
    done

    # 检查jq版本（至少1.6）
    if ! jq_version_str=$(jq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1); then
        log "❌ 无法解析jq版本，请安装jq 1.6+"
        exit 1
    fi
    jq_major=$(echo "$jq_version_str" | cut -d'.' -f1)
    jq_minor=$(echo "$jq_version_str" | cut -d'.' -f2)
    if [ "$jq_major" -lt 1 ] || [ "$jq_minor" -lt 6 ]; then
        log "❌ 请安装jq 1.6+（当前版本：$jq_version_str）"
        exit 1
    fi

    # 检查GNU grep
    if ! grep -E --help &> /dev/null; then
        log "❌ 请使用GNU grep（非BSD版本）"
        exit 1
    fi
    
    log "✅ 依赖工具检查通过"
}


# ==============================================
# 2. 仓库克隆
# ==============================================
clone_repositories() {
    log "📥 克隆OpenWrt主源码..."
    local retries=3
    local timeout=600  # 10分钟超时
    local required_dirs=("target/linux" "package")  # 核心目录验证

    while [ $retries -gt 0 ]; do
        rm -rf "$TMP_SRC"  # 清理上次残留
        if timeout $timeout git clone https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" 2>> "$SYNC_LOG"; then
            # 验证核心目录是否存在
            local missing=0
            for dir in "${required_dirs[@]}"; do
                if [ ! -d "$TMP_SRC/$dir" ]; then
                    log "⚠️ 主源码缺失关键目录：$dir"
                    missing=1
                fi
            done
            if [ $missing -eq 0 ]; then
                log "✅ 主源码克隆成功（核心目录完整）"
                break
            fi
        fi
        retries=$((retries - 1))
        log "⚠️ 主源码克隆失败，剩余重试：$retries"
        sleep 10
    done

    if [ $retries -eq 0 ]; then
        log "❌ 主源码克隆失败（核心目录始终缺失）"
        exit 1
    fi

    # 克隆扩展驱动仓库
    log "📥 克隆扩展驱动仓库（共 ${#PKG_REPOS[@]} 个）..."
    local repo_idx=1
    for repo in "${PKG_REPOS[@]}"; do
        local repo_name=$(basename "$repo" .git)
        local repo_dir="$TMP_PKGS_BASE/$repo_name"
        
        retries=3
        while [ $retries -gt 0 ]; do
            rm -rf "$repo_dir"
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
# 3. 设备信息提取（核心：提取设备名称、厂商、平台）
# ==============================================
extract_devices() {
    log "🔍 提取设备信息（含厂商和平台特征）..."
    declare -A PROCESSED_DEVICES  # 去重设备名称
    local BATCH_SIZE=1000
    local device_data_tmp="$LOG_DIR/device_data.tmp"
    > "$device_data_tmp"  # 清空临时设备数据

    local target_dir="$TMP_SRC/target/linux"
    if [ ! -d "$target_dir" ]; then
        log "❌ 设备配置目录不存在：$target_dir"
        exit 1
    fi

    # 查找所有设备相关文件（DTS、Makefile等）
    find "$target_dir" \( -name "*.dts" -o -name "*.dtsi" -o -name "*.dtso" \
        -o -name "*.mk" -o -name "Makefile" -o -name "*.conf" \
        -o -name "*.board" -o -name "*.profile" \) > "$LOG_DIR/device_files.tmp"
    
    local total_files=$(wc -l < "$LOG_DIR/device_files.tmp")
    log "ℹ️ 发现 $total_files 个设备相关文件"
    if [ "$total_files" -eq 0 ]; then
        log "❌ 未找到任何设备文件"
        exit 1
    fi

    # 分批处理文件（避免内存溢出）
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
            local platform=""  # 设备所属平台（如mt7621、ipq806x）

            # 根据文件类型提取信息
            case "$file_ext" in
                dts|dtsi|dtso)
                    # 从设备树文件提取型号和兼容性
                    local model=$(grep -E 'model[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/model[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''];//; s/^[[:space:]]*//' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE)
                    local compatible=$(grep -E 'compatible[[:space:]]*=' "$file" 2>> "$SYNC_LOG" | 
                                      sed -E 's/compatible[[:space:]]*=[[:space:]]*["'\'']//; s/["'\''],?[[:space:]]*/ /g' |
                                      iconv -f UTF-8 -t UTF-8//IGNORE)
                    device_names="$model $compatible"
                    vendor=$(echo "$compatible" | awk -F ',' '{print $1}' | head -n1 | tr '[:upper:]' '[:lower:]')
                    chip=$(echo "$compatible" | grep -oE '[a-z0-9]+,[a-z0-9-]+' | awk -F ',' '{print $2}' | head -n1 | tr '[:upper:]' '[:lower:]')
                    # 从路径提取平台（如target/linux/mt7621 -> mt7621）
                    platform=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d' | tr '[:upper:]' '[:lower:]')
                    ;;

                mk|Makefile)
                    # 从Makefile提取设备名称
                    device_names=$(grep -E 'DEVICE_NAME|SUPPORTED_DEVICES' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/(DEVICE_NAME|SUPPORTED_DEVICES)[[:space:]]*[:=][[:space:]]*//; s/["'\'']//g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE | tr '[:upper:]' '[:lower:]')
                    vendor=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d' | tr '[:upper:]' '[:lower:]')
                    platform=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d' | tr '[:upper:]' '[:lower:]')
                    chip=$(grep -E '^SOC[[:space:]]*:=' "$file" 2>> "$SYNC_LOG" | 
                          sed -E 's/SOC[[:space:]]*:=[[:space:]]*//; s/["'\'']//g' | head -n1 | tr '[:upper:]' '[:lower:]')
                    ;;

                conf|config)
                    # 从配置文件提取设备
                    device_names=$(grep -E '^CONFIG_TARGET_DEVICE' "$file" 2>> "$SYNC_LOG" | 
                                  sed -E 's/CONFIG_TARGET_DEVICE_//; s/=y//; s/_/-/g' |
                                  iconv -f UTF-8 -t UTF-8//IGNORE | tr '[:upper:]' '[:lower:]')
                    platform=$(echo "$file" | sed -E 's|.*/target/linux/([^/]+)/.*|\1|; t; d' | tr '[:upper:]' '[:lower:]')
                    ;;

                *)
                    log "⚠️ 跳过不支持的文件类型：$file_ext（文件：$file）"
                    continue
                    ;;
            esac

            # 处理设备名称（去重、清理特殊字符）
            for name in $device_names; do
                [ -z "$name" ] && continue
                # 清理设备名称（替换特殊字符为短横线）
                local clean_name=$(echo "$name" | sed -E 's/[_,:;\/]+/-/g; s/[^a-zA-Z0-9-]//g; s/--+/-/g; s/^-|-$//')
                [ -z "$clean_name" ] && continue

                # 去重：同一设备只记录一次
                if ! [[ -v PROCESSED_DEVICES["$clean_name"] ]]; then
                    PROCESSED_DEVICES["$clean_name"]=1
                    # 写入临时设备数据（JSON格式）
                    jq -n \
                       --arg name "$clean_name" \
                       --arg chip "$chip" \
                       --arg vendor "$vendor" \
                       --arg platform "$platform" \
                       '{"name": $name, "chip": $chip, "vendor": $vendor, "platform": $platform, "drivers": []}' \
                       >> "$device_data_tmp"
                    log "ℹ️ 提取设备：$clean_name（厂商：$vendor，平台：$platform）"
                fi
            done

            processed=$((processed + 1))
            [ $((processed % 100)) -eq 0 ] && log "ℹ️ 已处理 $processed/$total_files 个文件"
        done < "$batch_file"
    done

    # 合并设备数据为最终格式
    jq -s '{"devices": .}' "$device_data_tmp" > "$LOG_DIR/device_list.json"
    local device_count=$(jq '.devices | length' "$LOG_DIR/device_list.json" 2>/dev/null || echo 0)
    log "✅ 设备提取完成，共 $device_count 个设备"
    rm -f "$LOG_DIR/device_files.tmp"  # 清理临时文件
}


# ==============================================
# 4. 芯片信息提取（作为兜底，非必须）
# ==============================================
extract_chips() {
    log "🔍 提取芯片信息（作为驱动匹配兜底）..."
    local chip_data_tmp="$LOG_DIR/chip_data.tmp"
    > "$chip_data_tmp"

    # 从设备列表提取唯一芯片
    jq -r '.devices[].chip | select(. != "")' "$LOG_DIR/device_list.json" | sort | uniq | while read -r chip; do
        # 从设备中关联芯片的厂商和平台
        local vendor=$(jq -r --arg c "$chip" '.devices[] | select(.chip == $c) | .vendor' "$LOG_DIR/device_list.json" | head -n1)
        local platform=$(jq -r --arg c "$chip" '.devices[] | select(.chip == $c) | .platform' "$LOG_DIR/device_list.json" | head -n1)
        
        # 推断架构（平台→架构映射表）
        declare -A PLATFORM_ARCH=(
            ["mt7621"]="mips" ["mt7620"]="mips" ["rt305x"]="mips"
            ["ipq4019"]="armv7" ["ipq806x"]="armv7" ["qca9531"]="armv7"
            ["rk3399"]="aarch64" ["mt7981"]="aarch64" ["sunxi"]="aarch64"
            ["x86"]="x86_64" ["x86_64"]="x86_64"
        )
        local arch=${PLATFORM_ARCH[$platform]:-"unknown-arch"}

        # 提取芯片系列（取前缀）
        local series=$(echo "$chip" | awk -F '-' '{print $1}')

        # 写入芯片数据
        jq -n \
           --arg name "$chip" \
           --arg arch "$arch" \
           --arg vendor "$vendor" \
           --arg series "$series" \
           --arg platform "$platform" \
           '{"name": $name, "architecture": $arch, "vendor": $vendor, "series": $series, "platform": $platform, "default_drivers": []}' \
           >> "$chip_data_tmp"
    done

    # 合并芯片数据
    jq -s '{"chips": .}' "$chip_data_tmp" > "$LOG_DIR/chip_list.json"
    local chip_count=$(jq '.chips | length' "$LOG_DIR/chip_list.json" 2>/dev/null || echo 0)
    log "✅ 芯片提取完成，共 $chip_count 个芯片"
}


# ==============================================
# 5. 驱动元数据解析（核心：提取设备支持信息）
# ==============================================
parse_driver_metadata() {
    log "🔍 解析驱动元数据（含设备/厂商/平台支持）..."
    local driver_meta_dir="$LOG_DIR/driver_metadata"
    mkdir -p "$driver_meta_dir"
    > "$LOG_DIR/driver_files.tmp"  # 记录所有驱动文件

    # 1. 收集所有驱动相关文件（Makefile/Kconfig）
    log "ℹ️ 收集驱动文件..."
    # 主源码驱动
    find "$TMP_SRC/package" -name "Makefile" -o -name "Kconfig" >> "$LOG_DIR/driver_files.tmp"
    find "$TMP_SRC/target/linux" -name "Makefile" -o -name "Kconfig" >> "$LOG_DIR/driver_files.tmp"
    # 扩展仓库驱动
    for repo_dir in "$TMP_PKGS_BASE"/*; do
        [ -d "$repo_dir" ] || continue
        find "$repo_dir" -name "Makefile" -o -name "Kconfig" >> "$LOG_DIR/driver_files.tmp"
    done

    local total_drv_files=$(wc -l < "$LOG_DIR/driver_files.tmp")
    log "ℹ️ 共发现 $total_drv_files 个驱动文件，开始解析..."
    if [ "$total_drv_files" -eq 0 ]; then
        log "❌ 未找到任何驱动文件"
        exit 1
    fi

    # 2. 解析每个驱动文件，提取支持信息
    local processed_drv=0
    while IFS= read -r file; do
        [ -f "$file" ] || { log "⚠️ 跳过不存在的驱动文件：$file"; continue; }

        # 驱动名称（取父目录名）
        local driver_name=$(basename "$(dirname "$file")" | tr '[:upper:]' '[:lower:]')
        [ -z "$driver_name" ] && driver_name=$(basename "$file" | sed 's/\.(Makefile|Kconfig)//')

        # 提取支持的设备/厂商/平台/芯片
        local supported_devices=""
        local supported_vendors=""
        local supported_platforms=""
        local supported_chips=""

        if [[ "$file" == *"Makefile"* ]]; then
            # 从Makefile提取设备/厂商/平台支持
            supported_devices=$(grep -E 'SUPPORTED_DEVICES|DEVICE_LIST' "$file" 2>> "$SYNC_LOG" | 
                               sed -E 's/.*=[[:space:]]*//; s/["'\'']//g; s/ /,/g' | tr '[:upper:]' '[:lower:]')
            supported_vendors=$(grep -E 'VENDOR:=|VENDOR_NAME=' "$file" 2>> "$SYNC_LOG" | 
                               sed -E 's/.*=//; s/["'\'']//g' | tr '[:upper:]' '[:lower:]')
            supported_platforms=$(grep -E 'PLATFORM:=|TARGET_PLATFORM=' "$file" 2>> "$SYNC_LOG" | 
                                 sed -E 's/.*=//; s/["'\'']//g' | tr '[:upper:]' '[:lower:]')
        elif [[ "$file" == *"Kconfig"* ]]; then
            # 从Kconfig提取芯片支持
            supported_chips=$(grep -E 'DEPENDS|COMPATIBLE' "$file" 2>> "$SYNC_LOG" | 
                             sed -E 's/.*=[[:space:]]*//; s/["'\'']//g; s/ /,/g' | tr '[:upper:]' '[:lower:]')
        fi

        # 去重并清理空值
        supported_devices=$(echo "$supported_devices" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')
        supported_vendors=$(echo "$supported_vendors" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')
        supported_platforms=$(echo "$supported_platforms" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')
        supported_chips=$(echo "$supported_chips" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')

        # 写入驱动元数据（去重）
        if [ ! -f "$driver_meta_dir/$driver_name.json" ]; then
            jq -n \
               --arg name "$driver_name" \
               --arg devs "$supported_devices" \
               --arg vendors "$supported_vendors" \
               --arg plats "$supported_platforms" \
               --arg chips "$supported_chips" \
               '{"name": $name, "supported_devices": $devs, "supported_vendors": $vendors, "supported_platforms": $plats, "supported_chips": $chips}' \
               > "$driver_meta_dir/$driver_name.json"
        fi

        processed_drv=$((processed_drv + 1))
        [ $((processed_drv % 200)) -eq 0 ] && log "ℹ️ 已解析 $processed_drv/$total_drv_files 个驱动文件"
    done < "$LOG_DIR/driver_files.tmp"

    # 3. 合并所有驱动元数据
    jq -s '{"drivers": .}' "$driver_meta_dir"/*.json > "$LOG_DIR/driver_list.json"
    local driver_count=$(jq '.drivers | length' "$LOG_DIR/driver_list.json" 2>/dev/null || echo 0)
    log "✅ 驱动元数据解析完成，共 $driver_count 个驱动"
}


# ==============================================
# 6. 设备驱动匹配（核心：优先设备直接匹配）
# ==============================================
match_drivers() {
    log "🔍 匹配设备驱动（优先设备名称/厂商/平台）..."
    local device_list="$LOG_DIR/device_list.json"
    local driver_list="$LOG_DIR/driver_list.json"
    local chip_list="$LOG_DIR/chip_list.json"

    # 初始化输出JSON
    jq -n '{
        "devices": [],
        "chips": [],
        "drivers": [],
        "metadata": {"last_sync": "'"$(date +%Y-%m-%dT%H:%M:%S)"'"}
    }' > "$OUTPUT_JSON"

    # 1. 导入驱动列表
    jq --argfile drvs "$driver_list" '.drivers = $drvs.drivers' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

    # 2. 导入芯片列表
    jq --argfile chips "$chip_list" '.chips = $chips.chips' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

    # 3. 为每个设备匹配驱动（优先级：设备名 > 厂商 > 平台 > 芯片）
    log "ℹ️ 开始为设备匹配驱动..."
    jq -c '.devices[]' "$device_list" | while read -r device; do
        local dev_name=$(echo "$device" | jq -r '.name')
        local dev_vendor=$(echo "$device" | jq -r '.vendor')
        local dev_platform=$(echo "$device" | jq -r '.platform')
        local dev_chip=$(echo "$device" | jq -r '.chip')

        log "ℹ️ 匹配设备：$dev_name（厂商：$dev_vendor，平台：$dev_platform）"

        # 核心匹配逻辑：计算驱动优先级并筛选
        local matched_drivers=$(jq --arg name "$dev_name" \
                                   --arg vendor "$dev_vendor" \
                                   --arg platform "$dev_platform" \
                                   --arg chip "$dev_chip" \
                                   '.drivers | map(
                                       . + {
                                           "priority": (
                                               (if (.supported_devices | split(",") | index($name)) then 4 else 0 end) +
                                               (if (.supported_vendors | split(",") | index($vendor)) then 3 else 0 end) +
                                               (if (.supported_platforms | split(",") | index($platform)) then 2 else 0 end) +
                                               (if (.supported_chips | split(",") | index($chip)) then 1 else 0 end)
                                           )
                                       } |
                                       select(.priority > 0) |
                                       sort_by(-.priority) |
                                       map(.name) |
                                       unique' \
                                   "$OUTPUT_JSON")

        # 如果无匹配，添加通用驱动兜底
        if [ "$(echo "$matched_drivers" | jq length)" -eq 0 ]; then
            log "⚠️ 设备 $dev_name 无匹配驱动，添加通用驱动"
            matched_drivers='["kmod-core", "kmod-net-core", "kmod-usb-core"]'
        fi

        # 更新设备的驱动列表
        jq --arg name "$dev_name" \
           --argjson drvs "$matched_drivers" \
           '.devices[] |= (if .name == $name then .drivers = $drvs else . end)' \
           "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    done

    # 4. 补充设备列表到输出
    jq --argfile devs "$device_list" '.devices = $devs.devices' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

    # 5. 最终统计
    local final_dev_count=$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    local final_drv_count=$(jq '.drivers | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)
    log "✅ 设备驱动匹配完成（设备：$final_dev_count 个，驱动：$final_drv_count 个）"
}


# ==============================================
# 7. 生成辅助配置（可选，保持完整性）
# ==============================================
generate_aux_configs() {
    log "🔍 生成核心功能和主题配置..."
    local config_dir="configs"
    mkdir -p "$config_dir"

    # 生成核心功能配置
    jq -n '{"features": ["ipv6", "vpn", "qos", "nat", "wifi", "none"]}' > "$config_dir/core-features.json"

    # 生成主题配置
    jq -n '{"themes": [{"name": "argon"}, {"name": "material"}, {"name": "bootstrap"}]}' > "$config_dir/theme-optimizations.json"

    log "✅ 辅助配置生成完成"
}


# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt设备同步系统启动（设备直接匹配模式）"
log "📅 同步时间：$(date +"%Y-%m-%d %H:%M:%S")"
log "========================================="

# 依次执行所有步骤
check_dependencies
clone_repositories
extract_devices
extract_chips  # 可选步骤，作为兜底
parse_driver_metadata
match_drivers
generate_aux_configs  # 可选步骤

# 输出最终统计
log "========================================="
log "✅ 所有同步任务完成"
log "📊 设备总数：$(jq '.devices | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 驱动总数：$(jq '.drivers | length' "$OUTPUT_JSON" 2>/dev/null || echo 0)"
log "📊 输出文件：$OUTPUT_JSON"
log "========================================="
