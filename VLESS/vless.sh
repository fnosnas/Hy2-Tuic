#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
TAG="VLESS"
WORKDIR="/etc/xray"
BIN="/usr/local/bin/xray"
CONF="$WORKDIR/config.json"
PORT_FILE="$WORKDIR/port.txt"
UUID_FILE="$WORKDIR/uuid.txt"
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

# 生成配置文件
write_config() {
    local PORT=$1
    local UUID=$2
    cat > "$CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ Xray/VLESS 未安装或配置文件不存在${NC}"
        return
    fi
    PORT=$(cat "$PORT_FILE")
    UUID=$(cat "$UUID_FILE")
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "")
    echo -e "\n${GREEN}========== VLESS 配置信息 ==========${NC}"
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🔑 UUID:     ${YELLOW}$UUID${NC}"
    echo -e "🔒 加密方式: ${YELLOW}none${NC}"
    echo -e "🌐 传输协议: ${YELLOW}tcp${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 节点链接 (IPv4):${NC}"
        echo -e "${YELLOW}vless://$UUID@$IP4:$PORT?encryption=none&type=tcp#${TAG}_V4${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}vless://$UUID@[$IP6]:$PORT?encryption=none&type=tcp#${TAG}_V6${NC}"
    fi
    echo -e "${GREEN}=====================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 VLESS${NC}"; return
    fi
    UUID=$(cat "$UUID_FILE")
    read -p "请输入新端口 (回车则随机 10000-65535): " NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    echo "$NEW_PORT" > "$PORT_FILE"
    write_config "$NEW_PORT" "$UUID"
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/tcp
    restart_service
    echo -e "${GREEN}✅ 端口已更改为: $NEW_PORT${NC}"
    show_info
}

# 安装
install_vless() {
    echo -e "${GREEN}📦 安装依赖...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl ca-certificates bash
    else
        apt update && apt install -y curl ca-certificates bash
    fi

    mkdir -p "$WORKDIR"

    # 识别系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   XRAY_FILE="Xray-linux-64.zip" ;;
        aarch64|arm64) XRAY_FILE="Xray-linux-arm64-v8a.zip" ;;
        armv7l)   XRAY_FILE="Xray-linux-arm32-v7a.zip" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    echo -e "${GREEN}⬇️  下载 Xray ($ARCH)...${NC}"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_FILE"
    TMP_DIR=$(mktemp -d)
    curl -L -o "$TMP_DIR/xray.zip" "$XRAY_URL"

    # 解压（alpine 用 unzip，需先安装）
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache unzip
    else
        apt install -y unzip
    fi
    unzip -o "$TMP_DIR/xray.zip" xray -d "$TMP_DIR/"
    mv "$TMP_DIR/xray" "$BIN"
    chmod +x "$BIN"
    rm -rf "$TMP_DIR"

    # 生成 UUID 和端口
    UUID=$("$BIN" uuid)
    PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    echo "$UUID" > "$UUID_FILE"
    echo "$PORT" > "$PORT_FILE"

    # 写入配置
    write_config "$PORT" "$UUID"

    # 开放端口
    command -v ufw >/dev/null 2>&1 && ufw allow "$PORT"/tcp

    # 注册系统服务（自动保活 + 开机自启）
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
        rc-service xray start
    else
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS Service
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
        systemctl start xray
    fi

    echo -e "${GREEN}✅ 安装完成！${NC}"
    show_info
}

# 卸载
uninstall_vless() {
    echo -e "${YELLOW}正在卸载...${NC}"
    if [ "$OS" = "alpine" ]; then
        rc-service xray stop || true
        rc-update del xray || true
        rm -f /etc/init.d/xray
    else
        systemctl stop xray || true
        systemctl disable xray || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR" "$BIN"
    echo -e "${GREEN}✅ 已完全卸载${NC}"
}

# 菜单
clear
echo -e "${GREEN}===== VLESS 管理脚本 (by Xray-core) =====${NC}"
echo "1. 安装 VLESS"
echo "2. 查看信息 / 节点链接"
echo "3. 更改端口"
echo "4. 卸载"
echo "0. 退出"
read -p "请选择: " choice
case $choice in
    1) install_vless ;;
    2) show_info ;;
    3) change_port ;;
    4) uninstall_vless ;;
    *) exit 0 ;;
esac
