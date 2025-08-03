#!/bin/bash
set -uo pipefail

# ==============================================
# 全局变量定义
# ==============================================
OUTPUT_WORKFLOW=".github/workflows/build.yml"
DEVICE_JSON="device-drivers.json"
BRANCHES_FILE="sync-logs/source_branches.tmp"
CONFIG_DIR="configs"
# 确保日志输出格式统一
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# ==============================================
# 日志输出函数（增强错误定位）
# ==============================================
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"$LOG_TIMESTAMP_FORMAT")
    # 不同级别日志使用不同前缀，便于区分
    case "$level" in
        "INFO")  echo -e "${timestamp} [\033[32m${level}\033[0m] ${message}" ;;
        "ERROR") echo -e "${timestamp} [\033[31m${level}\033[0m] ${message}" >&2 ;;
        "WARN")  echo -e "${timestamp} [\033[33m${level}\033[0m] ${message}" ;;
        "DEBUG") echo -e "${timestamp} [\033[34m${level}\033[0m] ${message}" ;;
        *)       echo -e "${timestamp} [${level}] ${message}" ;;
    esac
}

# ==============================================
# 检查依赖工具（修复语法错误和版本检查）
# ==============================================
check_requirements() {
    log "INFO" "检查系统依赖..."
    
    # 基础工具检查（按重要性排序）
    local required_tools=("jq" "yq" "git" "curl" "yamlfmt")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "ERROR" "缺少必需工具：$tool（请先安装）"
            exit 1
        fi
    done

    # 检查yq版本（修复语法错误，正确处理版本输出）
    if ! yq_version=$(yq --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | cut -d'v' -f2); then
        log "ERROR" "无法解析yq版本，请确保安装的是mikefarah/yq（而非python-yq）"
        log "ERROR" "安装地址：https://github.com/mikefarah/yq/releases"
        exit 1
    fi
    local yq_major=$(echo "$yq_version" | cut -d'.' -f1)
    if [[ "$yq_major" -lt 4 ]]; then
        log "WARN" "yq版本过低（当前v$yq_version），建议升级到v4.0+"
    else
        log "DEBUG" "yq版本检查通过：v$yq_version"
    fi

    # 检查yamllint（仅警告，非强制依赖）
    if ! command -v yamllint &> /dev/null; then
        log "WARN" "未安装yamllint，跳过深度语法校验（建议安装：sudo apt install yamllint）"
    fi

    # 检查配置文件目录
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log "ERROR" "配置目录不存在：$CONFIG_DIR"
        exit 1
    fi

    log "INFO" "系统依赖检查通过"
}

# ==============================================
# 提取构建参数（增加文件存在性检查）
# ==============================================
extract_parameters() {
    log "INFO" "提取构建参数..."
    
    # 1. 检查分支文件存在性（核心修复）
    if [[ ! -f "$BRANCHES_FILE" ]]; then
        log "ERROR" "分支列表文件不存在：$BRANCHES_FILE"
        log "ERROR" "请先运行sync-devices.sh生成分支文件"
        exit 1
    fi
    if [[ ! -s "$BRANCHES_FILE" ]]; then
        log "ERROR" "分支列表文件为空：$BRANCHES_FILE"
        log "ERROR" "请重新运行sync-devices.sh更新分支信息"
        exit 1
    fi

    # 2. 提取分支列表（处理空行和特殊字符）
    BRANCHES=$(jq -Rn '[inputs | select(length > 0)]' "$BRANCHES_FILE" | jq -c '.')
    if [[ $(echo "$BRANCHES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "分支列表解析后为空"
        exit 1
    fi
    log "DEBUG" "分支列表解析完成（共$(echo "$BRANCHES" | jq 'length')个分支）"

    # 3. 检查设备JSON文件
    if [[ ! -f "$DEVICE_JSON" ]]; then
        log "ERROR" "设备配置文件不存在：$DEVICE_JSON"
        exit 1
    fi
    if [[ ! -s "$DEVICE_JSON" ]]; then
        log "ERROR" "设备配置文件为空：$DEVICE_JSON"
        exit 1
    fi

    # 4. 提取设备列表（处理中文和特殊字符）
    DEVICES=$(jq -c '.devices[].name | select(. != null)' "$DEVICE_JSON" | sed -E 's/[\\"]/\\\\&/g' | jq -Rn '[inputs]')
    if [[ $(echo "$DEVICES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "设备列表解析后为空"
        exit 1
    fi
    log "DEBUG" "设备列表解析完成（共$(echo "$DEVICES" | jq 'length')个设备）"

    # 5. 提取芯片架构列表（容错处理）
    ARCHITECTURES=$(jq -c '.chips[].name | select(. != null)' "$DEVICE_JSON" | jq -Rn '[inputs]')
    if [[ $(echo "$ARCHITECTURES" | jq 'length') -eq 0 ]]; then
        log "WARN" "未检测到芯片架构信息，使用默认列表"
        ARCHITECTURES='["mt7621", "x86_64", "ipq8065", "rk3399", "mt7981", "bcm53xx"]'
    fi
    log "DEBUG" "芯片架构列表解析完成（共$(echo "$ARCHITECTURES" | jq 'length')个架构）"

    # 6. 检查核心功能配置文件
    local core_features_file="$CONFIG_DIR/core-features.json"
    if [[ ! -f "$core_features_file" ]]; then
        log "ERROR" "核心功能配置文件不存在：$core_features_file"
        exit 1
    fi
    # 提取核心功能（修复原脚本JSON路径错误）
    FEATURES=$(jq -c '.features[] | select(. != null)' "$core_features_file" | jq -Rn '[inputs]')
    if [[ $(echo "$FEATURES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "核心功能列表解析后为空"
        exit 1
    fi
    log "DEBUG" "核心功能列表解析完成（共$(echo "$FEATURES" | jq 'length')项）"

    # 7. 检查主题配置文件
    local theme_file="$CONFIG_DIR/theme-optimizations.json"
    if [[ ! -f "$theme_file" ]]; then
        log "ERROR" "主题配置文件不存在：$theme_file"
        exit 1
    fi
    # 提取主题列表（修复原脚本JSON路径错误）
    THEMES=$(jq -c '.themes[].name | select(. != null)' "$theme_file" | jq -Rn '[inputs]')
    if [[ $(echo "$THEMES" | jq 'length') -eq 0 ]]; then
        log "ERROR" "主题列表解析后为空"
        exit 1
    fi
    log "DEBUG" "主题列表解析完成（共$(echo "$THEMES" | jq 'length')个主题）"
}

# ==============================================
# 生成YAML工作流文件（修复语法和逻辑错误）
# ==============================================
generate_yaml() {
    log "INFO" "开始生成工作流文件..."
    local tmp_yaml=$(mktemp -t workflow-XXXXXX.yml)

    # 生成YAML头部（修复原脚本条件判断空格错误）
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
    name: 编译固件（\${{ github.event.inputs.device }}）
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
          # 修复原脚本的空格语法错误：[! 改为 [ !
          if [ ! -f "device-drivers.json" ]; then
            echo "❌ 未找到设备配置文件 device-drivers.json，请先运行同步工作流"
            exit 1
          fi
          # 检查自定义脚本（如果启用）
          if [ "\${{ github.event.inputs.run_custom_script || 'false' }}" = "true" ] && [ ! -f "scripts/custom-init.sh" ]; then
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
          GO_LATEST_TAG=\$(curl -s "https://api.github.com/repos/golang/go/releases/latest" | jq -r '.tag_name')
          GO_VERSION=\${GO_LATEST_TAG#go}
          GO_TAR="go\${GO_VERSION}.linux-amd64.tar.gz"
          wget -O /tmp/\${GO_TAR} "https://dl.google.com/go/\${GO_TAR}" || wget -O /tmp/\${GO_TAR} "https://gomirrors.org/dl/go/\${GO_TAR}"
          sudo rm -rf /usr/local/go
          sudo tar -C /usr/local -xzf /tmp/\${GO_TAR}
          echo "/usr/local/go/bin" >> \$GITHUB_PATH

          # 安装最新版yq和yamlfmt
          if ! command -v yq &> /dev/null; then
            sudo snap install yq
          fi
          go install github.com/google/yamlfmt/cmd/yamlfmt@latest
          echo "\$HOME/go/bin" >> \$GITHUB_PATH

          # 升级Python工具链
          pip3 install --upgrade pip requests

      - name: 硬件资源详细检测
        run: |
          echo "🖥️ 编译环境信息："
          echo "  - CPU型号：\$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed -e 's/^ *//')"
          echo "  - 核心数：\$(grep -c ^processor /proc/cpuinfo)"
          echo "  - 总内存：\$(free -h | awk '/^Mem:/ {print \$2}')"  # 修复原脚本$2未转义的错误
          echo "  - 可用内存：\$(free -h | awk '/^Mem:/ {print \$7}')"

      - name: 初始化编译环境
        run: |
          # 检查openwrt目录是否存在
          if [ ! -d "openwrt" ]; then
            echo "❌ 未找到openwrt源码目录，请检查仓库结构"
            exit 1
          fi
          cd openwrt
          ./scripts/feeds update -a
          ./scripts/feeds install -a

      - name: 配置编译选项
        run: |
          cd openwrt
          make defconfig

          # 应用架构配置（容错处理）
          ARCH=\${{ github.event.inputs.arch }}
          echo "CONFIG_TARGET_\${ARCH}=y" >> .config || echo "⚠️ 架构配置可能无效：\$ARCH"

          # 应用功能配置
          case "\${{ github.event.inputs.features }}" in
            *ipv6*) echo "CONFIG_IPV6=y" >> .config ;;
            *vpn*) echo "CONFIG_PACKAGE_luci-app-openvpn=y" >> .config ;;
            *qos*) echo "CONFIG_PACKAGE_luci-app-qos=y" >> .config ;;
            *accel*) echo "CONFIG_PACKAGE_luci-app-accelerate=y" >> .config ;;
          esac

          # 应用主题配置（容错处理）
          THEME=\${{ github.event.inputs.theme }}
          echo "CONFIG_PACKAGE_luci-theme-\${THEME}=y" >> .config || echo "⚠️ 主题配置可能无效：\$THEME"

          # 应用优化级别
          OPT_LEVEL=\${{ github.event.inputs.optimize }}
          echo "CONFIG_CFLAGS=-O\${OPT_LEVEL}" >> .config
          echo "CONFIG_CXXFLAGS=-O\${OPT_LEVEL}" >> .config

          make defconfig

      - name: 开始编译（带超时保护）
        run: |
          cd openwrt
          make download -j8
          # 超时保护：最长12小时（43200秒）
          timeout 43200 make -j\$(nproc) || make -j1 V=s

      - name: 收集编译产物
        id: collect
        run: |
          # 查找固件文件（支持多种格式）
          cd openwrt/bin/targets/*/*
          FIRMWARE_FILE=\$(find . -type f -name "*.bin" -o -name "*.img" -o -name "*.tar.gz" | head -n1)
          if [ -z "\$FIRMWARE_FILE" ]; then
            echo "❌ 未找到编译产物"
            exit 1
          fi
          echo "固件路径: \$FIRMWARE_FILE"
          echo "firmware=\$(basename \$FIRMWARE_FILE)" >> \$GITHUB_OUTPUT
          mv "\$FIRMWARE_FILE" ../../../..

      - name: 上传固件
        uses: actions/upload-artifact@v4
        with:
          name: openwrt-firmware-\${{ github.event.inputs.device }}-\${{ github.sha }}
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
        log "WARN" "yamlfmt格式化失败，尝试手动修复缩进"
        sed -i 's/^    - /  - /g' "$tmp_yaml"
        sed -i 's/^        - /    - /g' "$tmp_yaml"
    fi

    # 二次验证YAML语法
    if ! yq eval '.' "$tmp_yaml" &> /dev/null; then
        log "ERROR" "生成的YAML语法错误"
        cat "$tmp_yaml"
        exit 1
    fi

    # 确保输出目录存在
    mkdir -p "$(dirname "$OUTPUT_WORKFLOW")"
    # 移动到目标位置
    mv "$tmp_yaml" "$OUTPUT_WORKFLOW"
    log "INFO" "工作流文件生成完成: $OUTPUT_WORKFLOW"
}

# ==============================================
# 验证工作流文件（增强容错性）
# ==============================================
validate_workflow() {
    log "INFO" "验证工作流文件有效性..."
    
    # 检查文件存在性和非空
    if [[ ! -f "$OUTPUT_WORKFLOW" ]]; then
        log "ERROR" "工作流文件未生成：$OUTPUT_WORKFLOW"
        exit 1
    fi
    if [[ ! -s "$OUTPUT_WORKFLOW" ]]; then
        log "ERROR" "工作流文件为空：$OUTPUT_WORKFLOW"
        exit 1
    fi

    # 检查关键配置项（使用yq安全解析）
    local required_keys=("name" "on" "jobs.build-firmware.runs-on")
    for key in "${required_keys[@]}"; do
        if ! yq eval ".$key" "$OUTPUT_WORKFLOW" &> /dev/null; then
            log "ERROR" "工作流缺少关键配置: $key"
            exit 1
        fi
    done

    # 检查选项列表非空
    local options=("branch" "device" "arch" "features" "theme")
    for opt in "${options[@]}"; do
        if [[ $(yq eval ".on.workflow_dispatch.inputs.${opt}.options | length" "$OUTPUT_WORKFLOW") -eq 0 ]]; then
            log "WARN" "工作流选项${opt}的可选值为空"
        fi
    done

    # 使用yamllint进行深度校验（仅当工具存在时）
    if command -v yamllint &> /dev/null; then
        if ! yamllint "$OUTPUT_WORKFLOW"; then
            log "ERROR" "yamllint校验失败，请检查格式"
            exit 1
        fi
    else
        log "INFO" "跳过yamllint校验（工具未安装）"
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
