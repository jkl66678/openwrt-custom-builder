#!/bin/bash
# 从device-drivers.json读取设备列表，动态生成build.yml工作流

# 检查依赖
if ! command -v jq &> /dev/null; then
  echo "❌ 错误：需要安装jq工具（用于解析JSON）"
  exit 1
fi

# 检查设备配置文件
if [ ! -f "device-drivers.json" ]; then
  echo "❌ 错误：未找到device-drivers.json，请先运行同步脚本"
  exit 1
fi

# 从JSON中提取设备列表（按名称排序，去重）
DEVICE_LIST=$(jq -r '.devices[].name' device-drivers.json | sort | uniq | tr '\n' ' ')
# 提取芯片列表
CHIP_LIST=$(jq -r '.chips[].name' device-drivers.json | sort | uniq | tr '\n' ' ')

# 检查是否有设备
if [ -z "$DEVICE_LIST" ]; then
  echo "⚠️ 警告：未提取到任何设备，使用默认设备列表"
  DEVICE_LIST="cudy-tr3000 redmi-ac2100 x86_64-generic"
fi

if [ -z "$CHIP_LIST" ]; then
  echo "⚠️ 警告：未提取到任何芯片，使用默认芯片列表"
  CHIP_LIST="mt7981 mt7621 x86_64"
fi

# 生成工作流内容（替换设备和芯片选项）
cat > .github/workflows/build.yml << EOF
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
        description: 源码分支（含内核）
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
        description: 核心功能（IPv6+硬件加速）
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

  schedule:
    - cron: "0 0 * * 0"

jobs:
  sync-devices:
    name: 同步设备与芯片信息
    runs-on: ubuntu-latest
    steps:
      - name: 拉取仓库代码
        uses: actions/checkout@v4

      - name: 检查同步脚本
        run: |
          if [ ! -f "scripts/sync-devices.sh" ]; then
            echo "❌ 未找到同步脚本"
            exit 1
          fi

      - name: 安装依赖
        run: sudo apt install -y git jq gh

      - name: 执行同步脚本
        run: |
          chmod +x scripts/sync-devices.sh
          ./scripts/sync-devices.sh

      - name: 生成新工作流（含最新设备）
        run: |
          chmod +x scripts/generate-workflow.sh
          ./scripts/generate-workflow.sh

      - name: 提交更新
        run: |
          git config --global user.name "Auto-Bot"
          git config --global user.email "bot@github.com"
          git add .github/workflows/build.yml device-drivers.json
          if git diff --cached --quiet; then
            echo "⚠️ 无更新"
          else
            git commit -m "自动更新设备列表（$(date +%Y%m%d)）"
            git push
          fi

  build-firmware:
    name: 动态编译固件
    needs: sync-devices
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: write
      packages: write

    steps:
      - name: 拉取代码
        uses: actions/checkout@v4

      - name: 安装依赖
        run: |
          sudo apt update
          sudo apt install -y build-essential libncurses5-dev libncursesw5-dev \
            zlib1g-dev gawk git gettext libssl-dev xsltproc wget unzip python3 jq

      # 以下步骤与之前的编译逻辑相同（省略，保持原样）
      # ...（包含硬件检测、动态线程计算、源码拉取、编译等步骤）
EOF

echo "✅ 工作流已生成，设备选项：$DEVICE_LIST"
