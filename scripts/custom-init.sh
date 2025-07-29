#!/bin/bash
# 编译前自定义配置

# 1. 修改默认管理IP（192.168.1.1 → 192.168.5.1）
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 开放自定义端口（8080）
echo 'iptables -A INPUT -p tcp --dport 8080 -j ACCEPT' >> package/base-files/files/etc/rc.local

# 3. 修改默认主机名
sed -i 's/OpenWrt/MyRouter/g' package/base-files/files/bin/config_generate

# 4. 禁用首次登录强制改密码
sed -i '/exit 0/d' package/base-files/files/etc/rc.local
echo 'uci set luci.main.mediaurlbase=/luci-static/bootstrap' >> package/base-files/files/etc/rc.local
echo 'uci commit luci' >> package/base-files/files/etc/rc.local
echo 'exit 0' >> package/base-files/files/etc/rc.local

# 5. 调整时区为上海
sed -i "s/'UTC'/'CST-8'\n        set system.@system[-1].zonename='Asia\/Shanghai'/g" package/base-files/files/bin/config_generate
