#!/usr/bin/env bash
set -Eeuo pipefail

# ===================== 配置参数 =====================
TAG="HTTP"
WORKDIR="/etc/tinyproxy"
CONF="/etc/tinyproxy/tinyproxy.conf"
PORT_FILE="$WORKDIR/port.txt"
SERVICE_NAME="tinyproxy"
SERVICE_FILE="/etc/systemd/system/tinyproxy.service"
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
        err "❌ 当前脚本仅支持 Debian / Ubuntu"
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

get_tinyproxy_bin() {
    if command -v tinyproxy >/dev/null 2>&1; then
        command -v tinyproxy
    elif [ -x /usr/sbin/tinyproxy ]; then
        echo "/usr/sbin/tinyproxy"
    elif [ -x /usr/bin/tinyproxy ]; then
        echo "/usr/bin/tinyproxy"
    else
        echo "/usr/sbin/tinyproxy"
    fi
}

disable_auto_start_during_apt() {
    cat > /usr/sbin/policy-rc.d <<'EOF_POLICY'
#!/bin/sh
exit 101
EOF_POLICY
    chmod +x /usr/sbin/policy-rc.d
}

enable_auto_start_after_apt() {
    rm -f /usr/sbin/policy-rc.d
}

install_dependencies() {
    msg "📦 正在安装 Tinyproxy 和依赖..."

    disable_auto_start_during_apt

    apt-get update -y

    # 修复可能存在的半安装状态
    apt-get install -f -y || true
    dpkg --configure -a || true

    apt-get install -y \
        tinyproxy \
        curl \
        ca-certificates \
        iproute2 \
        procps

    enable_auto_start_after_apt

    systemctl stop tinyproxy >/dev/null 2>&1 || true
    systemctl reset-failed tinyproxy >/dev/null 2>&1 || true
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

write_config() {
    local port="$1"

    mkdir -p "$WORKDIR"
    mkdir -p /var/log/tinyproxy
    mkdir -p /run/tinyproxy

    if id tinyproxy >/dev/null 2>&1; then
        chown -R tinyproxy:tinyproxy /var/log/tinyproxy /run/tinyproxy || true
    fi

    if [ -f "$CONF" ] && [ ! -f "$CONF.bak" ]; then
        cp -a "$CONF" "$CONF.bak" || true
    fi

    cat > "$CONF" <<EOF_CONF
# Tinyproxy HTTP 无认证代理配置
# 由管理脚本自动生成

User tinyproxy
Group tinyproxy

Port $port
Listen 0.0.0.0
Timeout 600

LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"

MaxClients 300
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0

ViaProxyName "tinyproxy"

ConnectPort 443
ConnectPort 563

# 无认证、开放来源
# 不写 Allow 即允许所有来源访问
EOF_CONF

    echo "$port" > "$PORT_FILE"
}

write_service() {
    local bin_path
    bin_path="$(get_tinyproxy_bin)"

    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Tinyproxy HTTP Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=${bin_path} -d -c ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

restart_service() {
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
}

stop_service() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
}

disable_service() {
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
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
        ss -lntp 2>/dev/null | grep -q ":${port} "
    else
        return 0
    fi
}

show_info() {
    if [ ! -f "$CONF" ] || [ ! -f "$PORT_FILE" ]; then
        warn "⚠️ 尚未安装或配置 HTTP 代理"
        return 1
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
    warn "⚠️ 如果是 NAT VPS，请确认该端口已在商家面板映射/放行。"
    warn "⚠️ 当前为无认证开放代理，请勿长期公网裸奔使用。"
    echo
}

install_proxy() {
    msg "🚀 开始安装 HTTP 无认证代理..."

    local port
    port="$(random_port)"

    install_dependencies
    write_config "$port"
    write_service
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

change_port_menu() {
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

    sed -i "s/^[[:space:]]*Port[[:space:]].*/Port ${new_port}/g" "$CONF"
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

change_port_auto() {
    local new_port="$1"

    if ! valid_port "$new_port"; then
        err "❌ 端口无效，请输入 1-65535 之间的数字"
        exit 1
    fi

    if [ ! -f "$CONF" ]; then
        err "❌ 尚未安装 HTTP 代理，请先安装"
        exit 1
    fi

    sed -i "s/^[[:space:]]*Port[[:space:]].*/Port ${new_port}/g" "$CONF"
    echo "$new_port" > "$PORT_FILE"

    allow_firewall_port "$new_port"

    if restart_service; then
        msg "✅ 端口已更改为 ${new_port}"
    else
        err "❌ 服务重启失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" --no-pager -n 80 || true
        exit 1
    fi

    show_info
}

uninstall_proxy() {
    msg "🧹 正在卸载 Tinyproxy HTTP 代理..."

    stop_service
    disable_service

    apt-get purge -y tinyproxy >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    rm -rf "$WORKDIR"
    rm -rf /var/log/tinyproxy
    rm -rf /run/tinyproxy

    msg "✅ 卸载完成"
}

menu_pause() {
    echo
    read -rp "按回车键继续..." _
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}==============================${NC}"
        echo -e "${GREEN} HTTP 无认证代理 管理菜单${NC}"
        echo -e "${BLUE}==============================${NC}"
        echo "1. 安装 HTTP 代理"
        echo "2. 查看信息"
        echo "3. 更改端口"
        echo "4. 卸载"
        echo "0. 退出"
        echo
        read -rp "选择: " choice

        case "$choice" in
            1)
                install_proxy
                menu_pause
                ;;
            2)
                show_info || true
                menu_pause
                ;;
            3)
                change_port_menu
                menu_pause
                ;;
            4)
                echo
                read -rp "确认卸载？输入 y 确认: " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    uninstall_proxy
                else
                    warn "已取消卸载"
                fi
                menu_pause
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

ACTION="${1:-menu}"

case "$ACTION" in
    menu)
        main_menu
        ;;
    install)
        install_proxy
        ;;
    info)
        show_info
        ;;
    port)
        if [ -z "${2:-}" ]; then
            err "❌ 用法: bash http.sh port 端口号"
            exit 1
        fi
        change_port_auto "$2"
        ;;
    uninstall)
        uninstall_proxy
        ;;
    *)
        err "❌ 未知参数: $ACTION"
        echo "用法:"
        echo "  bash http.sh              # 打开菜单"
        echo "  bash http.sh menu         # 打开菜单"
        echo "  bash http.sh install      # 直接安装"
        echo "  bash http.sh info         # 查看信息"
        echo "  bash http.sh port 12345   # 更改端口"
        echo "  bash http.sh uninstall    # 卸载"
        exit 1
        ;;
esac
