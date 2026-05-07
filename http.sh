cat > ~/http_proxy.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

# ===================== 配置参数 =====================
TAG="HTTP"
WORKDIR="/etc/tinyproxy"
CONF="/etc/tinyproxy/tinyproxy.conf"
PORT_FILE="$WORKDIR/port.txt"
SERVICE_NAME="tinyproxy"
# ====================================================

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

msg() {
    echo -e "${GREEN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}$*${NC}"
}

err() {
    echo -e "${RED}$*${NC}"
}

pause() {
    echo
    read -rp "按回车键继续..." _
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "❌ 请使用 root 用户运行"
        exit 1
    fi
}

detect_os() {
    if command -v apt-get >/dev/null 2>&1; then
        OS="debian"
    else
        err "❌ 当前脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
}

random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-65535 -n 1
    else
        echo $((RANDOM % 55535 + 10000))
    fi
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

install_dependencies() {
    msg "📦 正在自动安装 Tinyproxy 和依赖..."

    apt-get update -y
    apt-get install -y \
        tinyproxy \
        curl \
        ca-certificates \
        iproute2 \
        procps
}

allow_firewall_port() {
    local port="$1"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

backup_config() {
    mkdir -p "$WORKDIR"

    if [ -f "$CONF" ] && [ ! -f "$CONF.bak" ]; then
        cp -a "$CONF" "$CONF.bak"
    fi
}

write_config() {
    local port="$1"

    mkdir -p "$WORKDIR"

    cat > "$CONF" <<EOF2
# Tinyproxy HTTP 无认证代理配置
# 由管理脚本自动生成

User tinyproxy
Group tinyproxy

Port $port
Timeout 600

DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"

LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info

PidFile "/run/tinyproxy/tinyproxy.pid"

MaxClients 300
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0

ViaProxyName "tinyproxy"

# 允许 HTTPS CONNECT
ConnectPort 443
ConnectPort 563

# 无认证、无限制来源
# 注意：这里没有 Allow 限制，代表允许任意来源连接。
EOF2

    echo "$port" > "$PORT_FILE"
}

restart_service() {
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
}

stop_service() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
}

disable_service() {
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

service_status() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

get_ipv4() {
    curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null \
        || curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null \
        || curl -s4 --connect-timeout 5 https://ip.sb 2>/dev/null \
        || true
}

get_ipv6() {
    curl -s6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null \
        || curl -s6 --connect-timeout 5 https://ifconfig.me 2>/dev/null \
        || curl -s6 --connect-timeout 5 https://ip.sb 2>/dev/null \
        || true
}

check_listen_port() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
    else
        return 0
    fi
}

show_info() {
    if [ ! -f "$CONF" ] || [ ! -f "$PORT_FILE" ]; then
        warn "⚠️ 尚未安装或配置 HTTP 代理"
        return
    fi

    local port
    local ip4
    local ip6
    local status

    port="$(cat "$PORT_FILE")"
    ip4="$(get_ipv4)"
    ip6="$(get_ipv6)"
    status="$(service_status)"

    echo
    echo -e "${BLUE}========== HTTP 代理配置信息 ==========${NC}"
    echo -e "📦 代理程序: ${GREEN}Tinyproxy${NC}"
    echo -e "📦 服务状态: ${GREEN}${status}${NC}"
    echo -e "🎲 监听端口: ${GREEN}${port}${NC}"
    echo -e "🔓 认证方式: ${YELLOW}无认证${NC}"
    echo -e "📄 配置文件: ${CONF}"

    if check_listen_port "$port"; then
        echo -e "👂 端口监听: ${GREEN}正常${NC}"
    else
        echo -e "👂 端口监听: ${RED}未检测到，请检查服务状态${NC}"
    fi

    if [ -n "$ip4" ]; then
        echo
        echo -e "${GREEN}📎 IPv4 代理地址:${NC}"
        echo "http://${ip4}:${port}"
        echo "节点: ${TAG}_V4 → ${ip4}:${port}"
    fi

    if [ -n "$ip6" ]; then
        echo
        echo -e "${GREEN}📎 IPv6 代理地址:${NC}"
        echo "http://[${ip6}]:${port}"
        echo "节点: ${TAG}_V6 → [${ip6}]:${port}"
    fi

    echo
    warn "⚠️ 如果你是 NAT VPS，请确认该端口已在商家面板映射/放行。"
    warn "⚠️ 当前为无认证开放代理，请勿长期公网裸奔使用。"
    echo
}

install_proxy() {
    clear
    msg "🚀 开始一键安装 HTTP 无认证代理..."

    local port
    port="$(random_port)"

    install_dependencies
    backup_config
    write_config "$port"
    allow_firewall_port "$port"

    if restart_service; then
        msg "✅ HTTP 代理安装完成"
    else
        err "❌ 服务启动失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" --no-pager -n 80 || true
        exit 1
    fi

    show_info
}

change_port() {
    if [ ! -f "$CONF" ] || [ ! -f "$PORT_FILE" ]; then
        warn "⚠️ 尚未安装 HTTP 代理"
        return
    fi

    local old_port
    local new_port

    old_port="$(cat "$PORT_FILE")"

    echo
    read -rp "请输入新端口，回车随机 10000-65535: " new_port

    if [ -z "$new_port" ]; then
        new_port="$(random_port)"
    fi

    if ! valid_port "$new_port"; then
        err "❌ 端口无效，请输入 1-65535 之间的数字"
        return
    fi

    if grep -qE '^[[:space:]]*Port[[:space:]]+' "$CONF"; then
        sed -i "s/^[[:space:]]*Port[[:space:]].*/Port ${new_port}/g" "$CONF"
    else
        echo "Port ${new_port}" >> "$CONF"
    fi

    echo "$new_port" > "$PORT_FILE"
    allow_firewall_port "$new_port"

    if restart_service; then
        msg "✅ 端口已从 ${old_port} 更改为 ${new_port}"
    else
        err "❌ 服务重启失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" --no-pager -n 80 || true
        return
    fi

    show_info
}

uninstall_proxy() {
    echo
    warn "⚠️ 即将卸载 Tinyproxy HTTP 代理"
    read -rp "确认卸载？输入 y 确认: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        warn "已取消卸载"
        return
    fi

    stop_service
    disable_service

    apt-get purge -y tinyproxy >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    rm -rf "$WORKDIR"
    rm -rf /var/log/tinyproxy

    msg "✅ 卸载完成"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${GREEN} HTTP 无认证代理 管理脚本 - Tinyproxy版${NC}"
        echo -e "${BLUE}=====================================${NC}"
        echo "1. 安装 HTTP代理"
        echo "2. 查看信息"
        echo "3. 更改端口"
        echo "4. 卸载"
        echo "0. 退出"
        echo
        read -rp "选择: " choice

        case "$choice" in
            1)
                install_proxy
                pause
                ;;
            2)
                show_info
                pause
                ;;
            3)
                change_port
                pause
                ;;
            4)
                uninstall_proxy
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选择"
                sleep 1
                ;;
        esac
    done
}

check_root
detect_os
main_menu
EOF

chmod +x ~/http_proxy.sh
