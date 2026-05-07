#!/usr/bin/env bash

set -Eeuo pipefail

# ===================== 配置参数 =====================
TAG="HTTP"
WORKDIR="/etc/3proxy"
CONF="$WORKDIR/3proxy.cfg"
PORT_FILE="$WORKDIR/port.txt"
BIN="/usr/local/bin/3proxy"
SRC_DIR="/usr/local/src/3proxy"
SERVICE_NAME="3proxy"
# ====================================================

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
    if command -v apk >/dev/null 2>&1; then
        OS="alpine"
    elif command -v apt >/dev/null 2>&1; then
        OS="debian"
    else
        err "❌ 暂不支持当前系统，仅支持 Debian/Ubuntu/Alpine"
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

get_bin_path() {
    if command -v 3proxy >/dev/null 2>&1; then
        command -v 3proxy
        return
    fi

    if [ -x "/usr/local/bin/3proxy" ]; then
        echo "/usr/local/bin/3proxy"
        return
    fi

    if [ -x "/usr/bin/3proxy" ]; then
        echo "/usr/bin/3proxy"
        return
    fi

    echo "$BIN"
}

install_dependencies() {
    msg "📦 正在安装依赖..."

    if [ "$OS" = "alpine" ]; then
        apk update
        apk add --no-cache bash curl git make gcc musl-dev build-base openrc
    else
        apt update
        apt install -y curl bash git make gcc build-essential ca-certificates
    fi
}

install_3proxy_by_package() {
    msg "📦 尝试使用系统包管理器安装 3proxy..."

    if [ "$OS" = "alpine" ]; then
        if apk add --no-cache 3proxy; then
            return 0
        else
            return 1
        fi
    else
        if apt install -y 3proxy; then
            return 0
        else
            return 1
        fi
    fi
}

install_3proxy_by_source() {
    warn "⚠️ 系统源中没有可用的 3proxy，开始源码编译安装..."

    rm -rf "$SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"

    git clone https://github.com/3proxy/3proxy.git "$SRC_DIR"

    cd "$SRC_DIR"

    ln -sf Makefile.Linux Makefile
    make

    mkdir -p /usr/local/bin

    if [ -f "$SRC_DIR/bin/3proxy" ]; then
        install -m 755 "$SRC_DIR/bin/3proxy" "$BIN"
    elif [ -f "$SRC_DIR/src/3proxy" ]; then
        install -m 755 "$SRC_DIR/src/3proxy" "$BIN"
    else
        err "❌ 编译完成后未找到 3proxy 可执行文件"
        exit 1
    fi

    msg "✅ 源码编译安装完成：$BIN"
}

install_3proxy() {
    if command -v 3proxy >/dev/null 2>&1 || [ -x "$BIN" ]; then
        msg "✅ 检测到 3proxy 已安装"
        BIN="$(get_bin_path)"
        return
    fi

    install_dependencies

    if install_3proxy_by_package; then
        BIN="$(get_bin_path)"
        msg "✅ 3proxy 已通过系统包管理器安装：$BIN"
    else
        install_3proxy_by_source
        BIN="$(get_bin_path)"
    fi
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

create_config() {
    local port="$1"

    mkdir -p "$WORKDIR"

    cat > "$CONF" <<EOF
# 3proxy HTTP 无认证代理配置
# 由管理脚本自动生成

nscache 65536
nscache6 65536

timeouts 1 5 30 60 180 1800 15 60

log /var/log/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

maxconn 300

auth none
allow *

proxy -n -a -p$port
EOF

    echo "$port" > "$PORT_FILE"
}

create_service() {
    BIN="$(get_bin_path)"

    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/3proxy <<EOF
#!/sbin/openrc-run

name="3proxy"
description="3proxy HTTP Proxy Server"

command="$BIN"
command_args="$CONF"
command_background="yes"
pidfile="/run/3proxy.pid"

depend() {
    need net
    after firewall
}
EOF

        chmod +x /etc/init.d/3proxy
        rc-update add 3proxy default >/dev/null 2>&1 || true

    else
        cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy HTTP Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=$BIN $CONF
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable 3proxy >/dev/null 2>&1 || true
    fi
}

restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service 3proxy restart || rc-service 3proxy start
    else
        systemctl daemon-reload
        systemctl restart 3proxy
    fi
}

stop_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service 3proxy stop >/dev/null 2>&1 || true
    else
        systemctl stop 3proxy >/dev/null 2>&1 || true
    fi
}

disable_service() {
    if [ "$OS" = "alpine" ]; then
        rc-update del 3proxy default >/dev/null 2>&1 || true
        rm -f /etc/init.d/3proxy
    else
        systemctl disable 3proxy >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/3proxy.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

service_status() {
    if [ "$OS" = "alpine" ]; then
        rc-service 3proxy status >/dev/null 2>&1 && echo "运行中" || echo "未运行"
    else
        systemctl is-active --quiet 3proxy && echo "运行中" || echo "未运行"
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
    echo -e "📦 服务状态: ${GREEN}${status}${NC}"
    echo -e "🎲 监听端口: ${GREEN}${port}${NC}"
    echo -e "🔓 认证方式: ${YELLOW}无认证${NC}"
    echo -e "📄 配置文件: ${CONF}"
    echo -e "⚙️ 程序路径: $(get_bin_path)"

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
    warn "⚠️ 如果你是 NAT VPS，请确认该端口已经在商家面板映射/放行。"
    warn "⚠️ 当前为无认证代理，请勿长期公网裸奔使用。"
    echo
}

install_proxy() {
    clear
    msg "🚀 开始安装 HTTP 无认证代理..."

    install_3proxy

    echo
    read -rp "请输入监听端口，回车随机 10000-65535: " port

    if [ -z "$port" ]; then
        port="$(random_port)"
    fi

    if ! valid_port "$port"; then
        err "❌ 端口无效，请输入 1-65535 之间的数字"
        exit 1
    fi

    create_config "$port"
    create_service
    allow_firewall_port "$port"
    restart_service

    msg "✅ HTTP 代理安装完成"
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

    sed -i "s/proxy -n -a -p${old_port}/proxy -n -a -p${new_port}/g" "$CONF"

    if ! grep -q "proxy -n -a -p${new_port}" "$CONF"; then
        sed -i "s/^proxy .*/proxy -n -a -p${new_port}/g" "$CONF"
    fi

    echo "$new_port" > "$PORT_FILE"

    allow_firewall_port "$new_port"
    restart_service

    msg "✅ 端口已从 ${old_port} 更改为 ${new_port}"
    show_info
}

uninstall_proxy() {
    echo
    warn "⚠️ 即将卸载 3proxy HTTP 代理"
    read -rp "确认卸载？输入 y 确认: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        warn "已取消卸载"
        return
    fi

    stop_service
    disable_service

    rm -rf "$WORKDIR"
    rm -f /var/log/3proxy.log

    if [ -x "$BIN" ]; then
        rm -f "$BIN"
    fi

    if [ -d "$SRC_DIR" ]; then
        rm -rf "$SRC_DIR"
    fi

    if [ "$OS" = "debian" ]; then
        apt purge -y 3proxy >/dev/null 2>&1 || true
        apt autoremove -y >/dev/null 2>&1 || true
    elif [ "$OS" = "alpine" ]; then
        apk del 3proxy >/dev/null 2>&1 || true
    fi

    msg "✅ 卸载完成"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${GREEN} HTTP 无认证代理 管理脚本${NC}"
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
