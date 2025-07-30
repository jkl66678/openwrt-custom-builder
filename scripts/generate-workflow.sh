#!/bin/bash
set -uo pipefail

# ==============================================
# 配置与初始化
# ==============================================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/sync-logs"
DEVICE_JSON="$WORK_DIR/device-drivers.json"
CORE_FEATURES_JSON="$WORK_DIR/configs/core-features.json"
THEME_OPTS_JSON="$WORK_DIR/configs/theme-optimizations.json"
SOURCE_BRANCHES_TMP="$LOG_DIR/source_branches.tmp"
BUILD_YML=".github/workflows/build.yml"

# 临时文件存储生成的工作流内容
TMP_BUILD_YML=$(mktemp)

# 日志函数
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1"
}

# 错误处理函数
error_exit() {
    log "❌ $1"
    rm -f "$TMP_BUILD_YML"
    exit 1
}

# ==============================================
# 依赖检查
# ==============================================
check_dependencies() {
    log "🔍 检查依赖工具..."
    local required_tools=("jq" "sed" "grep" "awk" "yq")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error_exit "缺失必要工具：$tool（请安装后重试）"
        fi
    done
    
    # 检查yq版本（确保支持YAML验证）
    if ! yq --version &> /dev/null; then
        error_exit "yq工具版本不兼容，请安装yq 4.0+"
    fi
    
    log "✅ 依赖工具检查通过"
}

# ==============================================
# 提取选项并格式化（核心功能）
# ==============================================
extract_options() {
    # 1. 设备列表（从device-drivers.json提取）
    log "🔧 提取设备列表..."
    if [ -f "$DEVICE_JSON" ] && [ $(jq '.devices | length' "$DEVICE_JSON") -gt 0 ]; then
        DEVICE_LIST=$(jq -r '.devices[].name' "$DEVICE_JSON" | sort | uniq | 
                     sed -e 's/[\\"]/\\&/g' -e 's/^/          - /')  # 转义特殊字符
    else
        # 兜底默认设备
        DEVICE_LIST=$(cat <<EOF
          - cudy-tr3000
          - redmi-ac2100
          - x86-64-generic
          - phicomm-k2p
EOF
        )
    fi

    # 2. 芯片列表
    log "🔧 提取芯片列表..."
    if [ -f "$DEVICE_JSON" ] && [ $(jq '.chips | length' "$DEVICE_JSON") -gt 0 ]; then
        CHIP_LIST=$(jq -r '.chips[].name' "$DEVICE_JSON" | sort | uniq | 
                   sed -e 's/[\\"]/\\&/g' -e 's/^/          - /')
    else
        # 兜底默认芯片
        CHIP_LIST=$(cat <<EOF
          - mt7981
          - mt7621
          - x86_64
          - ipq8065
          - bcm53573
EOF
        )
    fi

    # 3. 源码分支（从同步临时文件提取）
    log "🔧 提取源码分支..."
    if [ -f "$SOURCE_BRANCHES_TMP" ] && [ -s "$SOURCE_BRANCHES_TMP" ]; then
        SOURCE_BRANCHES=$(cat "$SOURCE_BRANCHES_TMP" | sort -r | 
                         sed -e 's/[\\"]/\\&/g' -e 's/^/          - /')
    else
        # 兜底默认分支
        SOURCE_BRANCHES=$(cat <<EOF
          - openwrt-23.05
          - openwrt-master
          - immortalwrt-23.05
          - immortalwrt-master
EOF
        )
    fi

    # 4. 主题+优化组合（从主题配置生成）
    log "🔧 生成主题+优化组合..."
    if [ -f "$THEME_OPTS_JSON" ] && [ $(jq '.themes | length' "$THEME_OPTS_JSON") -gt 0 ]; then
        THEME_OPTS=$(jq -c '.themes[]' "$THEME_OPTS_JSON" | while read -r theme; do
            local name=$(echo "$theme" | jq -r '.name')
            local arches=$(echo "$theme" | jq -r '.architectures[]')
            local opts=$(echo "$theme" | jq -r '.opts[]')
            
            for arch in $arches; do
                for opt in $opts; do
                    echo "${name}-${opt}-${arch}"
                done
            done
        done | sort | uniq | sed -e 's/[\\"]/\\&/g' -e 's/^/          - /')
    else
        # 兜底默认主题组合
        THEME_OPTS=$(cat <<EOF
          - argon-O2-generic
          - argon-O3-armv8
          - argon-O3-x86
          - bootstrap-O2-generic
          - material-Os-generic
EOF
        )
    fi

    # 5. 核心功能选项
    log "🔧 提取核心功能选项..."
    if [ -f "$CORE_FEATURES_JSON" ] && [ $(jq '.features | length' "$CORE_FEATURES_JSON") -gt 0 ]; then
        CORE_FEATURES=$(jq -r '.features[]' "$CORE_FEATURES_JSON" | sort | uniq | 
                       sed -e 's/[\\"]/\\&/g' -e 's/^/          - /')
    else
        # 兜底默认功能
        CORE_FEATURES=$(cat <<EOF
          - ipv6+accel
          - ipv6-only
          - accel-only
          - none
EOF
        )
    fi
}

# ==============================================
# 生成工作流文件
# ==============================================
generate_workflow() {
    log "📝 开始生成工作流文件..."
    
    # 生成工作流头部（包含动态选项）
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
        options:
$SOURCE_BRANCHES

      theme_and_optimization:
        type: choice
        description: 主题+编译优化组合
        required: true
        options:
$THEME_OPTS

      core_features:
        type: choice
        description: 核心功能
        required: true
        options:
$CORE_FEATURES

      packages:
        type: string
        description: 软件包（格式：包1,包2，如openclash,samba）
        required: false
        default: "openclash,samba,ddns-scripts,luci-app-upnp"

      rootfs_size:
        type: number
        description: 根分区大小(MB，32-2048)
        required: true
        default: 192

      firmware_suffix:
        type: string
        description: 固件后缀（如版本号或自定义标识）
        required: false
        default: "custom"

      run_custom_script:
        type: boolean
        description: 执行自定义初始化脚本（scripts/custom-init.sh）
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

    # 提取原有工作流中的steps部分（保留用户自定义步骤）
    log "🔄 合并原有编译步骤..."
    if [ -f "$BUILD_YML" ]; then
        # 提取steps之后的内容（兼容任意缩进）
        if ! awk '/^[[:space:]]*steps:/ {flag=1; next} flag' "$BUILD_YML" >> "$TMP_BUILD_YML"; then
            log "⚠️ 提取原有步骤失败，使用默认编译步骤"
            # 添加默认编译步骤
            cat >> "$TMP_BUILD_YML" << EOF
      - name: 拉取代码
        uses: actions/checkout@v4

      - name: 安装编译依赖
        run: |
          sudo apt update
          sudo apt install -y build-essential libncurses5-dev libncursesw5-dev \
            zlib1g-dev gawk git gettext libssl-dev xsltproc wget unzip python3 jq

      - name: 编译固件
        run: echo "编译流程待执行"
EOF
        fi
    else
        # 全新工作流，添加基础步骤
        log "⚠️ 未找到原有工作流，创建新工作流"
        cat >> "$TMP_BUILD_YML" << EOF
      - name: 拉取代码
        uses: actions/checkout@v4

      - name: 初始化编译环境
        run: |
          echo "初始化编译环境..."
          # 基础编译步骤
EOF
    fi

    # 验证生成的YAML格式
    log "🔍 验证工作流格式..."
    if ! yq eval '.' "$TMP_BUILD_YML" &>/dev/null; then
        error_exit "生成的工作流文件格式错误（YAML语法无效）"
    fi

    # 备份旧工作流并替换
    if [ -f "$BUILD_YML" ]; then
        cp "$BUILD_YML" "$BUILD_YML.bak"
        log "ℹ️ 已备份旧工作流到 $BUILD_YML.bak"
    fi

    mv "$TMP_BUILD_YML" "$BUILD_YML" || error_exit "无法替换工作流文件"
}

# ==============================================
# 输出统计信息
# ==============================================
print_summary() {
    log "========================================="
    log "✅ 工作流生成完成：$BUILD_YML"
    log "📊 设备选项数：$(echo "$DEVICE_LIST" | grep -c '^          - ')"
    log "📊 芯片选项数：$(echo "$CHIP_LIST" | grep -c '^          - ')"
    log "📊 源码分支数：$(echo "$SOURCE_BRANCHES" | grep -c '^          - ')"
    log "📊 主题优化组合数：$(echo "$THEME_OPTS" | grep -c '^          - ')"
    log "📊 核心功能选项数：$(echo "$CORE_FEATURES" | grep -c '^          - ')"
    log "========================================="
}

# ==============================================
# 主流程
# ==============================================
log "========================================="
log "📌 OpenWrt工作流生成工具启动"
log "========================================="

check_dependencies
extract_options
generate_workflow
print_summary

exit 0
