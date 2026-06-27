#!/bin/sh

CONF="/etc/sysctl.d/99-network-opt.conf"

echo "正在生成优化配置..."

cat > "$CONF" << 'EOF'
# ===== BBR =====
net.ipv4.tcp_congestion_control=bbr

# ===== TCP Fast Open =====
net.ipv4.tcp_fastopen=3

# ===== MTU 自动探测 =====
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024

# ===== Socket Buffer =====
net.core.rmem_max=67108864
net.core.wmem_max=67108864

net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# ===== TCP 状态优化 =====
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_syn_backlog=8192

# ===== KeepAlive =====
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# ===== 重传优化 =====
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1

# ===== ECN =====
net.ipv4.tcp_ecn=0
EOF

echo "应用配置..."
sysctl -e -p "$CONF"

echo ""
echo "========== 当前状态 =========="

echo -n "拥塞控制算法: "
sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知"

echo -n "TCP Fast Open: "
sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知"

echo -n "MTU Probing: "
sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "未知"

if sysctl -n net.core.default_qdisc >/dev/null 2>&1; then
    echo -n "队列算法: "
    sysctl -n net.core.default_qdisc
else
    echo "队列算法: 当前内核未开放（NAT VPS 很常见）"
fi

echo "================================"
echo "优化完成。"
