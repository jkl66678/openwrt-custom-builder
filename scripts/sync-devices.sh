#!/bin/bash
# 设备同步脚本（修复格式和语法错误）

# 基础设置（拆分选项，避免旧版bash不兼容）
set -e  # 出错立即退出
set -u  # 禁止使用未定义变量
set -o pipefail  # 管道命令出错立即退出

# 平台-芯片映射表
declare -A PLATFORM_CHIPS=(
    ["mediatek/filogic"]="mt7981 mt7986"
    ["ramips/mt7621"]="mt7621"
    ["x86/64"]="x86_64"
)

# 输出文件（确保文件名正确）
OUTPUT_JSON="device-drivers.json"

# 初始化JSON
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
    echo "❌ 无法创建 $OUTPUT_JSON（检查权限）"
    exit 1
}

# 检查依赖
if ! command -v jq &> /dev/null; then
    echo "❌ 缺少 jq 工具，请安装：sudo apt install jq"
    exit 1
fi

# 克隆源码（简化版，仅拉取必要文件）
echo "📥 克隆源码..."
TMP_SRC=$(mktemp -d)
if ! git clone --depth 1 https://git.openwrt.org/openwrt/openwrt.git "$TMP_SRC"; then
    echo "❌ 源码克隆失败（网络问题）"
    exit 1
fi

# 提取设备信息（简化逻辑，减少出错点）
echo "🔍 提取设备信息..."
for platform in "${!PLATFORM_CHIPS[@]}"; do
    plat_path="$TMP_SRC/target/linux/$platform"
    [ -d "$plat_path" ] || continue

    # 提取设备
    find "$plat_path" -name "*.mk" | while read -r file; do
        dev_name=$(grep "DEVICE_NAME" "$file" | cut -d'=' -f2 | tr -d '"' | sed 's/ //g')
        [ -z "$dev_name" ] && continue

        # 写入设备到JSON
        jq --arg name "$dev_name" \
           --arg chip "${PLATFORM_CHIPS[$platform]}" \
           '.devices += [{"name": $name, "chip": $chip}]' \
           "$OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "$OUTPUT_JSON"
    done

    # 提取芯片
    for chip in ${PLATFORM_CHIPS[$platform]}; do
        jq --arg name "$chip" \
           '.chips += [{"name": $name}]' \
           "$OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "$OUTPUT_JSON"
    done
done

# 清理
rm -rf "$TMP_SRC"
echo "✅ 同步完成：$OUTPUT_JSON"
