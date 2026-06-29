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
SCRIPT_VERSION="1.4.0"

# GitHub 仓库信息
REPO_OWNER="Stoeaves"
REPO_NAME="ZBProxy"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases"

# 版本 URL（使用最新 Release）
V1_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/ZBProxy-linux-amd64-v1"
V3_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/ZBProxy-linux-amd64-v3"

# 版本信息文件路径
VERSION_FILE="/etc/zbproxy/version"
VERSION_TYPE_FILE="/etc/zbproxy/version_type"

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
    local deps=("wget" "rc-update" "rc-service" "curl")
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

# 获取最新 Release 版本号
get_latest_release_version() {
    local version=""
    
    # 尝试使用 curl 获取
    if command -v curl &>/dev/null; then
        version=$(curl -s "${GITHUB_API}/latest" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    fi
    
    # 如果 curl 失败，尝试使用 wget
    if [ -z "$version" ] && command -v wget &>/dev/null; then
        version=$(wget -qO- "${GITHUB_API}/latest" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    fi
    
    # 如果还是获取不到，尝试从 release 列表获取
    if [ -z "$version" ]; then
        if command -v curl &>/dev/null; then
            version=$(curl -s "${GITHUB_API}" | grep -o '"tag_name": "[^"]*' | head -1 | cut -d'"' -f4)
        elif command -v wget &>/dev/null; then
            version=$(wget -qO- "${GITHUB_API}" | grep -o '"tag_name": "[^"]*' | head -1 | cut -d'"' -f4)
        fi
    fi
    
    # 如果还是获取不到，使用默认值
    if [ -z "$version" ]; then
        echo -e "${YELLOW}无法获取最新版本号，使用默认值 v0.1.1${NC}"
        version="v0.1.1"
    fi
    
    echo "$version"
}

# 获取当前安装的版本号（从文件读取）
get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "v1.0.0"
    fi
}

# 获取当前安装的版本类型（从文件读取）
get_current_version_type() {
    if [ -f "$VERSION_TYPE_FILE" ]; then
        cat "$VERSION_TYPE_FILE"
    else
        # 如果类型文件不存在，通过文件大小判断
        if [ -f "/usr/local/bin/zbproxy" ]; then
            local file_size
            file_size=$(stat -c%s "/usr/local/bin/zbproxy" 2>/dev/null || echo "0")
            if [ "$file_size" -gt 8000000 ]; then
                echo "v3"
            else
                echo "v1"
            fi
        else
            echo "not_installed"
        fi
    fi
}

# 保存版本信息
save_version_info() {
    local version=$1
    local version_type=$2
    
    # 创建配置目录
    mkdir -p /etc/zbproxy
    
    # 保存版本号
    echo "$version" > "$VERSION_FILE"
    
    # 保存版本类型
    echo "$version_type" > "$VERSION_TYPE_FILE"
    
    echo -e "${GREEN}版本信息已保存: $version_type ($version)${NC}"
}

# 下载并安装指定版本
download_and_install() {
    local version=$1
    local url=$2
    
    echo -e "${BLUE}正在下载 ZBProxy $version...${NC}"
    
    # 下载
    if ! wget -q --show-progress -O /usr/local/bin/zbproxy "$url"; then
        echo -e "${RED}下载失败，请检查网络连接${NC}"
        return 1
    fi
    
    # 添加执行权限
    chmod +x /usr/local/bin/zbproxy
    
    INSTALLED_VERSION="$version"
    return 0
}

# 测试服务是否能正常启动
test_service() {
    echo "正在测试服务启动..."
    
    # 先停止可能存在的服务
    rc-service zbproxy stop 2>/dev/null || true
    
    # 清理 PID 文件
    rm -f /run/zbproxy.pid
    
    # 尝试启动服务
    if rc-service zbproxy start 2>/dev/null; then
        # 等待几秒让服务完全启动
        sleep 2
        
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

start_pre() {
    # 清理旧的 PID 文件
    rm -f /run/${name}.pid
}
EOF
    
    chmod +x /etc/init.d/zbproxy
}

# 安装 ZBProxy
install_zbproxy() {
    echo -e "${BLUE}开始安装 ZBProxy...${NC}"
    
    # 获取最新版本号
    LATEST_VERSION=$(get_latest_release_version)
    echo -e "${GREEN}最新 Release 版本: $LATEST_VERSION${NC}"
    echo ""
    
    # 检查是否已安装
    if [ -f "/usr/local/bin/zbproxy" ]; then
        echo -e "${YELLOW}检测到已安装 ZBProxy${NC}"
        CURRENT_VERSION=$(get_current_version)
        CURRENT_TYPE=$(get_current_version_type)
        echo -e "当前版本: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "当前类型: ${YELLOW}$CURRENT_TYPE${NC}"
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
    local current_version_type=""
    
    case $version_choice in
        1)
            echo -e "${BLUE}选择安装 v1 版本${NC}"
            if download_and_install "v1" "$V1_URL"; then
                create_service_script
                if test_service; then
                    install_success=true
                    current_version_type="v1"
                    current_version="$LATEST_VERSION"
                else
                    echo -e "${RED}服务启动失败，安装失败${NC}"
                    rm -f /usr/local/bin/zbproxy
                    rm -f /etc/init.d/zbproxy
                fi
            fi
            ;;
        2)
            echo -e "${BLUE}选择安装 v3 版本${NC}"
            if download_and_install "v3" "$V3_URL"; then
                create_service_script
                if test_service; then
                    install_success=true
                    current_version_type="v3"
                    current_version="$LATEST_VERSION"
                else
                    echo -e "${RED}服务启动失败，安装失败${NC}"
                    rm -f /usr/local/bin/zbproxy
                    rm -f /etc/init.d/zbproxy
                fi
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
                    current_version_type="v3"
                    current_version="$LATEST_VERSION"
                    echo -e "${GREEN}✓ v3 版本安装并测试成功！${NC}"
                else
                    echo -e "${YELLOW}⚠ v3 版本启动失败，尝试回退到 v1...${NC}"
                    # 清理失败的文件
                    rm -f /usr/local/bin/zbproxy
                    rm -f /etc/init.d/zbproxy
                    rm -f /run/zbproxy.pid
                    
                    # 尝试安装 v1
                    echo -e "${YELLOW}尝试安装 v1 版本...${NC}"
                    if download_and_install "v1" "$V1_URL"; then
                        # 重新创建服务脚本
                        create_service_script
                        
                        # 测试 v1
                        echo "测试 v1 版本..."
                        if test_service; then
                            install_success=true
                            current_version_type="v1"
                            current_version="$LATEST_VERSION"
                            echo -e "${GREEN}✓ v1 版本安装并测试成功！${NC}"
                        else
                            echo -e "${RED}✗ v1 版本也无法启动，安装失败${NC}"
                            rm -f /usr/local/bin/zbproxy
                            rm -f /etc/init.d/zbproxy
                            rm -f /run/zbproxy.pid
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
                        current_version_type="v1"
                        current_version="$LATEST_VERSION"
                        echo -e "${GREEN}✓ v1 版本安装并测试成功！${NC}"
                    else
                        echo -e "${RED}✗ v1 版本也无法启动，安装失败${NC}"
                        rm -f /usr/local/bin/zbproxy
                        rm -f /etc/init.d/zbproxy
                        rm -f /run/zbproxy.pid
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
    
    if [ "$install_success" = true ]; then
        # 保存版本信息
        save_version_info "$current_version" "$current_version_type"
        
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
        
        echo -e "${GREEN}ZBProxy 安装完成！${NC}"
        echo -e "安装版本: ${GREEN}$current_version${NC}"
        echo -e "版本类型: ${GREEN}$current_version_type${NC}"
        return 0
    else
        echo -e "${RED}ZBProxy 安装失败！${NC}"
        return 1
    fi
}

# 更新 ZBProxy
update_zbproxy() {
    echo -e "${BLUE}开始更新 ZBProxy...${NC}"
    
    # 获取最新版本号
    LATEST_VERSION=$(get_latest_release_version)
    echo -e "${GREEN}最新 Release 版本: $LATEST_VERSION${NC}"
    echo ""
    
    # 检查是否已安装
    if [ ! -f "/usr/local/bin/zbproxy" ]; then
        echo -e "${RED}未检测到已安装的 ZBProxy，请先安装${NC}"
        return 1
    fi
    
    CURRENT_VERSION=$(get_current_version)
    CURRENT_TYPE=$(get_current_version_type)
    echo -e "当前版本: ${YELLOW}$CURRENT_VERSION${NC}"
    echo -e "当前类型: ${YELLOW}$CURRENT_TYPE${NC}"
    
    # 检查是否有新版本
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        echo -e "${GREEN}已是最新版本！${NC}"
        read -p "是否强制重新安装? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    else
        echo -e "${YELLOW}发现新版本: $LATEST_VERSION${NC}"
    fi
    
    # 选择更新版本
    echo ""
    echo -e "${BLUE}请选择要更新到的版本:${NC}"
    echo -e "  ${GREEN}1.${NC} v1 (兼容性更好，适合旧系统)"
    echo -e "  ${GREEN}2.${NC} v3 (功能更新，性能更好)"
    echo -e "  ${GREEN}3.${NC} 保持当前版本 ($CURRENT_TYPE)"
    echo ""
    read -p "请选择 [1-3]: " version_choice
    
    local target_version=""
    local target_url=""
    local target_type=""
    
    case $version_choice in
        1)
            target_version="$LATEST_VERSION"
            target_url="$V1_URL"
            target_type="v1"
            ;;
        2)
            target_version="$LATEST_VERSION"
            target_url="$V3_URL"
            target_type="v3"
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
    
    if [ "$target_type" = "$CURRENT_TYPE" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}已是最新版本，无需更新${NC}"
        return 0
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
    echo "正在下载 $target_type (Release: $target_version)..."
    if ! wget -q --show-progress -O /usr/local/bin/zbproxy "$target_url"; then
        echo -e "${RED}下载失败，正在恢复备份...${NC}"
        [ -f "/usr/local/bin/zbproxy.bak" ] && mv /usr/local/bin/zbproxy.bak /usr/local/bin/zbproxy
        return 1
    fi
    
    chmod +x /usr/local/bin/zbproxy
    
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
    
    # 更新版本信息
    save_version_info "$target_version" "$target_type"
    
    echo -e "${GREEN}ZBProxy 更新完成！${NC}"
    echo -e "当前版本: ${GREEN}$target_version${NC}"
    echo -e "版本类型: ${GREEN}$target_type${NC}"
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
    
    # 删除版本信息文件
    if [ -f "$VERSION_FILE" ] || [ -f "$VERSION_TYPE_FILE" ]; then
        read -p "是否删除版本信息文件? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$VERSION_FILE" "$VERSION_TYPE_FILE"
            echo "版本信息文件已删除"
            
            # 如果目录为空，也删除目录
            if [ -d "/etc/zbproxy" ] && [ -z "$(ls -A /etc/zbproxy 2>/dev/null)" ]; then
                rmdir /etc/zbproxy 2>/dev/null || true
                echo "配置目录已删除"
            fi
        else
            echo "保留版本信息文件"
        fi
    fi
    
    echo -e "${GREEN}ZBProxy 卸载完成！${NC}"
    
    # 显示残留检查
    echo ""
    echo -e "${YELLOW}===== 残留检查 =====${NC}"
    local has_remains=false
    for file in "/usr/local/bin/zbproxy" "/etc/init.d/zbproxy" "/run/zbproxy.pid" "$VERSION_FILE" "$VERSION_TYPE_FILE"; do
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
    
    # 获取最新 Release 版本
    LATEST_VERSION=$(get_latest_release_version)
    
    if [ -f "/usr/local/bin/zbproxy" ]; then
        echo -e "状态: ${GREEN}已安装${NC}"
        
        CURRENT_VERSION=$(get_current_version)
        CURRENT_TYPE=$(get_current_version_type)
        
        echo -e "当前版本: ${GREEN}$CURRENT_VERSION${NC}"
        echo -e "版本类型: ${GREEN}$CURRENT_TYPE${NC}"
        echo "文件大小: $(du -h /usr/local/bin/zbproxy | cut -f1)"
        
        # 检查是否有更新
        if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ] && [ "$CURRENT_VERSION" != "v1.0.0" ]; then
            echo -e "${YELLOW}有新版本可用: $LATEST_VERSION${NC}"
        fi
    else
        echo -e "状态: ${RED}未安装${NC}"
    fi
    
    echo ""
    echo -e "最新 Release 版本: ${GREEN}$LATEST_VERSION${NC}"
    
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
