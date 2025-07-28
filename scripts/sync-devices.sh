#!/bin/bash
# 自动从OpenWrt源码同步设备信息，生成device-drivers.json

# 配置（可修改为ImmortalWrt仓库）
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
BRANCH="openwrt-23.05"
TMP_DIR="./tmp-openwrt"
OUTPUT_FILE="device-drivers.json"

# 清理旧文件
rm -rf $TMP_DIR $OUTPUT_FILE

# 克隆OpenWrt设备配置（仅同步target/linux目录，体积小）
echo "🔍 从 $OPENWRT_REPO 同步设备信息..."
git clone --depth 1 --branch $BRANCH --single-branch $OPENWRT_REPO $TMP_DIR &> /dev/null
cd $TMP_DIR/target/linux || exit 1

# 初始化JSON结构
echo '{"devices": [], "chips": []}' > ../../$OUTPUT_FILE

# 遍历所有平台（如mediatek、ramips、x86等）
for platform in $(ls -d */ | cut -d'/' -f1); do
  echo "📦 处理平台：$platform"
  
  # 遍历平台下的设备配置（一般在generic或specific目录）
  for device_dir in $(find $platform -name "profiles" -o -name "devices" | grep -v "patches"); do
    # 提取设备名称和芯片信息
    for device_file in $(find $device_dir -name "*.mk" -o -name "*.dts"); do
      # 从.mk文件提取设备名称和芯片
      if [[ $device_file == *.mk ]]; then
        device_name=$(grep "DEVICE_NAME" $device_file | cut -d'=' -f2 | tr -d '"')
        chip=$(grep "FEATURES" $device_file | grep -oE "mt7981|mt7621|ipq8065|x86_64" | head -n1)
        kernel_target="$platform/generic"  # 内核目标路径（如mediatek/filogic）
        
        # 从配置中提取驱动（简化逻辑：匹配常见驱动包名）
        drivers=$(grep "DEFAULT_PACKAGES" $device_file | grep -oE "kmod-[a-z0-9-]+" | tr '\n' ' ')
        
        # 若信息完整，添加到JSON
        if [[ -n $device_name && -n $chip && -n $drivers ]]; then
          echo "  - 发现设备：$device_name（芯片：$chip）"
          jq --arg name "$device_name" \
             --arg chip "$chip" \
             --arg target "$kernel_target" \
             --arg drivers "$drivers" \
             '.devices += [{"name": $name, "chip": $chip, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(length > 0)))}]' \
             ../../$OUTPUT_FILE > ../../$OUTPUT_FILE.tmp && mv ../../$OUTPUT_FILE.tmp ../../$OUTPUT_FILE
        fi
      fi
    done
  done
  
  # 提取芯片级信息（同一芯片的通用驱动）
  chip=$(echo $platform | grep -oE "mt7981|mt7621|ipq8065|x86_64" | head -n1)
  if [[ -n $chip ]]; then
    # 芯片通用驱动（从平台默认配置提取）
    chip_drivers=$(grep "DEFAULT_PACKAGES" $platform/Makefile 2>/dev/null | grep -oE "kmod-[a-z0-9-]+" | tr '\n' ' ')
    if [[ -n $chip_drivers ]]; then
      jq --arg name "$chip" \
         --arg target "$platform/generic" \
         --arg drivers "$chip_drivers" \
         '.chips += [{"name": $name, "kernel_target": $target, "drivers": ($drivers | split(" ") | map(select(length > 0)))}]' \
         ../../$OUTPUT_FILE > ../../$OUTPUT_FILE.tmp && mv ../../$OUTPUT_FILE.tmp ../../$OUTPUT_FILE
    fi
  fi
done

# 清理临时文件
cd ../../ && rm -rf $TMP_DIR
echo "✅ 自动生成完成：$OUTPUT_FILE"
echo "📊 设备数量：$(jq '.devices | length' $OUTPUT_FILE) 个"
echo "📊 芯片数量：$(jq '.chips | length' $OUTPUT_FILE) 个"
