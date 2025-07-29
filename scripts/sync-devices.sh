#!/bin/bash
set -euo pipefail

# 定义平台与芯片的映射关系（扩展此表以支持更多平台）
declare -A PLATFORM_CHIPS=(
    ["mediatek/filogic"]="mt7981 mt7986 mt7983"
    ["mediatek/mt7622"]="mt7622"
    ["ramips/mt7621"]="mt7621"
    ["ipq806x/generic"]="ipq8065 ipq8064"
    ["x86/64"]="x86_64"
    ["bcm53xx/generic"]="bcm53573 bcm4708"
)

# 临时文件
TMP_DEVICES=$(mktemp)
TMP_CHIPS=$(mktemp)
CANDIDATES="chip-candidates.txt"
> "$CANDIDATES"  # 清空候选文件

# 初始化JSON结构
echo '{"devices": [], "chips": []}' > "device-drivers.json"

# 克隆临时源码（用于提取设备信息，不保留本地副本）
echo "📥 克隆OpenWrt源码（临时，仅用于提取设备信息）"
TMP_SRC=$(mktemp -d)
git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC" >/dev/null 2>&1

# 提取设备和芯片信息
echo "🔍 开始提取设备和芯片信息..."
for platform in "${!PLATFORM_CHIPS[@]}"; do
    platform_path="$TMP_SRC/target/linux/$platform"
    [ -d "$platform_path" ] || continue
    
    # 提取该平台下的设备
    find "$platform_path" -name "*.mk" | while read -r file; do
        # 提取设备名称（处理下划线/连字符转换）
        device_name=$(grep "DEVICE_NAME" "$file" | cut -d'=' -f2 | tr -d '"' | sed 's/ //g' | tr '_' '-')
        [ -z "$device_name" ] && continue
        
        # 提取默认驱动包
        default_pkgs=$(grep "DEFAULT_PACKAGES" "$file" | cut -d'=' -f2 | tr -d '"')
        drivers=$(echo "$default_pkgs" | grep -oE "kmod-[a-z0-9-]+" | sort -u | tr '\n' ' ')
        
        # 关联芯片（来自平台映射表）
        chips=${PLATFORM_CHIPS[$platform]}
        main_chip=$(echo "$chips" | awk '{print $1}')  # 取第一个芯片作为主芯片
        
        # 添加到设备列表（去重）
        if ! grep -q "$device_name" "$TMP_DEVICES"; then
            echo "$device_name" >> "$TMP_DEVICES"
            echo "  - 新增设备：$device_name（芯片：$main_chip）"
            # 写入JSON
            jq --arg name "$device_name" \
               --arg chip "$main_chip" \
               --arg target "$platform" \
               --arg drivers "$drivers" \
               '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(. != "")))}]' \
               "device-drivers.json" > "tmp.json" && mv "tmp.json" "device-drivers.json"
        fi
    done
    
    # 提取芯片信息
    for chip in $chips; do
        if ! grep -q "$chip" "$TMP_CHIPS"; then
            echo "$chip" >> "$TMP_CHIPS"
            echo "  - 新增芯片：$chip（平台：$platform）"
            # 写入JSON
            jq --arg name "$chip" \
               --arg platform "$platform" \
               '.chips += [{"name": $name, "platform": $platform}]' \
               "device-drivers.json" > "tmp.json" && mv "tmp.json" "device-drivers.json"
        fi
    done
done

# 检测未识别的芯片（可选，用于扩展PLATFORM_CHIPS）
find "$TMP_SRC/target/linux" -name "*.dts" | while read -r dts; do
    chip=$(basename "$dts" .dts | grep -oE "mt[0-9]+|ipq[0-9]+|bcm[0-9]+|rt[0-9]+" | head -n1)
    [ -z "$chip" ] && continue
    if ! grep -q "$chip" "$TMP_CHIPS" && ! grep -q "$chip" "$CANDIDATES"; then
        echo "$chip" >> "$CANDIDATES"
    fi
done

# 清理临时文件
rm -rf "$TMP_SRC" "$TMP_DEVICES" "$TMP_CHIPS"
echo "✅ 设备同步完成，结果已保存到 device-drivers.json"
