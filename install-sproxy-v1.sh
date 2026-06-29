#!/bin/bash

# ZBProxy 安装脚本
# 适用于 OpenRC 系统（如 Alpine Linux、Gentoo 等）

set -e  # 遇到错误立即退出

echo "开始安装 ZBProxy..."

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

# 下载 ZBProxy
echo "正在下载 ZBProxy..."
wget -O /usr/local/bin/zbproxy https://github.com/Stoeaves/ZBProxy/releases/latest/download/ZBProxy-linux-amd64-v1

# 添加执行权限
echo "正在添加执行权限..."
chmod +x /usr/local/bin/zbproxy

# 创建 OpenRC 服务脚本
echo "正在创建 OpenRC 服务脚本..."
cat > /etc/init.d/zbproxy << 'EOF'
#!/sbin/openrc-run

name="zbproxy"
command="/usr/local/bin/zbproxy"
command_args=""
command_user="root"
command_background="yes"
pidfile="/run/${name}.pid"

depend() {
    need net
}
EOF

# 为服务脚本添加执行权限
echo "正在为服务脚本添加执行权限..."
chmod +x /etc/init.d/zbproxy

# 添加开机自启
echo "正在添加开机自启..."
rc-update add zbproxy default

# 启动服务
echo "正在启动 ZBProxy 服务..."
rc-service zbproxy start

# 检查服务状态
echo "检查服务状态..."
rc-service zbproxy status

echo "ZBProxy 安装完成！"
