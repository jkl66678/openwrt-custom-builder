#!/bin/bash

# ==============================================
# 全局变量定义
# ==============================================
OUTPUT_WORKFLOW=".github/workflows/build.yml"
DEVICE_JSON="device-drivers.json"
BRANCHES_FILE="sync-logs/source_branches.tmp"
CONFIG_DIR="configs"

# ==============================================
# 日志输出函数
# ==============================================
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${1}] ${2}"
}

# ==============================================
# 检查依赖工具
# ==============================================
check_requirements() {
    log "INFO" "检查系统依赖..."
    
    # 基础工具检查
    local required_tools=("jq" "yq" "yamlfmt" "git" "curl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "ERROR" "缺少必需工具：$tool"
            exit 1
        fi
    done
    
    # 检查YAML工具版本
    if [[ $(yq --version | cut -d'.' -f1) -lt 4 ]]; then
        log "WARNING" "建议使用yq v4+，当前版本可能存在兼容性问题"
    fi
    
    log "INFO" "系统依赖检查通过"
}

# ==============================================
# 提取构建参数
# ==============================================
extract_parameters() {
    log "INFO" "提取构建参数..."
    
    # 提取分支列表
    BRANCHES=$(jq -Rn '[inputs]' "$BRANCHES_FILE" | jq -c '.')
    if [[ -z "$BRANCHES" || $(echo "$BRANCHES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "分支列表为空，无法生成工作流"
        exit 1
    fi
    log "DEBUG" "分支列表：$BRANCHES"

    # 提取设备列表
    DEVICES=$(jq -c '.devices[].name' "$DEVICE_JSON" | sed -E 's/[\\"]/\\\\&/g' | jq -Rn '[inputs]')
    if [[ -z "$DEVICES" || $(echo "$DEVICES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "设备列表为空，无法生成工作流"
        exit 1
    fi
    log "DEBUG" "设备列表：$DEVICES"

    # 提取芯片架构列表
    ARCHITECTURES=$(jq -c '.chips[].name' "$DEVICE_JSON" | jq -Rn '[inputs]')
    if [[ -z "$ARCHITECTURES" ]]; then
        log "WARNING" "未检测到芯片架构信息，使用默认架构列表"
        ARCHITECTURES='["mt7621", "x86_64", "ipq8065"]'  # 备用默认值
    fi
    log "DEBUG" "芯片架构列表：$ARCHITECTURES"

    # 提取核心功能组合
    FEATURES=$(jq -c '.[] | .name' "$CONFIG_DIR/core-features.json" | jq -Rn '[inputs]')
    if [[ -z "$FEATURES" ]]; then
        log "ERROR" "核心功能配置文件为空"
        exit 1
    fi
    log "DEBUG" "核心功能列表：$FEATURES"

    # 提取主题配置
    THEMES=$(jq -c '.[] | .name' "$CONFIG_DIR/theme-optimizations.json" | jq -Rn '[inputs]')
    if [[ -z "$THEMES" ]]; then
        log "ERROR" "主题配置文件为空"
        exit 1
    fi
    log "DEBUG" "主题列表：$THEMES"
}

# ==============================================
# 生成YAML工作流文件
# ==============================================
generate_yaml() {
    log "INFO" "开始生成工作流文件..."
    local tmp_yaml=$(mktemp -t workflow-XXXXXX.yml)

    # 生成YAML头部
    cat <<EOF > "$tmp_yaml"
name: OpenWrt 固件自动编译系统

on:
  workflow_dispatch:
    inputs:
      branch:
        description: '源码分支'
        required: true
        type: choice
        options:
$(echo "$BRANCHES" | jq -r '.[] | "          - \"" + . + "\""')

      device:
        description: '目标设备（支持中文）'
        required: true
        type: choice
        options:
$(echo "$DEVICES" | jq -r '.[] | "          - \"" + . + "\""')

      arch:
        description: '芯片架构'
        required: true
        type: choice
        options:
$(echo "$ARCHITECTURES" | jq -r '.[] | select(. != "") | "          - \"" + . + "\""')

      features:
        description: '核心功能组合'
        required: true
        type: choice
        options:
$(echo "$FEATURES" | jq -r '.[] | "          - \"" + . + "\""')

      theme:
        description: 'Web界面主题'
        required: true
        type: choice
        options:
$(echo "$THEMES" | jq -r '.[] | "          - \"" + . + "\""')

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
  build-firmware:
    name: 编译固件
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: write
      packages: write

    steps:
      - name: 拉取仓库代码（含子模块）
        uses: actions/checkout@v4
        with:
          fetch-depth: 1
          submodules: "recursive"

      - name: 检查核心配置文件
        run: |
          # 检查设备配置文件
          if [! -f "device-drivers.json" ]; then
            echo "❌ 未找到设备配置文件 device-drivers.json，请先运行同步工作流"
            exit 1
          fi
          # 检查自定义脚本（如果启用）
          if [ "\${{ github.event.inputs.run_custom_script }}" = "true" ] && [! -f "scripts/custom-init.sh" ]; then
            echo "❌ 启用了自定义脚本但未找到 scripts/custom-init.sh"
            exit 1
          fi
          echo "✅ 核心配置文件检查通过"

      - name: 安装系统依赖（自动适配最新版本）
        run: |
          # 保留官方源，更新包索引
          sudo apt clean
          sudo apt update -y --fix-missing

          # 安装完整系统依赖
          sudo apt install -y \
            build-essential libncurses5-dev libncursesw5-dev \
            zlib1g-dev gawk git gettext libssl-dev xsltproc \
            wget unzip python3 python3-pip jq time curl ca-certificates \
            libelf-dev libzstd-dev flex bison locales dos2unix

          # 配置UTF-8本地化
          sudo locale-gen en_US.UTF-8
          sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

          # 动态安装最新版Go
          GO_LATEST_TAG=$(curl -s "https://api.github.com/repos/golang/go/releases/latest" | jq -r '.tag_name')
          GO_VERSION=${GO_LATEST_TAG#go}
          GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
          wget -O /tmp/${GO_TAR} "https://dl.google.com/go/${GO_TAR}" || wget -O /tmp/${GO_TAR} "https://gomirrors.org/dl/go/${GO_TAR}"
          sudo rm -rf /usr/local/go
          sudo tar -C /usr/local -xzf /tmp/${GO_TAR}
          echo "/usr/local/go/bin" >> \$GITHUB_PATH

          # 安装最新版yq和yamlfmt
          sudo snap install yq
          go install github.com/google/yamlfmt/cmd/yamlfmt@latest
          echo "\$HOME/go/bin" >> \$GITHUB_PATH

          # 升级Python工具链
          pip3 install --upgrade pip requests

      - name: 硬件资源详细检测
        run: |
          echo "🖥️ 编译环境信息："
          echo "  - CPU型号：\$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed -e 's/^ *//')"
          echo "  - 核心数：\$(grep -c ^processor /proc/cpuinfo)"
          echo "  - 总内存：\$(free -h | awk '/^Mem:/ {print $2}')"
          echo "  - 可用内存：\$(free -h | awk '/^Mem:/ {print $7}')"

      - name: 初始化编译环境
        run: |
          cd openwrt
          ./scripts/feeds update -a
          ./scripts/feeds install -a

      - name: 配置编译选项
        run: |
          cd openwrt
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
          echo "CONFIG_PACKAGE_luci-theme-\${{ github.event.inputs.theme }}=y" >> .config

          # 应用优化级别
          echo "CONFIG_CFLAGS=-O\${{ github.event.inputs.optimize }}" >> .config
          echo "CONFIG_CXXFLAGS=-O\${{ github.event.inputs.optimize }}" >> .config

          make defconfig

      - name: 开始编译
        run: |
          cd openwrt
          make download -j8
          make -j\$(nproc) || make -j1 V=s

      - name: 收集编译产物
        id: collect
        run: |
          cd openwrt/bin/targets/*/*
          FIRMWARE_FILE=\$(find . -name "*.bin" | head -n1)
          echo "固件路径: \$FIRMWARE_FILE"
          echo "firmware=\$(basename \$FIRMWARE_FILE)" >> \$GITHUB_OUTPUT
          mv \$FIRMWARE_FILE../../../..

      - name: 上传固件
        uses: actions/upload-artifact@v4
        with:
          name: openwrt-firmware-\${{ github.event.inputs.device }}
          path: \${{ steps.collect.outputs.firmware }}
          retention-days: 30
EOF

    # 检查临时文件是否生成成功
    if [[ ! -s "$tmp_yaml" ]]; then
        log "ERROR" "临时工作流文件生成失败（为空）"
        exit 1
    fi

    # 格式化YAML并修复缩进
    if ! yamlfmt "$tmp_yaml"; then
        log "WARNING" "YAML格式化失败，尝试手动修复缩进"
        sed -i 's/^    - /  - /g' "$tmp_yaml"
        sed -i 's/^        - /    - /g' "$tmp_yaml"
    fi

    # 二次验证YAML语法
    if ! yq eval '.' "$tmp_yaml" &> /dev/null; then
        log "ERROR" "生成的YAML语法错误"
        cat "$tmp_yaml"
        exit 1
    fi

    # 移动到目标位置
    mv "$tmp_yaml" "$OUTPUT_WORKFLOW"
    log "INFO" "工作流文件生成完成: $OUTPUT_WORKFLOW"
}

# ==============================================
# 验证工作流文件
# ==============================================
validate_workflow() {
    log "INFO" "验证工作流文件有效性..."
    
    # 检查文件存在性和非空
    if [[ ! -f "$OUTPUT_WORKFLOW" || ! -s "$OUTPUT_WORKFLOW" ]]; then
        log "ERROR" "工作流文件未生成或为空"
        exit 1
    fi

    # 检查关键配置项
    local required_keys=("name" "on" "jobs.build-firmware.runs-on")
    for key in "${required_keys[@]}"; do
        if ! yq eval ".$key" "$OUTPUT_WORKFLOW" &> /dev/null; then
            log "ERROR" "工作流缺少关键配置: $key"
            exit 1
        fi
    done

    # 使用yamllint进行深度校验
    if ! yamllint "$OUTPUT_WORKFLOW"; then
        log "ERROR" "yamllint校验失败，请检查格式"
        exit 1
    fi

    log "INFO" "工作流文件验证通过"
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
