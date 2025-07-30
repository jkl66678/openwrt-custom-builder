#!/bin/bash
set -uo pipefail

# 强制UTF-8编码（解决中文乱码）
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# ==============================================
# 基础配置与初始化
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
OUTPUT_WORKFLOW=".github/workflows/build.yml"
DEVICE_JSON="$WORK_DIR/device-drivers.json"
BRANCHES_FILE="$LOG_DIR/source_branches.tmp"
CORE_FEATURES="configs/core-features.json"
THEME_OPTS="configs/theme-optimizations.json"
WORKFLOW_LOG="$LOG_DIR/workflow-generate.log"

# 创建输出目录
mkdir -p "$(dirname "$OUTPUT_WORKFLOW")" || {
    echo "❌ 无法创建工作流目录: $(dirname "$OUTPUT_WORKFLOW")" >&2
    exit 1
}
> "$WORKFLOW_LOG"  # 清空日志

# 日志函数（确保中文正常输出）
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$timestamp" "$1" | tee -a "$WORKFLOW_LOG"
}

# ==============================================
# 1. 依赖与输入检查
# ==============================================
check_requirements() {
    log "🔍 检查工作流生成依赖..."
    
    # 检查必要工具
    local required_tools=("jq" "grep" "sed" "awk" "yamlfmt")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具: $tool（请先安装）"
            exit 1
        fi
    done

    # 检查输入文件
    local input_files=("$BRANCHES_FILE" "$DEVICE_JSON" "$CORE_FEATURES" "$THEME_OPTS")
    for file in "${input_files[@]}"; do
        if [ ! -f "$file" ]; then
            log "❌ 输入文件不存在: $file"
            exit 1
        fi
        if [ ! -s "$file" ]; then
            log "❌ 输入文件为空: $file"
            exit 1
        fi
    done

    log "✅ 依赖检查通过"
}

# ==============================================
# 2. 提取构建参数（支持中文设备名）
# ==============================================
extract_parameters() {
    log "🔍 提取构建参数..."

    # 提取分支列表（去重排序）
    BRANCHES=$(jq -Rn '[inputs]' "$BRANCHES_FILE" | jq -c '.')
    log "ℹ️ 提取分支数: $(echo "$BRANCHES" | jq 'length')"

    # 提取设备列表（保留中文，过滤特殊字符）
    DEVICES=$(jq -c '.devices[].name' "$DEVICE_JSON" | 
              sed -E 's/[\\"]/\\\\&/g' |  # 转义引号和反斜杠
              jq -Rn '[inputs]')
    log "ℹ️ 提取设备数: $(echo "$DEVICES" | jq 'length')"

    # 提取芯片架构
    ARCHITECTURES=$(jq -r '.chips[].platforms' "$DEVICE_JSON" | 
                    tr ',' '\n' | sort -u | grep -v '^$' | 
                    jq -Rn '[inputs]')
    log "ℹ️ 提取架构数: $(echo "$ARCHITECTURES" | jq 'length')"

    # 提取核心功能
    FEATURES=$(jq -c '.features' "$CORE_FEATURES")
    log "ℹ️ 提取功能数: $(echo "$FEATURES" | jq 'length')"

    # 提取主题列表
    THEMES=$(jq -c '.themes[].name' "$THEME_OPTS" | jq -Rn '[inputs]')
    log "ℹ️ 提取主题数: $(echo "$THEMES" | jq 'length')"
}

# ==============================================
# 3. 生成工作流YAML（核心逻辑）
# ==============================================
generate_yaml() {
    log "📝 开始生成工作流文件..."
    local tmp_yaml=$(mktemp -t workflow-XXXXXX.yml)

    # 写入YAML头部
    cat <<EOF > "$tmp_yaml"
# 自动生成的OpenWrt编译工作流
# 生成时间: $(date +"%Y-%m-%d %H:%M:%S")
name: OpenWrt 自动编译

on:
  workflow_dispatch:
    inputs:
      branch:
        description: '源码分支'
        required: true
        type: choice
        options: $(echo "$BRANCHES" | jq -r '.[] | "          - \"" + . + "\""')
      
      device:
        description: '目标设备（支持中文）'
        required: true
        type: choice
        options: $(echo "$DEVICES" | jq -r '.[] | "          - \"" + . + "\""')
      
      arch:
        description: '芯片架构'
        required: true
        type: choice
        options: $(echo "$ARCHITECTURES" | jq -r '.[] | select(. != "") | "          - \"" + . + "\""')
      
      features:
        description: '核心功能组合'
        required: true
        type: choice
        options: $(echo "$FEATURES" | jq -r '.[] | "          - \"" + . + "\""')
      
      theme:
        description: 'Web界面主题'
        required: true
        type: choice
        options: $(echo "$THEMES" | jq -r '.[] | "          - \"" + . + "\""')
      
      optimize:
        description: '编译优化级别'
        required: true
        type: choice
        options:
          - "O2"
          - "O3"
          - "Os"

  schedule:
    - cron: '0 0 * * 0'  # 每周日凌晨执行

jobs:
  build:
    name: 编译 OpenWrt 固件
    runs-on: ubuntu-22.04
    timeout-minutes: 360

    steps:
      - name: 检查源码
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: 初始化编译环境
        run: |
          sudo apt update -y
          sudo apt install -y build-essential clang flex bison g++ gawk \
            gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
            python3-distutils rsync unzip zlib1g-dev file wget curl jq
          echo "编译环境初始化完成"

      - name: 加载设备配置
        id: device-config
        run: |
          # 从设备JSON中提取芯片信息
          CHIP=\$(jq -r --arg device "\${{ github.event.inputs.device }}" \
            '.devices[] | select(.name == \$device) | .chip' "$DEVICE_JSON")
          echo "芯片型号: \$CHIP"
          echo "chip=\$CHIP" >> \$GITHUB_OUTPUT

          # 提取对应驱动
          DRIVERS=\$(jq -r --arg chip "\$CHIP" \
            '.chips[] | select(.name == \$chip) | .default_drivers | join(" ")' "$DEVICE_JSON")
          echo "驱动列表: \$DRIVERS"
          echo "drivers=\$DRIVERS" >> \$GITHUB_OUTPUT

      - name: 克隆源码
        run: |
          BRANCH=\${{ github.event.inputs.branch }}
          # 拆分仓库前缀和分支名（如 openwrt-master → 仓库+分支）
          REPO_PREFIX=\$(echo "\$BRANCH" | cut -d'-' -f1)
          BRANCH_NAME=\$(echo "\$BRANCH" | cut -d'-' -f2-)
          
          # 对应仓库地址
          if [ "\$REPO_PREFIX" = "immortalwrt" ]; then
            git clone --depth 1 -b \$BRANCH_NAME https://github.com/immortalwrt/immortalwrt.git openwrt
          else
            git clone --depth 1 -b \$BRANCH_NAME https://git.openwrt.org/openwrt/openwrt.git openwrt
          fi
          cd openwrt

      - name: 安装 feeds
        run: |
          cd openwrt
          ./scripts/feeds update -a
          ./scripts/feeds install -a
          # 安装设备所需驱动
          echo "安装驱动: \${{ steps.device-config.outputs.drivers }}"
          for driver in \${{ steps.device-config.outputs.drivers }}; do
            ./scripts/feeds install \$(echo \$driver | cut -d'@' -f1) || true
          done

      - name: 配置编译选项
        run: |
          cd openwrt
          # 加载默认配置
          make defconfig
          
          # 应用架构配置
          echo "CONFIG_TARGET_\${{ github.event.inputs.arch }}=y" >> .config
          
          # 应用功能配置
          case "\${{ github.event.inputs.features }}" in
            *ipv6*) echo "CONFIG_IPV6=y" >> .config ;;
            *vpn*) echo "CONFIG_PACKAGE_luci-app-openvpn=y" >> .config ;;
            *qos*) echo "CONFIG_PACKAGE_luci-app-qos=y" >> .config ;;
          esac
          
          # 应用主题配置
          THEME=\${{ github.event.inputs.theme }}
          echo "CONFIG_PACKAGE_luci-theme-\$THEME=y" >> .config
          
          # 应用优化级别
          echo "CONFIG_CFLAGS=-O\${{ github.event.inputs.optimize }}" >> .config
          echo "CONFIG_CXXFLAGS=-O\${{ github.event.inputs.optimize }}" >> .config
          
          # 保存配置
          make defconfig

      - name: 开始编译
        run: |
          cd openwrt
          make download -j8
          make -j\$(nproc) || make -j1 V=s  # 编译失败时单线程输出详细日志

      - name: 收集编译产物
        id: collect
        run: |
          cd openwrt/bin/targets/*/*
          FIRMWARE_FILE=\$(find . -name "*.bin" | head -n1)
          echo "固件路径: \$FIRMWARE_FILE"
          echo "firmware=\$(basename \$FIRMWARE_FILE)" >> \$GITHUB_OUTPUT
          mv \$FIRMWARE_FILE ../../../..

      - name: 上传固件
        uses: actions/upload-artifact@v4
        with:
          name: openwrt-firmware-${{ github.event.inputs.device }}
          path: ${{ steps.collect.outputs.firmware }}
          retention-days: 30
EOF

    # 格式化YAML（确保语法正确）
    if ! yamlfmt "$tmp_yaml" &> /dev/null; then
        log "⚠️ YAML格式化失败，尝试手动修复"
        # 手动修复常见格式问题
        sed -i 's/    - /  - /g' "$tmp_yaml"
        sed -i 's/        - /    - /g' "$tmp_yaml"
    fi

    # 移动临时文件到目标位置
    mv "$tmp_yaml" "$OUTPUT_WORKFLOW"
    log "✅ 工作流文件生成完成: $OUTPUT_WORKFLOW"
}

# ==============================================
# 4. 验证工作流文件
# ==============================================
validate_workflow() {
    log "🔍 验证工作流文件有效性..."
    
    # 检查文件存在性
    if [ ! -f "$OUTPUT_WORKFLOW" ]; then
        log "❌ 工作流文件未生成: $OUTPUT_WORKFLOW"
        exit 1
    fi
    
    # 检查YAML语法（使用jq间接验证）
    if ! yq eval '.' "$OUTPUT_WORKFLOW" &> /dev/null; then
        log "❌ 工作流文件语法错误: $OUTPUT_WORKFLOW"
        exit 1
    fi
    
    # 检查关键配置是否存在
    local required_keys=("name" "on" "jobs.build.runs-on")
    for key in "${required_keys[@]}"; do
        if ! yq eval ".$key" "$OUTPUT_WORKFLOW" &> /dev/null; then
            log "❌ 工作流缺少关键配置: $key"
            exit 1
        fi
    done
    
    log "✅ 工作流文件验证通过"
}

# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt工作流生成工具启动"
log "========================================="

check_requirements
extract_parameters
generate_yaml
validate_workflow

log "========================================="
log "✅ 工作流生成全部完成"
log "📌 输出文件: $OUTPUT_WORKFLOW"
log "========================================="
