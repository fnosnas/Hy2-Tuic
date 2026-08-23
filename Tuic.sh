#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
WORK_DIR="/usr/local/tuic"
BIN="${WORK_DIR}/tuic-server"
CONF="${WORK_DIR}/config.yaml"
SHA256_FILE="${WORK_DIR}/sha256.txt"
SERVICE_NAME="tuic"
TUIC_REPO="Itsusinn/tuic"
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

# 检测 IPv6 是否可用
ipv6_available() {
    local disabled
    disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    [ "$disabled" = "0" ] && return 0
    return 1
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ TUIC 未安装或配置文件不存在${NC}"; return
    fi
    PORT=$(grep "server:" "$CONF" | grep -oE '[0-9]{4,5}' | head -1)
    UUID=$(grep -A 1 "users:" "$CONF" | tail -n 1 | awk -F'"' '{print $2}')
    PASS=$(grep -A 1 "users:" "$CONF" | tail -n 1 | awk -F'"' '{print $4}')
    SHA256=""
    [ -f "$SHA256_FILE" ] && SHA256=$(cat "$SHA256_FILE")
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    echo -e "\n${GREEN}========== TUIC 配置信息 ==========${NC}"
    echo -e "🌐 IPv4地址:   ${YELLOW}${IP4:-不可用}${NC}"
    echo -e "🌐 IPv6地址:   ${YELLOW}${IP6:-不可用}${NC}"
    echo -e "📌 UUID:       ${YELLOW}$UUID${NC}"
    echo -e "🔐 密码:       ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口:       ${YELLOW}$PORT${NC}"
    [ -n "$SHA256" ] && echo -e "🔏 证书SHA256: ${YELLOW}$SHA256${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 IPv4 (跳过验证):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V4${NC}"
        if [[ -n "$SHA256" ]]; then
            echo -e "${GREEN}📎 TUIC 节点链接 IPv4 (SHA256校验):${NC}"
            echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&pinSHA256=$SHA256&sni=www.bing.com#TUIC_V4_SHA256${NC}"
        fi
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 IPv6 (跳过验证):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V6${NC}"
        if [[ -n "$SHA256" ]]; then
            echo -e "${GREEN}📎 TUIC 节点链接 IPv6 (SHA256校验):${NC}"
            echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&pinSHA256=$SHA256&sni=www.bing.com#TUIC_V6_SHA256${NC}"
        fi
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
    sed -i "s/\(server:.*:\)[0-9]\{1,5\}\"/\1${NEW_PORT}\"/" "$CONF"
    restart_service
    show_info
}

# 安装
install_tuic() {
    # 安装依赖
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl bash openrc
    else
        apt update -y && apt install -y curl openssl
    fi

    # 架构判断
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        TUIC_ARCH="x86_64"  ;;
        aarch64|arm64) TUIC_ARCH="aarch64" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    mkdir -p "$WORK_DIR"

    # 获取最新版本号
    echo -e "${YELLOW}正在获取最新版本...${NC}"
    LATEST=$(curl -s "https://api.github.com/repos/${TUIC_REPO}/releases/latest" \
        | grep '"tag_name"' | cut -d'"' -f4)
    if [ -z "$LATEST" ]; then
        LATEST="v1.8.1"
        echo -e "${YELLOW}⚠️  无法获取最新版本，使用 $LATEST${NC}"
    fi
    echo -e "${GREEN}版本: $LATEST${NC}"

    # 下载二进制
    echo -e "${YELLOW}正在下载 tuic-server ${LATEST}...${NC}"
    curl -L --retry 3 -o "$BIN" \
        "https://github.com/${TUIC_REPO}/releases/download/${LATEST}/tuic-server-${TUIC_ARCH}-linux-musl"
    chmod +x "$BIN"

    # 验证
    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}❌ 二进制文件不可执行（大小: $(wc -c < "$BIN") bytes）${NC}"
        exit 1
    fi

    PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 4)

    # 根据 IPv6 可用性决定 dual_stack
    if ipv6_available; then
        DUAL_STACK="true"
        LISTEN="[::]:${PORT}"
        echo -e "${GREEN}✅ IPv6 可用，启用双栈监听${NC}"
    else
        DUAL_STACK="false"
        LISTEN="0.0.0.0:${PORT}"
        echo -e "${YELLOW}⚠️  IPv6 不可用，使用纯 IPv4 监听${NC}"
    fi

    # 生成自签证书
    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WORK_DIR}/key.pem" \
        -out    "${WORK_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" \
        -days 3650 -nodes 2>/dev/null

    # 提取 SHA256 指纹（去冒号、转小写）
    SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${WORK_DIR}/cert.pem" 2>/dev/null \
             | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
    echo "$SHA256" > "$SHA256_FILE"

    # 生成 YAML 配置
    {
        echo "server: \"${LISTEN}\""
        echo "users:"
        echo "  \"${UUID}\": \"${PASS}\""
        echo "congestion_control: \"bbr\""
        echo "auth_timeout: \"3s\""
        echo "zero_rtt_handshake: false"
        echo "dual_stack: ${DUAL_STACK}"
        echo "tls:"
        echo "  certificate: \"${WORK_DIR}/cert.pem\""
        echo "  private_key: \"${WORK_DIR}/key.pem\""
        echo "  alpn:"
        echo "    - \"h3\""
    } > "$CONF"

    # 注册服务
    if command -v systemctl >/dev/null 2>&1; then
        {
            echo "[Unit]"
            echo "Description=TUIC Server"
            echo "After=network.target"
            echo ""
            echo "[Service]"
            echo "ExecStart=${BIN} -c ${CONF}"
            echo "Restart=on-failure"
            echo "RestartSec=5s"
            echo "LimitNOFILE=65536"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } > /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
    else
        {
            echo "#!/sbin/openrc-run"
            echo "description=\"TUIC Server\""
            echo "command=\"${BIN}\""
            echo "command_args=\"-c ${CONF}\""
            echo "command_background=true"
            echo "pidfile=\"/run/\${RC_SVCNAME}.pid\""
            echo "output_log=\"/var/log/tuic.log\""
            echo "error_log=\"/var/log/tuic.log\""
        } > /etc/init.d/${SERVICE_NAME}
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
        systemctl stop    ${SERVICE_NAME} 2>/dev/null || true
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
    else
        rc-service ${SERVICE_NAME} stop 2>/dev/null || true
        rc-update del ${SERVICE_NAME}   2>/dev/null || true
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
    1) install_tuic   ;;
    2) show_info      ;;
    3) change_port    ;;
    4) uninstall_tuic ;;
    *) exit 0         ;;
esac
