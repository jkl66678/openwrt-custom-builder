#!/bin/bash
# 从device-drivers.json生成build.yml

# 检查依赖
if ! command -v jq &> /dev/null; then
  echo "❌ 需要安装jq工具"
  exit 1
fi

# 检查配置文件
if [ ! -f "device-drivers.json" ]; then
  echo "❌ 未找到device-drivers.json"
  exit 1
fi

# 提取设备和芯片列表
DEVICE_LIST=$(jq -r '.devices[].name' device-drivers.json | sort | uniq | tr '\n' ' ')
CHIP_LIST=$(jq -r '.chips[].name' device-drivers.json | sort | uniq | tr '\n' ' ')

# 兜底默认值
[ -z "$DEVICE_LIST" ] && DEVICE_LIST="cudy-tr3000 redmi-ac2100 x86-64-generic"
[ -z "$CHIP_LIST" ] && CHIP_LIST="mt7981 mt7621 x86_64"

# 生成工作流
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
      - name: 拉取代码
        uses: actions/checkout@v4

      - name: 安装依赖
        run: |
          sudo apt update
          sudo apt install -y build-essential libncurses5-dev libncursesw5-dev \
            zlib1g-dev gawk git gettext libssl-dev xsltproc wget unzip python3 jq

      # 以下步骤与完整编译逻辑一致（省略，保持与build.yml相同）
EOF

# 追加编译步骤（复用现有逻辑）
tail -n +$(grep -n "steps:" .github/workflows/build.yml | cut -d':' -f1) .github/workflows/build.yml >> .github/workflows/build.yml

echo "✅ 工作流生成完成，设备选项：$DEVICE_LIST"
