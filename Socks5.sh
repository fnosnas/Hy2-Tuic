#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
TAG="SOCKS5"
WORKDIR="/etc/xray"
BIN="/usr/local/bin/xray"
CONF="$WORKDIR/config.json"
PORT_FILE="$WORKDIR/port.txt"
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
        rc-service xray restart || true
    else
        systemctl restart xray || true
    fi
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ Socks5 未安装或配置文件不存在${NC}"
        return
    fi
    PORT_AUTH=$(jq -r '.inbounds[0].port' "$CONF")
    PORT_NOAUTH=$(jq -r '.inbounds[1].port' "$CONF")
    USER=$(jq -r '.inbounds[0].settings.accounts[0].user' "$CONF")
    PASS=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$CONF")

    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "")

    echo -e "\n${GREEN}========== Socks5 代理配置信息 ==========${NC}"
    echo -e "📌 IPv4地址 : ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址 : ${YELLOW}$IP6${NC}"
    echo -e ""
    echo -e "${GREEN}--- 节点1：带账号密码 ---${NC}"
    echo -e "🎲 端口     : ${YELLOW}$PORT_AUTH${NC}"
    echo -e "👤 用户名   : ${YELLOW}$USER${NC}"
    echo -e "🔐 密码     : ${YELLOW}$PASS${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "📎 IPv4链接 : ${YELLOW}socks5://$USER:$PASS@$IP4:$PORT_AUTH${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "📎 IPv6链接 : ${YELLOW}socks5://$USER:$PASS@[$IP6]:$PORT_AUTH${NC}"
    fi
    echo -e ""
    echo -e "${GREEN}--- 节点2：无需认证 ---${NC}"
    echo -e "🎲 端口     : ${YELLOW}$PORT_NOAUTH${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "📎 IPv4链接 : ${YELLOW}socks5://$IP4:$PORT_NOAUTH${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "📎 IPv6链接 : ${YELLOW}socks5://[$IP6]:$PORT_NOAUTH${NC}"
    fi
    echo -e "${GREEN}=========================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Socks5${NC}"; return
    fi
    read -p "请输入新的认证端口 (回车随机): " NEW_PORT_AUTH
    [[ -z "$NEW_PORT_AUTH" ]] && NEW_PORT_AUTH=$(( RANDOM % 50000 + 10000 ))
    read -p "请输入新的无认证端口 (回车随机): " NEW_PORT_NOAUTH
    [[ -z "$NEW_PORT_NOAUTH" ]] && NEW_PORT_NOAUTH=$(( RANDOM % 50000 + 10000 ))

    # 用 jq 更新端口
    TMP=$(mktemp)
    jq ".inbounds[0].port = $NEW_PORT_AUTH | .inbounds[1].port = $NEW_PORT_NOAUTH" "$CONF" > "$TMP" && mv "$TMP" "$CONF"

    command -v ufw >/dev/null 2>&1 && {
        ufw allow "$NEW_PORT_AUTH"/tcp
        ufw allow "$NEW_PORT_NOAUTH"/tcp
    }
    restart_service
    show_info
}

# 安装
install_socks5() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl ca-certificates bash jq unzip
    else
        apt update && apt install -y curl ca-certificates bash jq unzip
    fi

    mkdir -p "$WORKDIR"

    # 下载 xray
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_FILE="Xray-linux-64.zip" ;;
        aarch64|arm64) XRAY_FILE="Xray-linux-arm64-v8a.zip" ;;
        *) echo "❌ 不支持架构: $ARCH"; exit 1 ;;
    esac

    echo -e "${YELLOW}正在下载 Xray...${NC}"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_FILE"
    curl -L -o /tmp/xray.zip "$XRAY_URL"
    unzip -o /tmp/xray.zip xray -d /usr/local/bin/
    chmod +x "$BIN"
    rm -f /tmp/xray.zip

    # 生成随机端口和密码
    PORT_AUTH=$(( RANDOM % 50000 + 10000 ))
    PORT_NOAUTH=$(( RANDOM % 50000 + 10000 ))
    # 避免两个端口相同
    while [ "$PORT_NOAUTH" -eq "$PORT_AUTH" ]; do
        PORT_NOAUTH=$(( RANDOM % 50000 + 10000 ))
    done
    SOCKS_USER="user$(openssl rand -hex 2)"
    SOCKS_PASS=$(openssl rand -hex 6)

    echo "$PORT_AUTH $PORT_NOAUTH" > "$PORT_FILE"

    # 生成 xray config.json
    cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-auth",
      "port": $PORT_AUTH,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          { "user": "$SOCKS_USER", "pass": "$SOCKS_PASS" }
        ],
        "udp": true
      }
    },
    {
      "tag": "socks-noauth",
      "port": $PORT_NOAUTH,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    # 注册服务
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
command="$BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/xray.pid"
supervisor="supervise-daemon"
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default
    else
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Socks5 Proxy
After=network.target
[Service]
ExecStart=$BIN run -c $CONF
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray
    fi

    # 放行防火墙
    command -v ufw >/dev/null 2>&1 && {
        ufw allow "$PORT_AUTH"/tcp
        ufw allow "$PORT_NOAUTH"/tcp
    }

    restart_service
    show_info
}

# 菜单
clear
echo -e "${GREEN}===== Socks5 代理管理脚本 =====${NC}"
echo "1. 安装 Socks5 代理"
echo "2. 查看节点信息"
echo "3. 更改端口"
echo "4. 卸载"
echo "0. 退出"
read -p "选择: " choice
case $choice in
    1) install_socks5 ;;
    2) show_info ;;
    3) change_port ;;
    4)
        if [ "$OS" = "alpine" ]; then
            rc-service xray stop || true
            rc-update del xray || true
            rm -f /etc/init.d/xray
        else
            systemctl stop xray || true
            systemctl disable xray || true
            rm -f /etc/systemd/system/xray.service
        fi
        rm -rf "$WORKDIR" "$BIN"
        echo -e "${GREEN}✅ 已卸载${NC}"
        ;;
    0) exit 0 ;;
    *) echo "无效选项"; exit 1 ;;
esac
