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

# 提取设备和芯片列表（生成YAML列表格式，每个选项单独一行）
# 修复点1：将设备列表转换为YAML列表格式（- 选项）
DEVICE_LIST=$(jq -r '.devices[].name' device-drivers.json | sort | uniq | sed 's/^/          - /')
CHIP_LIST=$(jq -r '.chips[].name' device-drivers.json | sort | uniq | sed 's/^/          - /')

# 兜底默认值（同样使用YAML列表格式）
# 修复点2：默认值也采用列表格式
if [ -z "$DEVICE_LIST" ]; then
  DEVICE_LIST=$(cat <<EOF
          - cudy-tr3000
          - redmi-ac2100
          - x86-64-generic
          - phicomm-k2p
EOF
  )
fi

if [ -z "$CHIP_LIST" ]; then
  CHIP_LIST=$(cat <<EOF
          - mt7981
          - mt7621
          - x86_64
          - ipq8065
          - bcm53573
EOF
  )
fi

# 临时文件存储生成的工作流
TMP_BUILD_YML=$(mktemp)

# 生成工作流头部（修复选项格式）
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
        options:
$DEVICE_LIST

      chip:
        type: choice
        description: 芯片型号（仅芯片模式）
        required: false
        options:
$CHIP_LIST

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
# 修复点3：增强兼容性，处理可能的空行或格式差异
if ! sed -n '/^    steps:/,$p' .github/workflows/build.yml | tail -n +2 >> "$TMP_BUILD_YML"; then
  echo "⚠️ 提取原有steps失败，使用默认编译步骤"
  cat >> "$TMP_BUILD_YML" << EOF
      - name: 拉取代码
        uses: actions/checkout@v4

      - name: 编译固件
        run: echo "开始编译..."
EOF
fi

# 替换原工作流文件（添加备份机制）
[ -f ".github/workflows/build.yml" ] && cp .github/workflows/build.yml .github/workflows/build.yml.bak
mv "$TMP_BUILD_YML" .github/workflows/build.yml

echo "✅ 工作流生成完成"
echo "→ 设备选项数：$(echo "$DEVICE_LIST" | grep -c '^          - ')"
echo "→ 芯片选项数：$(echo "$CHIP_LIST" | grep -c '^          - ')"
