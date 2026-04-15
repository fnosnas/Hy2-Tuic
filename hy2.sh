#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.yaml"
PORT_FILE="$WORKDIR/port.txt"
PASS_FILE="$WORKDIR/password.txt"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"
    exit 1
fi

# 重启服务
restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria restart || true
    else
        systemctl restart hysteria || true
    fi
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ Hysteria2 未安装或配置文件不存在${NC}"
        return
    fi
    PORT=$(grep "listen:" "$CONF" | sed 's/.*://' | tr -d ' ')
    PASSWORD=$(grep "password:" "$CONF" | awk -F'"' '{print $2}')
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "")
    echo -e "\n${GREEN}========== Hysteria2 配置信息 ==========${NC}"
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🔐 认证密码: ${YELLOW}$PASSWORD${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 节点链接 (IPv4):${NC}"
        echo -e "${YELLOW}hy2://$PASSWORD@$IP4:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V4${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}hy2://$PASSWORD@[$IP6]:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V6${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    OLD_PORT=$(cat "$PORT_FILE")
    read -p "请输入新端口 (回车则随机 10000-65535): " NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    sed -i "s/listen: :$OLD_PORT/listen: :$NEW_PORT/g" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/udp
    restart_service
    show_info
}

# 安装
install_hy2() {
    [ "$OS" = "alpine" ] && apk add --no-cache curl openssl ca-certificates bash || (apt update && apt install -y curl openssl ca-certificates bash)
    mkdir -p "$WORKDIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64|arm64) FILE="hysteria-linux-arm64" ;;
        *) echo "❌ 不支持架构"; exit 1 ;;
    esac
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"
    chmod +x "$BIN"
    PASSWORD=$(openssl rand -hex 4)
    PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    echo "$PASSWORD" > "$PASS_FILE"
    echo "$PORT" > "$PORT_FILE"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$SERVER_NAME"
    cat > "$CONF" <<EOF
listen: :$PORT
tls:
  cert: $WORKDIR/cert.pem
  key: $WORKDIR/key.pem
  alpn:
    - h3
auth:
  type: password
  password: "$PASSWORD"
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/hysteria.pid"
supervisor="supervise-daemon"
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default
    else
        cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2
After=network.target
[Service]
ExecStart=$BIN server -c $CONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria
    fi
    restart_service
    show_info
}

# 菜单
clear
echo -e "${GREEN}Hysteria2 管理脚本${NC}"
echo "1. 安装 Hysteria2"
echo "2. 查看信息"
echo "3. 更改端口"
echo "4. 卸载"
read -p "选择: " choice
case $choice in
    1) install_hy2 ;;
    2) show_info ;;
    3) change_port ;;
    4) 
        if [ "$OS" = "alpine" ]; then
            rc-service hysteria stop || true
            rc-update del hysteria || true
            rm -f /etc/init.d/hysteria
        else
            systemctl stop hysteria || true
            systemctl disable hysteria || true
            rm -f /etc/systemd/system/hysteria.service
        fi
        rm -rf "$WORKDIR" "$BIN"
        echo "已卸载" 
        ;;
    *) exit 0 ;;
esac
