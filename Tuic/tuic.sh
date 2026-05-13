#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
WORK_DIR="/usr/local/tuic"
BIN="${WORK_DIR}/tuic-server"
CONF="${WORK_DIR}/config.json"        # 1.0.0 用 JSON 格式
SERVICE_NAME="tuic"
TUIC_VERSION="tuic-server-1.0.0"
TUIC_REPO="EAimTY/tuic"
TUIC_LIBC="unknown-linux-gnu"         # musl 版有 os error 92 bug
### =====================

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
NC='\033[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
else
    echo -e "${RED}❌ 不支持的系统${NC}"; exit 1
fi

# 重启服务
restart_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart ${SERVICE_NAME}
    else
        rc-service ${SERVICE_NAME} restart
    fi
}

# 确保 IPv6 socket 层可用（tuic 1.0.0 gnu 版需要）
ensure_ipv6() {
    local disabled
    disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
    if [ "$disabled" = "1" ]; then
        echo -e "${YELLOW}⚠️  IPv6 内核级别被禁用，正在临时开启（仅 socket 层）...${NC}"
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ IPv6 socket 已开启${NC}"
    fi
}

# 从 JSON 配置读取字段
get_conf_field() {
    if [ ! -f "$CONF" ]; then echo ""; return; fi
    case "$1" in
        port)     grep '"server"' "$CONF" | grep -oE '[0-9]{2,5}' | tail -1 ;;
        uuid)     grep -A1 '"users"' "$CONF" | grep -oE '"[0-9a-f-]{36}"' | tr -d '"' ;;
        password) grep -A1 '"users"' "$CONF" | grep -oE '": "[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"' ;;
    esac
}

# 显示配置信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ TUIC 未安装或配置文件不存在${NC}"; return
    fi
    PORT=$(get_conf_field port)
    UUID=$(get_conf_field uuid)
    PASS=$(get_conf_field password)
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    echo -e "\n${GREEN}========== TUIC 配置信息 ==========${NC}"
    echo -e "🌐 IPv4地址: ${YELLOW}${IP4:-不可用}${NC}"
    echo -e "🌐 IPv6地址: ${YELLOW}${IP6:-不可用}${NC}"
    echo -e "📌 UUID:     ${YELLOW}$UUID${NC}"
    echo -e "🔐 密码:     ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口:     ${YELLOW}$PORT${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv4):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V4${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V6${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}\n"
}

# 修改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 TUIC${NC}"; return
    fi
    read -p "请输入新端口 (10000-65535，回车随机): " NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    sed -i "s/\"server\": \"[^\"]*\"/\"server\": \"0.0.0.0:${NEW_PORT}\"/" "$CONF"
    restart_service
    show_info
}

# 安装
install_tuic() {
    # 安装依赖
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl bash openrc iproute2
    else
        apt update -y && apt install -y curl openssl iproute2
    fi

    # 架构判断
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        TUIC_ARCH="x86_64" ;;
        aarch64|arm64) TUIC_ARCH="aarch64" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    mkdir -p $WORK_DIR

    # 下载 tuic-server 1.0.0
    echo -e "${YELLOW}正在下载 tuic-server ${TUIC_VERSION}...${NC}"
    curl -L --retry 3 -o "$BIN" \
        "https://github.com/${TUIC_REPO}/releases/download/${TUIC_VERSION}/${TUIC_VERSION}-${TUIC_ARCH}-${TUIC_LIBC}"
    chmod +x "$BIN"

    # 验证二进制可执行
    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}❌ 二进制文件下载失败或不可执行（大小: $(wc -c < "$BIN") bytes）${NC}"
        exit 1
    fi

    PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 4)

    # 确保 IPv6 socket 可用
    ensure_ipv6

    # 生成 JSON 配置（1.0.0 版本格式）
    cat > "$CONF" <<EOF
{
    "server": "0.0.0.0:${PORT}",
    "users": {
        "${UUID}": "${PASS}"
    },
    "certificate": "${WORK_DIR}/cert.pem",
    "private_key": "${WORK_DIR}/key.pem",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "auth_timeout": "3s",
    "max_idle_time": "30s",
    "max_external_packet_size": 1500,
    "gc_interval": "3s",
    "gc_lifetime": "15s",
    "log_level": "warn"
}
EOF

    # 生成自签证书
    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WORK_DIR}/key.pem" \
        -out "${WORK_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" \
        -days 3650 -nodes 2>/dev/null

    # 注册系统服务
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=${BIN} -c ${CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
    else
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="TUIC Server"
command="${BIN}"
command_args="-c ${CONF}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/tuic.log"
error_log="/var/log/tuic.log"
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
        rc-update add ${SERVICE_NAME} default
    fi

    restart_service
    sleep 2

    # 检查启动结果
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            echo -e "${GREEN}✅ TUIC 服务启动成功${NC}"
        else
            echo -e "${RED}❌ TUIC 服务启动失败，错误日志：${NC}"
            journalctl -u ${SERVICE_NAME} -n 15 --no-pager
            exit 1
        fi
    else
        sleep 1
        if rc-service ${SERVICE_NAME} status 2>&1 | grep -q started; then
            echo -e "${GREEN}✅ TUIC 服务启动成功${NC}"
        else
            echo -e "${RED}❌ TUIC 服务启动失败，查看日志：cat /var/log/tuic.log${NC}"
            exit 1
        fi
    fi

    show_info
}

# 卸载
uninstall_tuic() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
    else
        rc-service ${SERVICE_NAME} stop 2>/dev/null || true
        rc-update del ${SERVICE_NAME} 2>/dev/null || true
        rm -f /etc/init.d/${SERVICE_NAME}
    fi
    rm -rf "$WORK_DIR"
    echo -e "${GREEN}✅ 已卸载${NC}"
}

# 菜单
clear
echo -e "${GREEN}TUIC 管理脚本${NC}"
echo "1. 安装 TUIC"
echo "2. 查看信息"
echo "3. 修改端口"
echo "4. 卸载"
read -p "选择: " choice
case $choice in
    1) install_tuic ;;
    2) show_info ;;
    3) change_port ;;
    4) uninstall_tuic ;;
    *) exit 0 ;;
esac
