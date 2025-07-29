#!/bin/bash set -euo pipefail
关键：确保文件名正确（是 device-drivers.json，而非 device-devices.json）
OUTPUT_JSON="device-drivers.json"
平台 - 芯片映射表（保持不变）
declare -A PLATFORM_CHIPS=(
["mediatek/filogic"]="mt7981 mt7986"
["ramips/mt7621"]="mt7621"
["x86/64"]="x86_64"
["ipq806x/generic"]="ipq8065"
)
初始化 JSON（强制覆盖旧文件，确保格式正确）
echo '{"devices": [], "chips": []}' > "$OUTPUT_JSON" || {
echo "❌ 无法创建 $OUTPUT_JSON！可能原因："
echo "1. 当前目录无写入权限"
echo "2. 磁盘空间不足"
exit 1
}
检查 jq 工具是否可用（JSON 处理依赖）
if ! command -v jq &> /dev/null; then
echo "❌ 未安装 jq 工具，无法生成 JSON！请先执行：sudo apt install jq"
exit 1
fi
克隆源码（临时目录）
TMP_SRC=
(mktemp−d)gitclone−−depth1https://git.openwrt.org/openwrt/openwrt.git"
TMP_SRC" >/dev/null 2>&1 || {
echo "❌ 源码克隆失败"
exit 1
}
提取设备和芯片信息
for platform in "
!PLATFORM 
C
​
 HIPS[@]";doplat 
p
​
 ath="
TMP_SRC/target/linux/
platform"[−d"
plat_path" ] || continue
处理设备
find "$plat_path" -name "*.mk" | while read -r mkfile; do
提取设备名称（处理特殊字符）
dev_name=
(grep"DEVICE 
N
​
 AME""
mkfile" | cut -d'=' -f2 | tr -d '"' | sed 's/[/&]/\&/g')
[ -z "$dev_name" ] && continue
提取驱动（处理空格和特殊字符）
drivers=
(grep"DEFAULT 
P
​
 ACKAGES""
mkfile" | cut -d'=' -f2 | tr -d '"' | grep -oE "kmod-[a-z0-9-]+" | sort -u | tr '\n' ' ' | sed 's/ $//')
关联芯片
chip=
(echo"
{PLATFORM_CHIPS[$platform]}" | awk '{print $1}')
写入 JSON（使用 jq 安全处理特殊字符）
jq --arg name "
dev 
n
​
 ame" −−argchip"
chip"
--arg target "
platform" −−argdrivers"
drivers"
'.devices += [{"name": $name, "chip": $chip, "kernel_target": 
target,"drivers":(
drivers | split(" ") | map(select(. != "")))}]'
"OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "OUTPUT_JSON" || {
echo "⚠️ 写入设备 $dev_name 到 JSON 失败（可能含特殊字符）"
}
done
处理芯片
for chip in {PLATFORM_CHIPS[platform]}; do
jq --arg name "
chip" −−argplatform"
platform"
'.chips += [{"name": $name, "platform": platform}]' \ "OUTPUT_JSON" > "tmp.json" && mv "tmp.json" "$OUTPUT_JSON" || {
echo "⚠️ 写入芯片 $chip 到 JSON 失败"
}
done
done
验证 JSON 格式是否有效
if ! jq . "$OUTPUT_JSON" >/dev/null 2>&1; then
echo "❌ $OUTPUT_JSON 格式无效！可能是特殊字符导致 "
exit 1
fi
清理临时文件
rm -rf "$TMP_SRC"
echo "✅ 成功生成 $OUTPUT_JSON"
