#!/bin/sh
#=============================================================================
# Xray 节点管理脚本 (Alpine Linux) - 最终修复版
# 协议: Vless + WS + TLS (Cloudflare CDN)
# 支持: NAT/VPS/独立服务器 + Cloudflare Tunnel
#=============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 配置路径
XRAY_DIR="/etc/xray"
XRAY_CONFIG_DIR="${XRAY_DIR}/config"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/init.d/xray"
NODES_FILE="${XRAY_DIR}/nodes.txt"
LOG_DIR="/var/log/xray"
TUNNEL_DIR="${XRAY_DIR}/tunnel"

# Cloudflare Tunnel 配置
CF_TUNNEL_BIN="/usr/local/bin/cloudflared"
CF_TUNNEL_CONFIG="/etc/cloudflared"
CF_TUNNEL_SERVICE="/etc/init.d/cloudflared"
CF_TUNNEL_LOG="/var/log/cloudflared.log"
CF_HOME="/root/.cloudflared"

# Cloudflare 支持的 HTTPS 端口
CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"

#=============================================================================
# 初始化所有目录
#=============================================================================

init_dirs() {
    mkdir -p ${XRAY_DIR} ${XRAY_CONFIG_DIR} ${LOG_DIR} ${TUNNEL_DIR}
    mkdir -p ${CF_TUNNEL_CONFIG} ${CF_HOME}
    mkdir -p /var/run/xray /var/run/cloudflared
    touch ${NODES_FILE}
    touch ${TUNNEL_DIR}/current_tunnel.txt
    touch ${TUNNEL_DIR}/node_tunnel_map.txt
}

#=============================================================================
# 基础功能
#=============================================================================

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}安装依赖...${NC}"
    apk update
    apk add --no-cache curl wget unzip jq openssl
}

install_xray() {
    if [ ! -f "${XRAY_BIN}" ]; then
        echo -e "${YELLOW}安装 Xray-core...${NC}"
        local ARCH=$(uname -m)
        case $ARCH in
            x86_64)  XRAY_ARCH="64" ;;
            aarch64) XRAY_ARCH="arm64-v8a" ;;
            armv7l|armhf) XRAY_ARCH="arm32-v7a" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
        esac
        
        local LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
        [ -z "$LATEST_VERSION" ] && LATEST_VERSION="v1.8.23"
        
        local DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
        
        mkdir -p /tmp/xray && cd /tmp/xray
        wget -q ${DOWNLOAD_URL} -O xray.zip || wget -q "https://ghproxy.com/${DOWNLOAD_URL}" -O xray.zip
        unzip -q xray.zip
        mv xray ${XRAY_BIN}
        chmod +x ${XRAY_BIN}
        rm -rf /tmp/xray
        echo -e "${GREEN}Xray 安装完成${NC}"
    fi
}

create_xray_service() {
    cat > ${XRAY_SERVICE} << 'EOF'
#!/sbin/openrc-run

name="Xray"
description="Xray Proxy Service"

command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config/config.json"
command_background=true
pidfile="/var/run/xray.pid"
output_log="/var/log/xray/output.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/run/xray
    checkpath --file --owner root:root --mode 0644 ${output_log} ${error_log}
}
EOF
    chmod +x ${XRAY_SERVICE}
    rc-update add xray default 2>/dev/null || true
}

generate_uuid() {
    ${XRAY_BIN} uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

check_port_available() {
    local port=$1
    if netstat -tln 2>/dev/null | grep -q ":${port} " || ss -tln 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

get_local_ip() {
    ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || \
    ip -4 addr show | grep -v 127.0.0.1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
    echo "127.0.0.1"
}

#=============================================================================
# Xray 节点配置
#=============================================================================

generate_tunnel_node_config() {
    local node_id=$1 node_name=$2 uuid=$3 ws_path=$4 sni=$5 local_port=$6
    
    cat > ${XRAY_CONFIG_DIR}/node_${node_id}.json << EOF
{
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": ${local_port},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${uuid}",
        "level": 0,
        "email": "${node_name}"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "${ws_path}",
        "headers": {
          "Host": "${sni}"
        }
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF
}

generate_standard_node_config() {
    local node_id=$1 node_name=$2 uuid=$3 ws_path=$4 sni=$5 cert_path=$6 key_path=$7 local_port=$8
    
    cat > ${XRAY_CONFIG_DIR}/node_${node_id}.json << EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${local_port},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${uuid}",
        "level": 0,
        "email": "${node_name}"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "${cert_path}",
          "keyFile": "${key_path}"
        }],
        "serverName": "${sni}",
        "alpn": ["http/1.1", "h2"]
      },
      "wsSettings": {
        "path": "${ws_path}",
        "headers": {
          "Host": "${sni}"
        }
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF
}

generate_combined_config() {
    cat > ${XRAY_CONFIG_DIR}/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF

    for config_file in ${XRAY_CONFIG_DIR}/node_*.json; do
        if [ -f "$config_file" ]; then
            local inbound=$(jq '.inbounds[0]' "$config_file" 2>/dev/null)
            if [ -n "$inbound" ] && [ "$inbound" != "null" ]; then
                jq ".inbounds += [${inbound}]" ${XRAY_CONFIG_DIR}/config.json > ${XRAY_CONFIG_DIR}/config.json.tmp
                mv ${XRAY_CONFIG_DIR}/config.json.tmp ${XRAY_CONFIG_DIR}/config.json
            fi
        fi
    done
}

#=============================================================================
# 证书处理
#=============================================================================

handle_certificate() {
    local sni=$1 cert_method=$2
    local cert_path="" key_path=""
    
    case $cert_method in
        1)
            while true; do
                read -p "证书公钥路径: " cert_path
                [ -z "$cert_path" ] && continue
                [ -f "$cert_path" ] && break
                echo -e "${RED}文件不存在${NC}"
            done
            while true; do
                read -p "证书私钥路径: " key_path
                [ -z "$key_path" ] && continue
                [ -f "$key_path" ] && break
                echo -e "${RED}文件不存在${NC}"
            done
            ;;
        2)
            echo -e "${YELLOW}申请 Let's Encrypt 证书...${NC}"
            if [ ! -f "/root/.acme.sh/acme.sh" ]; then
                apk add socat openssl 2>/dev/null || true
                curl https://get.acme.sh | sh -s email=admin@${sni}
            fi
            ~/.acme.sh/acme.sh --issue -d ${sni} --standalone --force || {
                echo -e "${RED}申请失败${NC}"; return 1
            }
            cert_path="/root/.acme.sh/${sni}/fullchain.cer"
            key_path="/root/.acme.sh/${sni}/${sni}.key"
            ;;
        3)
            echo -e "${CYAN}Cloudflare Dashboard -> SSL/TLS -> Origin Server -> Create Certificate${NC}"
            read -p "证书保存路径 (默认: /etc/ssl/certs/cf.pem): " cert_path
            cert_path=${cert_path:-/etc/ssl/certs/cf.pem}
            read -p "私钥保存路径 (默认: /etc/ssl/private/cf.key): " key_path
            key_path=${key_path:-/etc/ssl/private/cf.key}
            mkdir -p $(dirname $cert_path) $(dirname $key_path)
            echo -e "${YELLOW}粘贴证书内容 (输入 EOF 结束):${NC}"
            cat > $cert_path
            [ ! -s "$cert_path" ] && { echo -e "${RED}证书为空${NC}"; return 1; }
            echo -e "${YELLOW}粘贴私钥内容 (输入 EOF 结束):${NC}"
            cat > $key_path
            [ ! -s "$key_path" ] && { echo -e "${RED}私钥为空${NC}"; return 1; }
            ;;
        *) echo -e "${RED}无效选项${NC}"; return 1 ;;
    esac
    
    echo "${cert_path}|${key_path}"
    return 0
}

#=============================================================================
# Cloudflare Tunnel 管理
#=============================================================================

install_cloudflared() {
    if [ -f "${CF_TUNNEL_BIN}" ]; then
        echo -e "${GREEN}cloudflared 已安装${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}安装 Cloudflare Tunnel...${NC}"
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64)  CF_ARCH="amd64" ;;
        aarch64) CF_ARCH="arm64" ;;
        armv7l|armhf) CF_ARCH="arm" ;;
        *) echo -e "${RED}不支持的架构${NC}"; return 1 ;;
    esac
    
    # 确保目录存在
    mkdir -p ${CF_TUNNEL_CONFIG} ${CF_HOME}
    
    wget -q --show-progress "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -O ${CF_TUNNEL_BIN}
    chmod +x ${CF_TUNNEL_BIN}
    echo -e "${GREEN}cloudflared 安装完成${NC}"
}

create_tunnel_service() {
    cat > ${CF_TUNNEL_SERVICE} << 'EOF'
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"

command="/usr/local/bin/cloudflared"
command_args="tunnel --config /etc/cloudflared/config.yml run"
command_background=true
pidfile="/var/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.log"

depend() {
    need net
}

start_pre() {
    checkpath --file --mode 0644 ${output_log} ${error_log}
}
EOF
    chmod +x ${CF_TUNNEL_SERVICE}
    rc-update add cloudflared default 2>/dev/null || true
}

# 登录 Cloudflare
login_cloudflare() {
    # 确保目录存在
    mkdir -p ${CF_HOME}
    
    # 检查是否已登录
    if [ -f "${CF_HOME}/cert.pem" ]; then
        echo -e "${GREEN}已登录 Cloudflare${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}需要登录 Cloudflare Tunnel${NC}"
    echo ""
    echo -e "${CYAN}请选择登录方式:${NC}"
    echo "1. 本机登录 (需要浏览器和桌面环境)"
    echo "2. 上传 cert.pem 文件 (推荐)"
    read -p "请选择 [1-2]: " login_choice
    
    case $login_choice in
        1)
            echo -e "${YELLOW}即将打开浏览器...${NC}"
            ${CF_TUNNEL_BIN} tunnel login
            if [ -f "${CF_HOME}/cert.pem" ]; then
                echo -e "${GREEN}登录成功${NC}"
            else
                echo -e "${RED}登录失败${NC}"
                return 1
            fi
            ;;
        2)
            echo -e "${CYAN}获取 cert.pem 的方法:${NC}"
            echo "1. 在您的电脑上下载 cloudflared:"
            echo "   https://github.com/cloudflare/cloudflared/releases"
            echo "2. 运行: cloudflared tunnel login"
            echo "3. 将生成的 cert.pem 上传到服务器"
            echo "   默认路径: ~/.cloudflared/cert.pem"
            echo ""
            read -p "请输入 cert.pem 文件路径: " cert_file
            
            if [ -z "$cert_file" ]; then
                echo -e "${RED}路径不能为空${NC}"
                return 1
            fi
            
            if [ ! -f "$cert_file" ]; then
                echo -e "${RED}文件不存在: ${cert_file}${NC}"
                return 1
            fi
            
            # 确保目标目录存在
            mkdir -p ${CF_HOME}
            
            # 复制文件
            cp "$cert_file" "${CF_HOME}/cert.pem"
            chmod 600 "${CF_HOME}/cert.pem"
            echo -e "${GREEN}cert.pem 已导入到 ${CF_HOME}/cert.pem${NC}"
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            return 1
            ;;
    esac
    
    return 0
}

# 完整 Tunnel 配置
setup_tunnel() {
    local tunnel_domain=$1
    local local_port=$2
    
    echo -e "${BLUE}====== 配置 Cloudflare Tunnel ======${NC}"
    
    # 确保所有目录存在
    mkdir -p ${CF_HOME} ${CF_TUNNEL_CONFIG}
    
    # 1. 安装
    install_cloudflared || return 1
    
    # 2. 登录
    login_cloudflare || return 1
    
    # 3. 创建 Tunnel
    local tunnel_name="xray-$(echo ${tunnel_domain} | tr '.' '-')-$(date +%s | tail -c 5)"
    echo -e "${YELLOW}创建 Tunnel: ${tunnel_name}${NC}"
    
    ${CF_TUNNEL_BIN} tunnel create ${tunnel_name}
    
    # 等待文件生成
    sleep 1
    
    # 获取 Tunnel ID
    local tunnel_id=$(${CF_TUNNEL_BIN} tunnel list 2>/dev/null | grep ${tunnel_name} | awk '{print $1}')
    
    if [ -z "$tunnel_id" ]; then
        echo -e "${RED}无法获取 Tunnel ID${NC}"
        echo -e "${YELLOW}Tunnel 列表:${NC}"
        ${CF_TUNNEL_BIN} tunnel list
        return 1
    fi
    
    # 凭证文件路径
    local cred_file="${CF_HOME}/${tunnel_id}.json"
    
    if [ ! -f "$cred_file" ]; then
        echo -e "${RED}找不到凭证文件: ${cred_file}${NC}"
        echo -e "${YELLOW}可用文件:${NC}"
        ls -la ${CF_HOME}/*.json 2>/dev/null || echo "无 .json 文件"
        
        # 尝试查找
        cred_file=$(ls ${CF_HOME}/*.json 2>/dev/null | head -1)
        if [ -z "$cred_file" ]; then
            return 1
        fi
        echo -e "${YELLOW}使用: ${cred_file}${NC}"
    fi
    
    echo -e "${GREEN}Tunnel ID: ${tunnel_id}${NC}"
    echo -e "${GREEN}凭证: ${cred_file}${NC}"
    
    # 4. 配置 DNS 路由
    echo -e "${YELLOW}配置 DNS 路由...${NC}"
    ${CF_TUNNEL_BIN} tunnel route dns ${tunnel_id} ${tunnel_domain}
    echo -e "${GREEN}DNS 路由已配置${NC}"
    
    # 5. 创建配置文件（使用 .json 凭证文件）
    cat > ${CF_TUNNEL_CONFIG}/config.yml << EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file}

ingress:
  - hostname: ${tunnel_domain}
    service: http://localhost:${local_port}
  - service: http_status:404

logfile: ${CF_TUNNEL_LOG}
loglevel: info
EOF
    
    echo -e "${GREEN}配置文件:${NC}"
    cat ${CF_TUNNEL_CONFIG}/config.yml
    
    # 6. 创建并启动服务
    create_tunnel_service
    
    echo -e "${YELLOW}启动 Tunnel 服务...${NC}"
    rc-service cloudflared stop 2>/dev/null || true
    sleep 1
    rc-service cloudflared start
    sleep 3
    
    # 7. 验证
    if rc-service cloudflared status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}✓ Tunnel 服务运行中${NC}"
    else
        echo -e "${YELLOW}检查日志:${NC}"
        tail -20 ${CF_TUNNEL_LOG} 2>/dev/null
        
        # 再等一会
        sleep 5
        if rc-service cloudflared status 2>/dev/null | grep -q "started"; then
            echo -e "${GREEN}✓ Tunnel 服务运行中${NC}"
        else
            echo -e "${RED}启动失败，请查看日志${NC}"
        fi
    fi
    
    # 8. 保存配置
    echo "${tunnel_id}|${tunnel_name}|${tunnel_domain}|${local_port}" > ${TUNNEL_DIR}/current_tunnel.txt
    
    echo -e "${GREEN}====== Tunnel 配置完成 ======${NC}"
    echo "域名: ${tunnel_domain}"
    echo "端口: ${local_port} (内部)"
    echo "Tunnel ID: ${tunnel_id}"
    
    return 0
}

# Tunnel 管理菜单
manage_tunnel() {
    mkdir -p ${TUNNEL_DIR} ${CF_HOME}
    
    while true; do
        echo ""
        echo -e "${BLUE}====== Tunnel 管理 ======${NC}"
        echo "1. 安装 cloudflared"
        echo "2. 配置新 Tunnel"
        echo "3. 查看状态"
        echo "4. 重启 Tunnel"
        echo "5. 查看日志"
        echo "6. 测试连接"
        echo "0. 返回"
        read -p "选择 [0-6]: " opt
        
        case $opt in
            1) install_cloudflared ;;
            2)
                read -p "域名: " domain
                read -p "本地端口: " port
                setup_tunnel "$domain" "$port"
                ;;
            3)
                echo -e "${YELLOW}服务状态:${NC}"
                rc-service cloudflared status 2>/dev/null || echo "未运行"
                echo ""
                echo -e "${YELLOW}Tunnel 列表:${NC}"
                ${CF_TUNNEL_BIN} tunnel list 2>/dev/null || echo "无法获取"
                echo ""
                echo -e "${YELLOW}路由列表:${NC}"
                ${CF_TUNNEL_BIN} tunnel route list 2>/dev/null || echo "无法获取"
                if [ -s "${TUNNEL_DIR}/current_tunnel.txt" ]; then
                    echo ""
                    echo -e "${YELLOW}当前配置:${NC}"
                    cat ${TUNNEL_DIR}/current_tunnel.txt
                fi
                ;;
            4)
                rc-service cloudflared restart
                sleep 2
                rc-service cloudflared status
                ;;
            5)
                if [ -f "${CF_TUNNEL_LOG}" ]; then
                    tail -30 ${CF_TUNNEL_LOG}
                else
                    echo "无日志文件"
                fi
                ;;
            6)
                if [ -s "${TUNNEL_DIR}/current_tunnel.txt" ]; then
                    local d=$(cat ${TUNNEL_DIR}/current_tunnel.txt | cut -d'|' -f3)
                    echo -e "${YELLOW}测试: https://${d}${NC}"
                    curl -sk -o /dev/null -w "HTTP: %{http_code}\n" https://${d} 2>/dev/null || echo "连接失败"
                else
                    echo "未配置 Tunnel"
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

#=============================================================================
# 节点管理
#=============================================================================

create_node() {
    echo -e "${BLUE}====== 创建新节点 ======${NC}"
    echo ""
    
    echo -e "${YELLOW}连接模式:${NC}"
    echo "1. 标准模式 (需要公网IP/端口转发 + TLS证书)"
    echo "2. Cloudflare Tunnel 模式 (无需公网IP，自动HTTPS)"
    read -p "选择 [1-2]: " mode_choice
    
    local use_tunnel="false"
    local sni=""
    
    if [ "$mode_choice" = "2" ]; then
        use_tunnel="true"
        echo -e "${MAGENTA}====== Tunnel 模式 ======${NC}"
        echo -e "${CYAN}输入用于 Tunnel 的域名 (该域名将作为连接地址和SNI)${NC}"
        read -p "域名: " sni
        [ -z "$sni" ] && { echo -e "${RED}域名不能为空${NC}"; return; }
        install_cloudflared || return
    else
        echo -e "${MAGENTA}====== 标准模式 ======${NC}"
        read -p "域名 (SNI): " sni
        [ -z "$sni" ] && { echo -e "${RED}域名不能为空${NC}"; return; }
    fi
    
    read -p "节点名称: " node_name
    [ -z "$node_name" ] && { echo -e "${RED}名称不能为空${NC}"; return; }
    
    # 端口
    while true; do
        if [ "$use_tunnel" = "true" ]; then
            read -p "本地端口 (留空随机): " local_port
            [ -z "$local_port" ] && local_port=$((10000 + RANDOM % 55535)) && echo -e "${GREEN}随机端口: ${local_port}${NC}"
        else
            read -p "本地监听端口: " local_port
        fi
        [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] && break
        echo -e "${RED}无效端口${NC}"
    done
    
    local external_port=$local_port
    if [ "$use_tunnel" != "true" ]; then
        read -p "公网端口 (默认: ${local_port}): " external_port
        external_port=${external_port:-$local_port}
    fi
    
    read -p "UUID (留空自动生成): " uuid
    uuid=${uuid:-$(generate_uuid)}
    echo -e "${GREEN}UUID: ${uuid}${NC}"
    
    read -p "WS Path (留空自动生成): " ws_path
    ws_path=${ws_path:-/ws$(date +%s | tail -c 5)}
    [[ "$ws_path" != /* ]] && ws_path="/${ws_path}"
    echo -e "${GREEN}WS Path: ${ws_path}${NC}"
    
    # 证书（仅标准模式）
    local cert_path="" key_path=""
    if [ "$use_tunnel" != "true" ]; then
        echo ""
        echo -e "${BLUE}证书配置:${NC}"
        echo "1. 已有证书  2. Let's Encrypt  3. CF Origin"
        read -p "选择 [1-3]: " cert_method
        local cert_result=$(handle_certificate "$sni" "$cert_method") || return
        cert_path=$(echo "$cert_result" | cut -d'|' -f1)
        key_path=$(echo "$cert_result" | cut -d'|' -f2)
    fi
    
    # 节点 ID
    local node_id=0
    [ -s "${NODES_FILE}" ] && node_id=$(($(tail -1 ${NODES_FILE} | cut -d'|' -f1) + 1))
    
    # 保存
    echo "${node_id}|${node_name}|${uuid}|${ws_path}|${sni}|${cert_path}|${key_path}|${local_port}|${external_port}|${use_tunnel}" >> ${NODES_FILE}
    
    # 生成配置
    if [ "$use_tunnel" = "true" ]; then
        generate_tunnel_node_config ${node_id} "${node_name}" "${uuid}" "${ws_path}" "${sni}" ${local_port}
    else
        generate_standard_node_config ${node_id} "${node_name}" "${uuid}" "${ws_path}" "${sni}" "${cert_path}" "${key_path}" ${local_port}
    fi
    
    generate_combined_config
    
    # 验证
    echo -e "${YELLOW}验证 Xray 配置...${NC}"
    if ! ${XRAY_BIN} run -test -config ${XRAY_CONFIG_DIR}/config.json > /dev/null 2>&1; then
        echo -e "${RED}配置验证失败:${NC}"
        ${XRAY_BIN} run -test -config ${XRAY_CONFIG_DIR}/config.json
        return
    fi
    echo -e "${GREEN}配置验证通过${NC}"
    
    # Tunnel 配置
    if [ "$use_tunnel" = "true" ]; then
        setup_tunnel "$sni" "$local_port"
    fi
    
    # 重启 Xray
    restart_xray
    
    # 输出
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        节点创建成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "节点 ID: ${node_id}"
    echo "名称: ${node_name}"
    echo "域名: ${sni}"
    echo "端口: $([ "$use_tunnel" = "true" ] && echo "443 (Tunnel)" || echo "${external_port}")"
    echo "UUID: ${uuid}"
    echo "WS Path: ${ws_path}"
    echo "模式: $([ "$use_tunnel" = "true" ] && echo "Cloudflare Tunnel" || echo "标准")"
    echo ""
    
    echo -e "${YELLOW}====== VLESS 链接 ======${NC}"
    if [ "$use_tunnel" = "true" ]; then
        echo -e "${CYAN}vless://${uuid}@${sni}:443?encryption=none&security=tls&sni=${sni}&alpn=http/1.1&type=ws&path=${ws_path}&host=${sni}#${node_name}${NC}"
        echo ""
        echo -e "${YELLOW}流量路径: 客户端 -> Cloudflare(${sni}:443) -> Tunnel -> Xray(127.0.0.1:${local_port})${NC}"
    else
        echo -e "${CYAN}vless://${uuid}@${sni}:${external_port}?encryption=none&security=tls&sni=${sni}&alpn=http/1.1&type=ws&path=${ws_path}&host=${sni}#${node_name}${NC}"
    fi
    echo ""
}

list_nodes() {
    echo -e "${BLUE}====== 节点列表 ======${NC}"
    if [ ! -s "${NODES_FILE}" ]; then
        echo -e "${YELLOW}暂无节点${NC}"
        return
    fi
    
    while IFS='|' read -r id name uuid path sni cert key local_port external_port use_tunnel; do
        local mode="标准"
        [ "$use_tunnel" = "true" ] && mode="Tunnel"
        echo -e "${GREEN}节点 ${id} - ${name}${NC}"
        echo "  域名: ${sni}"
        echo "  端口: $([ "$use_tunnel" = "true" ] && echo "443" || echo "${external_port}")"
        echo "  路径: ${path}"
        echo "  模式: ${mode}"
        if [ "$use_tunnel" = "true" ]; then
            echo -e "  ${CYAN}vless://${uuid}@${sni}:443?encryption=none&security=tls&sni=${sni}&type=ws&path=${path}&host=${sni}#${name}${NC}"
        else
            echo -e "  ${CYAN}vless://${uuid}@${sni}:${external_port}?encryption=none&security=tls&sni=${sni}&type=ws&path=${path}&host=${sni}#${name}${NC}"
        fi
        echo ""
    done < ${NODES_FILE}
}

delete_node() {
    [ ! -s "${NODES_FILE}" ] && { echo -e "${RED}无节点${NC}"; return; }
    list_nodes
    read -p "删除节点 ID: " node_id
    grep -q "^${node_id}|" ${NODES_FILE} || { echo -e "${RED}不存在${NC}"; return; }
    read -p "确认? (y/N): " c
    [ "$c" != "y" ] && [ "$c" != "Y" ] && return
    rm -f ${XRAY_CONFIG_DIR}/node_${node_id}.json
    sed -i "/^${node_id}|/d" ${NODES_FILE}
    generate_combined_config
    restart_xray
    echo -e "${GREEN}已删除${NC}"
}

restart_xray() {
    echo -e "${YELLOW}重启 Xray...${NC}"
    [ ! -f "${XRAY_CONFIG_DIR}/config.json" ] && { echo -e "${RED}无配置${NC}"; return; }
    ${XRAY_BIN} run -test -config ${XRAY_CONFIG_DIR}/config.json > /dev/null 2>&1 || {
        echo -e "${RED}配置错误:${NC}"; ${XRAY_BIN} run -test -config ${XRAY_CONFIG_DIR}/config.json; return
    }
    rc-service xray restart 2>/dev/null || rc-service xray start 2>/dev/null
    sleep 2
    rc-service xray status 2>/dev/null | grep -q "started" && echo -e "${GREEN}✓ Xray 运行中${NC}" || echo -e "${RED}启动失败${NC}"
    netstat -tlnp 2>/dev/null | grep xray || ss -tlnp 2>/dev/null | grep xray || true
}

diagnose_nat() {
    init_dirs
    
    echo -e "${BLUE}====== 诊断 ======${NC}"
    echo "系统: Alpine $(cat /etc/alpine-release 2>/dev/null)"
    echo "IP: $(get_local_ip)"
    echo ""
    echo -e "${YELLOW}监听:${NC}"
    netstat -tlnp 2>/dev/null | grep -E "(xray|cloudflared)" || ss -tlnp 2>/dev/null | grep -E "(xray|cloudflared)" || echo "无相关进程"
    echo ""
    echo -e "${YELLOW}Xray:${NC}"
    rc-service xray status 2>/dev/null || echo "未运行"
    echo ""
    echo -e "${YELLOW}Tunnel:${NC}"
    rc-service cloudflared status 2>/dev/null || echo "未运行"
    if [ -f "${CF_TUNNEL_CONFIG}/config.yml" ]; then
        echo "Tunnel 配置:"
        cat ${CF_TUNNEL_CONFIG}/config.yml
    fi
}

uninstall_service() {
    read -p "输入 YES 确认卸载: " c
    [ "$c" != "YES" ] && return
    rc-service xray stop 2>/dev/null || true
    rc-service cloudflared stop 2>/dev/null || true
    rc-update del xray default 2>/dev/null || true
    rc-update del cloudflared default 2>/dev/null || true
    rm -f ${XRAY_SERVICE} ${CF_TUNNEL_SERVICE}
    killall xray cloudflared 2>/dev/null || true
    rm -rf ${XRAY_DIR} ${CF_TUNNEL_CONFIG} ${LOG_DIR} ${CF_HOME}
    rm -f ${XRAY_BIN} ${CF_TUNNEL_BIN} ${CF_TUNNEL_LOG}
    echo -e "${GREEN}已卸载${NC}"
}

#=============================================================================
# 初始化
#=============================================================================

initialize() {
    echo -e "${BLUE}===== Xray 节点管理系统 =====${NC}"
    check_root
    init_dirs
    install_dependencies
    install_xray
    create_xray_service
    echo -e "${GREEN}初始化完成${NC}"
}

#=============================================================================
# 主菜单
#=============================================================================

main_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}===== Xray 节点管理 =====${NC}"
        echo "1. 创建节点   2. 删除节点   3. 节点列表"
        echo "4. 重启Xray   5. Tunnel管理  6. 诊断"
        echo "7. 卸载       0. 退出"
        read -p "选择 [0-7]: " opt
        case $opt in
            1) create_node ;; 2) delete_node ;; 3) list_nodes ;;
            4) restart_xray ;; 5) manage_tunnel ;; 6) diagnose_nat ;;
            7) uninstall_service ;; 0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

#=============================================================================
# 入口
#=============================================================================

# 确保所有目录在脚本启动时就创建
init_dirs

if [ ! -f "${XRAY_BIN}" ] || [ ! -f "${XRAY_SERVICE}" ]; then
    initialize
fi

check_root
main_menu