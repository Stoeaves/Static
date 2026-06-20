#!/bin/bash

# ZBProxy 卸载脚本
# 适用于 OpenRC 系统（如 Alpine Linux、Gentoo 等）

set -e  # 遇到错误立即退出

echo "开始卸载 ZBProxy..."

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

# 停止服务
echo "正在停止 ZBProxy 服务..."
if rc-service zbproxy status &>/dev/null; then
    rc-service zbproxy stop
    echo "服务已停止"
else
    echo "服务未运行，跳过停止步骤"
fi

# 移除开机自启
echo "正在移除开机自启..."
if rc-update show | grep -q zbproxy; then
    rc-update del zbproxy default
    echo "已从开机自启中移除"
else
    echo "未找到开机自启配置，跳过"
fi

# 删除服务脚本
echo "正在删除服务脚本..."
if [ -f "/etc/init.d/zbproxy" ]; then
    rm -f /etc/init.d/zbproxy
    echo "服务脚本已删除"
else
    echo "服务脚本不存在，跳过"
fi

# 删除二进制文件
echo "正在删除二进制文件..."
if [ -f "/usr/local/bin/zbproxy" ]; then
    rm -f /usr/local/bin/zbproxy
    echo "二进制文件已删除"
else
    echo "二进制文件不存在，跳过"
fi

# 删除 PID 文件（如果存在）
if [ -f "/run/zbproxy.pid" ]; then
    rm -f /run/zbproxy.pid
    echo "PID 文件已删除"
fi

# 可选：删除配置文件（如果存在）
# ZBProxy 默认配置文件位置可能需要根据实际情况调整
if [ -f "/etc/zbproxy/config.json" ]; then
    read -p "是否删除配置文件 /etc/zbproxy/config.json? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f /etc/zbproxy/config.json
        echo "配置文件已删除"
        
        # 如果目录为空，也删除目录
        if [ -d "/etc/zbproxy" ] && [ -z "$(ls -A /etc/zbproxy)" ]; then
            rmdir /etc/zbproxy
            echo "配置目录已删除"
        fi
    else
        echo "保留配置文件"
    fi
fi

echo "ZBProxy 卸载完成！"

# 显示残留检查
echo ""
echo "===== 残留检查 ====="
if [ -f "/usr/local/bin/zbproxy" ] || [ -f "/etc/init.d/zbproxy" ]; then
    echo "⚠️  警告：仍有残留文件，请手动检查以下位置："
    [ -f "/usr/local/bin/zbproxy" ] && echo "  - /usr/local/bin/zbproxy"
    [ -f "/etc/init.d/zbproxy" ] && echo "  - /etc/init.d/zbproxy"
    [ -f "/run/zbproxy.pid" ] && echo "  - /run/zbproxy.pid"
else
    echo "✓ 所有文件已清理干净"
fi