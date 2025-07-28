#!/bin/bash
# 独立设备同步脚本：负责从OpenWrt仓库提取设备/芯片信息
# 解决动态嵌入导致的维护困难问题

# 配置参数（可根据需求修改）
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
BACKUP_REPO="https://github.com/openwrt/openwrt.git"  # 备用仓库
BRANCH="openwrt-23.05"                               # 同步的源码分支
TMP_DIR="./tmp-openwrt"                               # 临时目录
OUTPUT_FILE="device-drivers.json"                     # 输出设备配置
CANDIDATES_FILE="chip-candidates.txt"                 # 新芯片候选列表

# 清理旧文件
rm -rf "$TMP_DIR" "$CANDIDATES_FILE"

# 克隆源码（支持备用仓库）
clone_repo() {
  local repo=$1
  if git clone --depth 1 --branch "$BRANCH" "$repo" "$TMP_DIR"; then
    return 0
  fi
  return 1
}

echo "🔍 从官方仓库同步设备信息..."
if ! clone_repo "$OPENWRT_REPO"; then
  echo "⚠️ 官方仓库克隆失败，尝试备用仓库..."
  if ! clone_repo "$BACKUP_REPO"; then
    echo "⚠️ 所有仓库克隆失败，使用现有设备配置（若有）"
    [ -f "$OUTPUT_FILE" ] || { echo "❌ 无可用设备配置"; exit 1; }
    exit 0
  fi
fi

cd "$TMP_DIR/target/linux" || { echo "❌ 找不到设备配置目录"; exit 1; }

# 初始化JSON配置文件
echo '{"devices": [], "chips": []}' > ../../"$OUTPUT_FILE"

# 平台-芯片映射表（人工维护，确保准确性）
declare -A PLATFORM_CHIPS=(
  ["mediatek"]="mt7981 mt7621 mt7986 mt7620"
  ["ramips"]="mt7621 mt7620 rt3050 rt5350"
  ["ipq806x"]="ipq8065 ipq8064"
  ["x86"]="x86_64 i386"
  ["qualcommax"]="ipq6018 ipq807x"
  ["bcm53xx"]="bcm53573 bcm4709"
)

# 提取所有疑似芯片型号（用于自动提醒）
extract_candidates() {
  echo "🔍 提取疑似芯片型号..."
  # 从文件名和驱动中提取可能的芯片型号（正则匹配常见格式）
  find . -name "*.mk" -o -name "*.dts" | \
    grep -oE "mt[0-9]{4,5}|ipq[0-9]{4,5}|rt[0-9]{3,5}|bcm[0-9]{4,6}|x86_64|i386" | \
    sort -u > ../../"$CANDIDATES_FILE"
  
  # 过滤已在映射表中的芯片，只保留新候选
  mapped_chips=$(echo "${PLATFORM_CHIPS[@]}" | tr ' ' '\n' | sort -u)
  new_candidates=$(comm -23 ../../"$CANDIDATES_FILE" <(echo "$mapped_chips"))
  echo "$new_candidates" > ../../"$CANDIDATES_FILE"
}

# 遍历平台提取设备信息
for platform in "${!PLATFORM_CHIPS[@]}"; do
  [ -d "$platform" ] || continue
  echo "📦 处理平台：$platform（芯片：${PLATFORM_CHIPS[$platform]}）"
  
  # 提取设备配置文件
  find "$platform" -name "*.mk" | while read -r file; do
    # 提取设备名称
    device_name=$(grep "DEVICE_NAME" "$file" | cut -d'=' -f2 | tr -d '"' | sed 's/ //g')
    [ -z "$device_name" ] && continue  # 跳过无名称设备
    
    # 提取驱动包
    default_pkgs=$(grep "DEFAULT_PACKAGES" "$file" | cut -d'=' -f2)
    drivers=$(echo "$default_pkgs" | grep -oE "kmod-[a-z0-9-]+" | sort -u | tr '\n' ' ')
    [ -z "$drivers" ] && continue  # 跳过无驱动设备
    
    # 提取芯片型号（优先从文件名+映射表匹配）
    chip=$(echo "$file ${PLATFORM_CHIPS[$platform]}" | grep -oE "mt7981|mt7621|ipq8065|x86_64|rt3050|mt7986" | head -n1)
    [ -z "$chip" ] && chip=$(echo "${PLATFORM_CHIPS[$platform]}" | cut -d' ' -f1)  # 兜底取平台主芯片
    
    # 内核目标路径
    kernel_target="$platform/generic"
    
    # 写入设备信息
    echo "  - 新增设备：$device_name（芯片：$chip）"
    jq --arg name "$device_name" \
       --arg chip "$chip" \
       --arg target "$kernel_target" \
       --arg drivers "$drivers" \
       '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(length > 0)))}]' \
       ../../"$OUTPUT_FILE" > ../../"$OUTPUT_FILE.tmp" && mv ../../"$OUTPUT_FILE.tmp" ../../"$OUTPUT_FILE"
  done
  
  # 提取芯片通用驱动
  chip=$(echo "${PLATFORM_CHIPS[$platform]}" | cut -d' ' -f1)
  [ -z "$chip" ] && continue
  chip_drivers=$(grep "DEFAULT_PACKAGES" "$platform/Makefile" 2>/dev/null | grep -oE "kmod-[a-z0-9-]+" | sort -u | tr '\n' ' ')
  if [ -n "$chip_drivers" ]; then
    echo "  - 新增芯片驱动：$chip"
    jq --arg name "$chip" \
       --arg target "$platform/generic" \
       --arg drivers "$chip_drivers" \
       '.chips += [{"name": $name, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(length > 0)))}]' \
       ../../"$OUTPUT_FILE" > ../../"$OUTPUT_FILE.tmp" && mv ../../"$OUTPUT_FILE.tmp" ../../"$OUTPUT_FILE"
  fi
done

# 提取疑似新芯片并生成提醒
extract_candidates

# 清理临时文件
cd ../../ && rm -rf "$TMP_DIR"
echo "✅ 设备同步完成：$(jq '.devices | length' "$OUTPUT_FILE")个设备，$(jq '.chips | length' "$OUTPUT_FILE")个芯片"
