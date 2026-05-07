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

msg(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){ echo -e "${RED}$*${NC}"; }

check_root() {
    [[ "$(id -u)" -eq 0 ]] || { err "❌ 请使用 root 用户运行"; exit 1; }
}

detect_os() {
    command -v apt-get >/dev/null 2>&1 || {
        err "❌ 当前脚本仅支持 Debian / Ubuntu"
        exit 1
    }
}

random_port() {
    shuf -i 10000-65535 -n 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

install_dependencies() {
    msg "📦 正在安装 Tinyproxy 和依赖..."
    apt-get update -y
    apt-get install -y tinyproxy curl ca-certificates iproute2 procps
}

allow_firewall_port() {
    local port="$1"
    command -v ufw >/dev/null 2>&1 && ufw allow "$port"/tcp >/dev/null 2>&1 || true
}

write_config() {
    local port="$1"
    mkdir -p "$WORKDIR" /var/log/tinyproxy

    cat > "$CONF" <<EOF
User tinyproxy
Group tinyproxy
Port $port
Timeout 600
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 300
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 563
EOF

    echo "$port" > "$PORT_FILE"
}

restart_service() {
    systemctl daemon-reload
    systemctl enable tinyproxy >/dev/null 2>&1 || true
    systemctl restart tinyproxy
}

service_status() {
    systemctl is-active --quiet tinyproxy && echo "运行中" || echo "未运行"
}

get_ipv4() {
    curl -s4 --connect-timeout 5 https://api.ipify.org || true
}

show_info() {
    [[ -f "$PORT_FILE" ]] || { warn "⚠️ 尚未安装"; return; }

    local port ip status
    port=$(cat "$PORT_FILE")
    ip=$(get_ipv4)
    status=$(service_status)

    echo
    echo -e "${BLUE}========== HTTP 代理信息 ==========${NC}"
    echo "📦 程序: Tinyproxy"
    echo "📦 状态: $status"
    echo "🎲 端口: $port"
    echo "🔓 认证: 无"
    echo
    echo "📎 代理地址:"
    echo "http://${ip}:${port}"
    echo "节点: ${TAG}_V4 → ${ip}:${port}"
    echo
}

install_proxy() {
    local port
    port=$(random_port)

    install_dependencies
    write_config "$port"
    allow_firewall_port "$port"
    restart_service

    msg "✅ HTTP 代理安装完成"
    show_info
}

change_port_menu() {
    read -rp "请输入新端口（回车随机）: " port
    [[ -z "$port" ]] && port=$(random_port)

    valid_port "$port" || { err "端口无效"; return; }

    sed -i "s/^Port .*/Port $port/" "$CONF"
    echo "$port" > "$PORT_FILE"
    restart_service
    show_info
}

uninstall_proxy() {
    systemctl stop tinyproxy || true
    apt-get purge -y tinyproxy
    rm -rf "$WORKDIR" /var/log/tinyproxy
    msg "✅ 已卸载"
}

menu() {
    while true; do
        clear
        echo "=============================="
        echo " HTTP 无认证代理 管理菜单"
        echo "=============================="
        echo "1. 安装 HTTP 代理"
        echo "2. 查看信息"
        echo "3. 更改端口"
        echo "4. 卸载"
        echo "0. 退出"
        read -rp "选择: " c

        case "$c" in
            1) install_proxy ;;
            2) show_info ;;
            3) change_port_menu ;;
            4) uninstall_proxy ;;
            0) exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
        read -rp "按回车继续..." _
    done
}

check_root
detect_os

# ✅ 核心修复点：默认进入菜单
ACTION="${1:-menu}"

case "$ACTION" in
    menu) menu ;;
    install) install_proxy ;;
    info) show_info ;;
    uninstall) uninstall_proxy ;;
    *) err "未知参数";;
esac
