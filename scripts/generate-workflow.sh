#!/bin/bash
set -uo pipefail

# 确保中文显示正常
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# ==============================================
# 基础配置
# ==============================================
WORK_DIR=$(pwd)
OUTPUT_WORKFLOW="$WORK_DIR/.github/workflows/build.yml"
THEME_OPTS_JSON="$WORK_DIR/configs/theme-optimizations.json"
CORE_FEATURES_JSON="$WORK_DIR/configs/core-features.json"
DEVICES_JSON="$WORK_DIR/device-drivers.json"
BRANCHES_TMP="$WORK_DIR/sync-logs/source_branches.tmp"
LOG_FILE="$WORK_DIR/sync-logs/workflow-generate.log"

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$OUTPUT_WORKFLOW")"
> "$LOG_FILE"  # 清空日志

# 日志函数
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# ==============================================
# 1. 依赖检查
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    REQUIRED_TOOLS=("jq" "yq" "sed" "grep" "awk")  # yq用于验证YAML格式
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "❌ 缺失必要工具：$tool"
            exit 1
        fi
    done
    
    # 验证输入JSON文件存在且有效
    local json_files=("$THEME_OPTS_JSON" "$CORE_FEATURES_JSON" "$DEVICES_JSON" "$BRANCHES_TMP")
    for file in "${json_files[@]}"; do
        if [ ! -f "$file" ] || [ ! -s "$file" ]; then
            log "❌ 输入文件不存在或为空：$file"
            exit 1
        fi
        # 验证JSON格式有效性
        if ! jq . "$file" &> /dev/null; then
            log "❌ JSON格式错误：$file（请检查语法）"
            exit 1
        fi
    done
    
    log "✅ 依赖工具检查通过"
}

# ==============================================
# 2. 提取配置数据（修复jq解析和变量为空问题）
# ==============================================
extract_configs() {
    # 提取设备列表（限制最多50个，避免工作流过大）
    log "🔧 提取设备列表..."
    DEVICES=$(jq -r '.devices[0:50] | .[].name' "$DEVICES_JSON" | sort | uniq | tr '\n' ' ')
    log "ℹ️ 设备列表：$DEVICES"

    # 提取芯片列表
    log "🔧 提取芯片列表..."
    CHIPS=$(jq -r '.chips[].name' "$DEVICES_JSON" | sort | uniq | grep -v '^$' | tr '\n' ' ')
    log "ℹ️ 芯片列表：$CHIPS"

    # 提取源码分支
    log "🔧 提取源码分支..."
    BRANCHES=$(cat "$BRANCHES_TMP" | sort -r | tr '\n' ' ')
    log "ℹ️ 源码分支：$BRANCHES"

    # 生成主题+优化组合（修复jq解析错误）
    log "🔧 生成主题+优化组合..."
    # 验证theme-optimizations.json结构并提取有效数据
    local valid_themes=$(jq -r '
        .themes[] | 
        select(.name != null and .architectures != null and .opts != null) |
        {name: .name, arch: .architectures[], opt: .opts[]} |
        "\(.name)-\(.arch)-\(.opt)"
    ' "$THEME_OPTS_JSON" 2>> "$LOG_FILE")  # 捕获jq错误到日志
    
    # 处理可能的空值，设置默认值
    THEME_COMBOS=$(echo "$valid_themes" | grep -v '^$' | sort | uniq | tr '\n' ' ')
    theme_count=$(echo "$THEME_COMBOS" | wc -w | xargs)
    theme_count=${theme_count:-0}  # 关键修复：设置默认值避免为空
    log "ℹ️ 主题+优化组合（共$theme_count个）：$THEME_COMBOS"

    # 提取核心功能选项
    log "🔧 提取核心功能选项..."
    CORE_FEATURES=$(jq -r '.features[]' "$CORE_FEATURES_JSON" | sort | uniq | tr '\n' ' ')
    log "ℹ️ 核心功能选项：$CORE_FEATURES"
}

# ==============================================
# 3. 生成工作流内容
# ==============================================
generate_workflow() {
    log "📝 开始生成工作流文件..."
    local tmp_workflow=$(mktemp)

    # 写入工作流头部
    cat <<EOF > "$tmp_workflow"
name: OpenWrt 自动编译

on:
  workflow_dispatch:
    inputs:
      source_branch:
        description: '源码分支'
        required: true
        default: 'openwrt-master'
        type: choice
        options:
          - $(echo "$BRANCHES" | tr ' ' '\n' | head -n 20 | tr '\n' ' ' | sed 's/ $//')  # 限制选项数量

      target_device:
        description: '目标设备（留空则按芯片编译）'
        required: false
        default: ''
        type: choice
        options:
          - ''
          - $(echo "$DEVICES" | tr ' ' '\n' | head -n 20 | tr '\n' ' ' | sed 's/ $//')

      target_chip:
        description: '目标芯片（设备为空时生效）'
        required: true
        default: 'mt7621'
        type: choice
        options:
          - $(echo "$CHIPS" | tr ' ' '\n' | head -n 20 | tr '\n' ' ' | sed 's/ $//')

      core_features:
        description: '核心功能组合'
        required: true
        default: 'ipv6+qos'
        type: choice
        options:
          - $(echo "$CORE_FEATURES" | tr ' ' '\n' | head -n 10 | tr '\n' ' ' | sed 's/ $//')

      theme_optimization:
        description: '主题+编译优化'
        required: true
        default: 'argon-generic-O3'
        type: choice
        options:
          - $(echo "$THEME_COMBOS" | tr ' ' '\n' | head -n 20 | tr '\n' ' ' | sed 's/ $//')

jobs:
  build:
    name: 编译 OpenWrt 固件
    runs-on: ubuntu-22.04
    steps:
      - name: 检查源码
        uses: actions/checkout@v4

      - name: 初始化编译环境
        run: |
          sudo apt update -y
          sudo apt install -y build-essential clang flex bison g++ gawk gcc-multilib gettext git libncurses5-dev libssl-dev python3-distutils rsync unzip zlib1g-dev file wget

      - name: 同步源码与配置
        run: |
          ./scripts/sync-devices.sh

      - name: 加载自定义配置
        run: |
          # 根据选择生成.config
          ./scripts/generate-config.sh \${{ github.event.inputs.source_branch }} \${{ github.event.inputs.target_device }} \${{ github.event.inputs.target_chip }}

      - name: 开始编译
        run: |
          make defconfig
          make -j\$(nproc) || make -j1 V=s  # 失败时单线程输出详细日志

      - name: 整理固件
        run: |
          mkdir -p ./output/firmware
          find ./bin/targets/ -name "*.bin" -exec cp {} ./output/firmware/ \;
          find ./bin/targets/ -name "*.img" -exec cp {} ./output/firmware/ \;

      - name: 上传固件
        uses: actions/upload-artifact@v4
        with:
          name: openwrt-firmware-\${{ github.sha }}
          path: ./output/firmware/
EOF

    # 合并原有编译步骤（如果存在模板）
    log "🔄 合并原有编译步骤..."
    if [ -f ".github/workflows/build.template.yml" ]; then
        # 提取模板中的自定义步骤并追加
        yq eval '.jobs.build.steps[]' ".github/workflows/build.template.yml" 2>> "$LOG_FILE" | 
            sed '/^null$/d' >> "$tmp_workflow"
    fi

    # 验证YAML格式
    log "🔍 验证工作流格式..."
    if ! yq eval '.' "$tmp_workflow" &> /dev/null; then
        log "❌ 生成的工作流文件格式错误（YAML语法无效）"
        exit 1
    fi

    # 输出最终工作流
    mv "$tmp_workflow" "$OUTPUT_WORKFLOW"
    log "✅ 工作流文件生成成功：$OUTPUT_WORKFLOW"
}

# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt工作流生成工具启动"
log "========================================="

check_dependencies
extract_configs

# 关键修复：检查主题组合数量是否有效（避免后续逻辑错误）
if [ "$theme_count" -gt 0 ]; then
    generate_workflow
else
    log "⚠️ 未检测到有效主题+优化组合，使用默认工作流模板"
    #  fallback到默认模板
    if [ -f ".github/workflows/build.template.yml" ]; then
        cp ".github/workflows/build.template.yml" "$OUTPUT_WORKFLOW"
        log "✅ 使用默认模板生成工作流"
    else
        log "❌ 无有效主题组合且无默认模板，生成失败"
        exit 1
    fi
fi

log "========================================="
log "✅ 工作流生成完成"
log "========================================="
