#!/bin/bash
# 从device-drivers.json动态生成build.yml的选项（修复版）

# 检查依赖
if ! command -v jq &> /dev/null; then
  echo "❌ 需要安装jq工具（sudo apt install jq）"
  exit 1
fi

# 检查配置文件
if [ ! -f "device-drivers.json" ]; then
  echo "❌ 未找到device-drivers.json，请先运行同步工作流"
  exit 1
fi

# 提取设备和芯片列表（用逗号分隔，适配YAML格式）
DEVICE_LIST=$(jq -r '.devices[].name' device-drivers.json | sort | uniq | tr '\n' ',' | sed 's/,$//')
CHIP_LIST=$(jq -r '.chips[].name' device-drivers.json | sort | uniq | tr '\n' ',' | sed 's/,$//')

# 兜底默认值（用逗号分隔）
[ -z "$DEVICE_LIST" ] && DEVICE_LIST="cudy-tr3000,redmi-ac2100,x86-64-generic,phicomm-k2p"
[ -z "$CHIP_LIST" ] && CHIP_LIST="mt7981,mt7621,x86_64,ipq8065,bcm53573"

# 临时文件存储生成的工作流
TMP_BUILD_YML=$(mktemp)

# 生成工作流头部（保留原文件结构，仅替换options）
cat > "$TMP_BUILD_YML" << EOF
name: OpenWrt全功能动态编译系统（自动生成）

on:
  workflow_dispatch:
    inputs:
      select_mode:
        type: choice
        description: 编译模式（设备/芯片）
        required: true
        options: [device, chip]

      device:
        type: choice
        description: 设备型号（仅设备模式）
        required: false
        options: [$DEVICE_LIST]

      chip:
        type: choice
        description: 芯片型号（仅芯片模式）
        required: false
        options: [$CHIP_LIST]

      source_branch:
        type: choice
        description: 源码分支
        required: true
        options: [openwrt-23.05, openwrt-master, immortalwrt-23.05, immortalwrt-master]

      theme_and_optimization:
        type: choice
        description: 主题+编译优化组合
        required: true
        options:
          - argon-O2-generic
          - argon-O3-armv8
          - argon-O3-x86
          - bootstrap-O2-generic
          - material-Os-generic

      core_features:
        type: choice
        description: 核心功能
        required: true
        options: [ipv6+accel, ipv6-only, accel-only, none]

      packages:
        type: string
        description: 软件包（格式：包1,包2）
        required: false
        default: "openclash,samba,ddns-scripts,luci-app-upnp"

      rootfs_size:
        type: number
        description: 根分区大小(MB，32-2048)
        required: true
        default: 192

      firmware_suffix:
        type: string
        description: 固件后缀（如版本号）
        required: false
        default: "custom"

      run_custom_script:
        type: boolean
        description: 执行自定义初始化脚本
        required: true
        default: true

jobs:
  build-firmware:
    name: 动态编译固件
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: write
      packages: write

    steps:
EOF

# 追加原build.yml中的steps内容（排除已生成的头部）
# 原理：从原文件中提取"steps:"之后的所有行（保留编译逻辑）
sed -n '/^    steps:/,$p' .github/workflows/build.yml | tail -n +2 >> "$TMP_BUILD_YML"

# 替换原工作流文件
mv "$TMP_BUILD_YML" .github/workflows/build.yml

echo "✅ 工作流生成完成"
echo "→ 设备选项：$DEVICE_LIST"
echo "→ 芯片选项：$CHIP_LIST"
