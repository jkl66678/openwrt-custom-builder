#!/bin/bash
# 自定义初始化脚本：修改默认设置，在编译前执行

# 1. 修改默认管理IP（从192.168.1.1改为192.168.5.1）
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 添加自定义防火墙规则（开放8080端口）
echo 'iptables -A INPUT -p tcp --dport 8080 -j ACCEPT' >> package/base-files/files/etc/rc.local

# 3. 修改默认主机名（如改为"MyRouter"）
sed -i 's/OpenWrt/MyRouter/g' package/base-files/files/bin/config_generate

# 4. 禁用首次登录强制修改密码（可选）
sed -i 's/exit 0//g' package/base-files/files/etc/rc.local
echo 'uci set luci.main.mediaurlbase=/luci-static/bootstrap' >> package/base-files/files/etc/rc.local
echo 'uci commit luci' >> package/base-files/files/etc/rc.local
echo 'exit 0' >> package/base-files/files/etc/rc.local
    
