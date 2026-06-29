#!/bin/bash

# ZBProxy 一键管理脚本
# 支持安装、更新、卸载
# 支持 v1 和 v3 版本选择
# 适用于 OpenRC 系统（如 Alpine Linux、Gentoo 等）

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 版本信息
SCRIPT_VERSION="1.1.0"

# 版本 URL
V1_URL="https://github.com/Stoeaves/ZBProxy/releases/latest/download/ZBProxy-linux-amd64-v1"
V3_URL="https://github.com/Stoeaves/ZBProxy/releases/latest/download/ZBProxy-linux-amd64-v3"

# 安装版本记录
INSTALLED_VERSION=""

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    local deps=("wget" "rc-update" "rc-service")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${YELLOW}缺少依赖: ${missing[*]}${NC}"
        echo "请安装后重试"
        exit 1
    fi
}

# 获取当前安装版本
get_current_version() {
    if [ -f "/usr/local/bin/zbproxy" ]; then
        # 尝试获取版本信息
        local version_info
        version_info=$(/usr/local/bin/zbproxy --version 2>/dev/null | head -1)
        if echo "$version_info" | grep -qi "v3"; then
            echo "v3"
        elif echo "$version_info" | grep -qi "v1"; then
            echo "v1"
        else
            # 通过文件大小或其他方式判断
            local file_size
            file_size=$(stat -c%s "/usr/local/bin/zbproxy" 2>/dev/null || echo "0")
            if [ "$file_size" -gt 10000000 ]; then
                echo "v3"
            else
                echo "v1"
            fi
        fi
    else
        echo "not_installed"
    fi
}

# 下载并安装指定版本
download_and_install() {
    local version=$1
    local url=$2
    
    echo -e "${BLUE}正在下载 ZBProxy $version...${NC}"
    
    # 下载
    if ! wget -O /usr/local/bin/zbproxy "$url"; then
        echo -e "${RED}下载失败，请检查网络连接${NC}"
        return 1
    fi
    
    # 添加执行权限
    chmod +x /usr/local/bin/zbproxy
    
    # 验证文件是否可执行
    if ! /usr/local/bin/zbproxy --version &>/dev/null; then
        echo -e "${RED}下载的文件无法执行，可能已损坏${NC}"
        return 1
    fi
    
    INSTALLED_VERSION="$version"
    return 0
}

# 测试服务是否能正常启动
test_service() {
    echo "正在测试服务启动..."
    
    # 尝试启动服务
    if rc-service zbproxy start 2>/dev/null; then
        # 等待几秒让服务完全启动
        sleep 3
        
        # 检查服务状态
        if rc-service zbproxy status &>/dev/null; then
            echo -e "${GREEN}服务启动成功${NC}"
            return 0
        else
            echo -e "${YELLOW}服务启动后状态异常${NC}"
            rc-service zbproxy stop 2>/dev/null || true
            return 1
        fi
    else
        echo -e "${YELLOW}服务启动失败${NC}"
        return 1
    fi
}

# 创建 OpenRC 服务脚本
create_service_script() {
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
    
    chmod +x /etc/init.d/zbproxy
}

# 安装 ZBProxy
install_zbproxy() {
    echo -e "${BLUE}开始安装 ZBProxy...${NC}"
    
    # 检查是否已安装
    if [ -f "/usr/local/bin/zbproxy" ]; then
        echo -e "${YELLOW}检测到已安装 ZBProxy${NC}"
        read -p "是否覆盖安装? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "安装已取消"
            return 1
        fi
        # 停止旧服务
        rc-service zbproxy stop 2>/dev/null || true
    fi
    
    # 选择版本
    echo ""
    echo -e "${BLUE}请选择要安装的版本:${NC}"
    echo -e "  ${GREEN}1.${NC} v1 (兼容性更好，适合旧系统)"
    echo -e "  ${GREEN}2.${NC} v3 (功能更新，性能更好)"
    echo -e "  ${GREEN}3.${NC} 自动选择 (先尝试 v3，失败则回退到 v1)"
    echo ""
    read -p "请选择 [1-3]: " version_choice
    
    local install_success=false
    local current_version=""
    
    case $version_choice in
        1)
            echo -e "${BLUE}选择安装 v1 版本${NC}"
            if download_and_install "v1" "$V1_URL"; then
                install_success=true
                current_version="v1"
            fi
            ;;
        2)
            echo -e "${BLUE}选择安装 v3 版本${NC}"
            if download_and_install "v3" "$V3_URL"; then
                install_success=true
                current_version="v3"
            fi
            ;;
        3)
            echo -e "${BLUE}自动选择模式：优先尝试 v3${NC}"
            echo ""
            
            # 先尝试 v3
            echo -e "${YELLOW}尝试安装 v3 版本...${NC}"
            if download_and_install "v3" "$V3_URL"; then
                # 创建服务脚本
                create_service_script
                
                # 测试 v3 是否能正常启动
                echo "测试 v3 版本..."
                if test_service; then
                    install_success=true
                    current_version="v3"
                    echo -e "${GREEN}✓ v3 版本安装并测试成功！${NC}"
                else
                    echo -e "${YELLOW}⚠ v3 版本启动失败，尝试回退到 v1...${NC}"
                    # 清理失败的文件
                    rm -f /usr/local/bin/zbproxy
                    rm -f /etc/init.d/zbproxy
                    
                    # 尝试安装 v1
                    if download_and_install "v1" "$V1_URL"; then
                        # 重新创建服务脚本
                        create_service_script
                        
                        # 测试 v1
                        echo "测试 v1 版本..."
                        if test_service; then
                            install_success=true
                            current_version="v1"
                            echo -e "${GREEN}✓ v1 版本安装并测试成功！${NC}"
                        else
                            echo -e "${RED}✗ v1 版本也无法启动，安装失败${NC}"
                            rm -f /usr/local/bin/zbproxy
                            rm -f /etc/init.d/zbproxy
                        fi
                    else
                        echo -e "${RED}✗ v1 版本下载失败，安装失败${NC}"
                    fi
                fi
            else
                echo -e "${RED}✗ v3 版本下载失败，尝试 v1...${NC}"
                if download_and_install "v1" "$V1_URL"; then
                    create_service_script
                    if test_service; then
                        install_success=true
                        current_version="v1"
                        echo -e "${GREEN}✓ v1 版本安装并测试成功！${NC}"
                    else
                        echo -e "${RED}✗ v1 版本也无法启动，安装失败${NC}"
                        rm -f /usr/local/bin/zbproxy
                        rm -f /etc/init.d/zbproxy
                    fi
                else
                    echo -e "${RED}✗ v1 版本下载失败，安装失败${NC}"
                fi
            fi
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            return 1
            ;;
    esac
    
    # 如果还没创建服务脚本（手动选择版本的情况）
    if [ "$install_success" = true ] && [ ! -f "/etc/init.d/zbproxy" ]; then
        create_service_script
    fi
    
    if [ "$install_success" = true ]; then
        # 添加开机自启
        echo "正在添加开机自启..."
        rc-update add zbproxy default 2>/dev/null || true
        
        # 启动服务（如果还没启动）
        if ! rc-service zbproxy status &>/dev/null; then
            echo "正在启动服务..."
            rc-service zbproxy start 2>/dev/null || true
        fi
        
        # 检查服务状态
        echo "检查服务状态..."
        rc-service zbproxy status 2>/dev/null || echo "服务状态检查完成"
        
        echo -e "${GREEN}ZBProxy $current_version 安装完成！${NC}"
        echo -e "安装版本: ${GREEN}$current_version${NC}"
        return 0
    else
        echo -e "${RED}ZBProxy 安装失败！${NC}"
        return 1
    fi
}

# 更新 ZBProxy
update_zbproxy() {
    echo -e "${BLUE}开始更新 ZBProxy...${NC}"
    
    # 检查是否已安装
    if [ ! -f "/usr/local/bin/zbproxy" ]; then
        echo -e "${RED}未检测到已安装的 ZBProxy，请先安装${NC}"
        return 1
    fi
    
    CURRENT_VERSION=$(get_current_version)
    echo -e "当前版本: ${YELLOW}$CURRENT_VERSION${NC}"
    
    # 选择更新版本
    echo ""
    echo -e "${BLUE}请选择要更新到的版本:${NC}"
    echo -e "  ${GREEN}1.${NC} v1 (兼容性更好，适合旧系统)"
    echo -e "  ${GREEN}2.${NC} v3 (功能更新，性能更好)"
    echo -e "  ${GREEN}3.${NC} 保持当前版本 ($CURRENT_VERSION)"
    echo ""
    read -p "请选择 [1-3]: " version_choice
    
    local target_version=""
    local target_url=""
    
    case $version_choice in
        1)
            target_version="v1"
            target_url="$V1_URL"
            ;;
        2)
            target_version="v3"
            target_url="$V3_URL"
            ;;
        3)
            echo "保持当前版本，跳过更新"
            return 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            return 1
            ;;
    esac
    
    if [ "$target_version" = "$CURRENT_VERSION" ]; then
        echo -e "${YELLOW}目标版本与当前版本相同，无需更新${NC}"
        read -p "是否强制重新安装? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # 停止服务
    echo "正在停止服务..."
    rc-service zbproxy stop 2>/dev/null || true
    
    # 备份旧文件
    if [ -f "/usr/local/bin/zbproxy" ]; then
        mv /usr/local/bin/zbproxy /usr/local/bin/zbproxy.bak
        echo "已备份旧版本"
    fi
    
    # 下载新版本
    echo "正在下载 $target_version..."
    if ! wget -O /usr/local/bin/zbproxy "$target_url"; then
        echo -e "${RED}下载失败，正在恢复备份...${NC}"
        [ -f "/usr/local/bin/zbproxy.bak" ] && mv /usr/local/bin/zbproxy.bak /usr/local/bin/zbproxy
        return 1
    fi
    
    chmod +x /usr/local/bin/zbproxy
    
    # 验证新版本
    if ! /usr/local/bin/zbproxy --version &>/dev/null; then
        echo -e "${RED}新版本文件无法执行，正在恢复备份...${NC}"
        [ -f "/usr/local/bin/zbproxy.bak" ] && mv /usr/local/bin/zbproxy.bak /usr/local/bin/zbproxy
        return 1
    fi
    
    # 删除备份
    rm -f /usr/local/bin/zbproxy.bak
    
    # 测试启动
    echo "测试新版本..."
    if ! test_service; then
        echo -e "${RED}新版本启动失败，正在恢复备份...${NC}"
        # 恢复备份
        if [ -f "/usr/local/bin/zbproxy.bak" ]; then
            mv /usr/local/bin/zbproxy.bak /usr/local/bin/zbproxy
            chmod +x /usr/local/bin/zbproxy
        fi
        # 重启旧版本
        rc-service zbproxy start 2>/dev/null || true
        return 1
    fi
    
    echo -e "${GREEN}ZBProxy 更新完成！新版本: $target_version${NC}"
    return 0
}

# 卸载 ZBProxy
uninstall_zbproxy() {
    echo -e "${BLUE}开始卸载 ZBProxy...${NC}"
    
    # 检查是否已安装
    if [ ! -f "/usr/local/bin/zbproxy" ] && [ ! -f "/etc/init.d/zbproxy" ]; then
        echo -e "${YELLOW}未检测到已安装的 ZBProxy${NC}"
        return 0
    fi
    
    # 确认卸载
    read -p "确认要卸载 ZBProxy 吗? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "卸载已取消"
        return 0
    fi
    
    # 停止服务
    echo "正在停止服务..."
    if rc-service zbproxy status &>/dev/null; then
        rc-service zbproxy stop
        echo "服务已停止"
    else
        echo "服务未运行，跳过停止步骤"
    fi
    
    # 移除开机自启
    echo "正在移除开机自启..."
    if rc-update show 2>/dev/null | grep -q zbproxy; then
        rc-update del zbproxy default 2>/dev/null || true
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
    
    # 删除备份文件
    if [ -f "/usr/local/bin/zbproxy.bak" ]; then
        rm -f /usr/local/bin/zbproxy.bak
        echo "备份文件已删除"
    fi
    
    # 删除 PID 文件
    if [ -f "/run/zbproxy.pid" ]; then
        rm -f /run/zbproxy.pid
        echo "PID 文件已删除"
    fi
    
    # 可选：删除配置文件
    if [ -f "/etc/zbproxy/config.json" ]; then
        read -p "是否删除配置文件 /etc/zbproxy/config.json? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f /etc/zbproxy/config.json
            echo "配置文件已删除"
            
            if [ -d "/etc/zbproxy" ] && [ -z "$(ls -A /etc/zbproxy 2>/dev/null)" ]; then
                rmdir /etc/zbproxy 2>/dev/null || true
                echo "配置目录已删除"
            fi
        else
            echo "保留配置文件"
        fi
    fi
    
    echo -e "${GREEN}ZBProxy 卸载完成！${NC}"
    
    # 显示残留检查
    echo ""
    echo -e "${YELLOW}===== 残留检查 =====${NC}"
    local has_remains=false
    for file in "/usr/local/bin/zbproxy" "/etc/init.d/zbproxy" "/run/zbproxy.pid"; do
        if [ -f "$file" ]; then
            echo -e "${RED}⚠️  残留文件: $file${NC}"
            has_remains=true
        fi
    done
    if [ "$has_remains" = false ]; then
        echo -e "${GREEN}✓ 所有文件已清理干净${NC}"
    fi
    
    return 0
}

# 查看状态
show_status() {
    echo -e "${BLUE}===== ZBProxy 状态 =====${NC}"
    
    if [ -f "/usr/local/bin/zbproxy" ]; then
        echo -e "状态: ${GREEN}已安装${NC}"
        VERSION=$(get_current_version)
        echo "版本: $VERSION"
        
        # 显示更多版本信息
        echo "详细版本信息:"
        /usr/local/bin/zbproxy --version 2>/dev/null | head -3 || echo "无法获取详细版本信息"
    else
        echo -e "状态: ${RED}未安装${NC}"
    fi
    
    echo ""
    if command -v rc-service &>/dev/null; then
        echo "服务状态:"
        rc-service zbproxy status 2>/dev/null || echo -e "${YELLOW}服务未注册${NC}"
    fi
    
    if command -v rc-update &>/dev/null; then
        echo ""
        echo "开机自启:"
        if rc-update show 2>/dev/null | grep -q zbproxy; then
            echo -e "${GREEN}已启用${NC}"
        else
            echo -e "${YELLOW}未启用${NC}"
        fi
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}      ZBProxy 一键管理脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 安装 ZBProxy"
    echo -e "  ${GREEN}2.${NC} 更新 ZBProxy"
    echo -e "  ${GREEN}3.${NC} 卸载 ZBProxy"
    echo -e "  ${GREEN}4.${NC} 查看状态"
    echo -e "  ${GREEN}0.${NC} 退出"
    echo ""
    echo -e "${BLUE}=====================================${NC}"
}

# 主函数
main() {
    check_root
    check_dependencies
    
    while true; do
        show_menu
        read -p "请选择操作 [0-4]: " choice
        echo ""
        
        case $choice in
            1)
                install_zbproxy
                ;;
            2)
                update_zbproxy
                ;;
            3)
                uninstall_zbproxy
                ;;
            4)
                show_status
                ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                ;;
        esac
        
        echo ""
        read -p "按 Enter 键继续..."
    done
}

# 支持命令行参数
if [ $# -gt 0 ]; then
    case $1 in
        install)
            check_root
            check_dependencies
            install_zbproxy
            ;;
        update)
            check_root
            check_dependencies
            update_zbproxy
            ;;
        uninstall)
            check_root
            check_dependencies
            uninstall_zbproxy
            ;;
        status)
            check_root
            check_dependencies
            show_status
            ;;
        *)
            echo "用法: $0 {install|update|uninstall|status}"
            exit 1
            ;;
    esac
else
    main
fi