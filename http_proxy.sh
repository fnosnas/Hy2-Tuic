#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
TAG="HTTP"
WORKDIR="/etc/3proxy"
BIN="/usr/local/bin/3proxy"
CONF="$WORKDIR/3proxy.cfg"
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
        rc-service 3proxy restart || true
    else
        systemctl restart 3proxy || true
    fi
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ HTTP代理 未安装或配置文件不存在${NC}"
        return
    fi
    PORT=$(cat "$PORT_FILE")
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "")
    echo -e "\n${GREEN}========== HTTP代理 配置信息 ==========${NC}"
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🔓 认证方式: ${YELLOW}无认证${NC}"
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 代理地址 (IPv4):${NC}"
        echo -e "${YELLOW}http://$IP4:$PORT${NC}"
        echo -e "${YELLOW}节点: ${TAG}_V4 → $IP4:$PORT${NC}"
    fi
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 代理地址 (IPv6):${NC}"
        echo -e "${YELLOW}http://[$IP6]:$PORT${NC}"
        echo -e "${YELLOW}节点: ${TAG}_V6 → [$IP6]:$PORT${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 HTTP代理${NC}"; return
    fi
    OLD_PORT=$(cat "$PORT_FILE")
    read -p "请输入新端口 (回车则随机 10000-65535): " NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    sed -i "s/proxy -p$OLD_PORT/proxy -p$NEW_PORT/g" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/tcp
    restart_service
    show_info
}

# 安装
install_proxy() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl bash 3proxy
    else
        apt update && apt install -y curl bash 3proxy
    fi

    mkdir -p "$WORKDIR"
    PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    echo "$PORT" > "$PORT_FILE"

    cat > "$CONF" <<EOF
#!/usr/bin/3proxy
# 无认证 HTTP 代理配置
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy.log D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
maxconn 300
allow *
proxy -n -a -p$PORT
EOF

    if [ "$OS" = "alpine" ]; then
        # Alpine 使用 OpenRC
        cat > /etc/init.d/3proxy <<'INITEOF'
#!/sbin/openrc-run
name="3proxy"
command="/usr/bin/3proxy"
command_args="/etc/3proxy/3proxy.cfg"
command_background=true
pidfile="/run/3proxy.pid"
supervisor="supervise-daemon"
INITEOF
        chmod +x /etc/init.d/3proxy
        rc-update add 3proxy default
    else
        # Debian/Ubuntu 使用 systemd
        # 若 apt 安装的 3proxy 已自带 service，跳过创建
        if [ ! -f /lib/systemd/system/3proxy.service ] && [ ! -f /etc/systemd/system/3proxy.service ]; then
            cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy HTTP Proxy
After=network.target
[Service]
ExecStart=$BIN $CONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable 3proxy
        else
            # 替换默认配置路径为我们自己的配置
            systemctl daemon-reload
            systemctl enable 3proxy
        fi
    fi

    command -v ufw >/dev/null 2>&1 && ufw allow "$PORT"/tcp

    restart_service
    show_info
}

# 菜单
clear
echo -e "${GREEN}HTTP 无认证代理 管理脚本${NC}"
echo "1. 安装 HTTP代理"
echo "2. 查看信息"
echo "3. 更改端口"
echo "4. 卸载"
read -p "选择: " choice
case $choice in
    1) install_proxy ;;
    2) show_info ;;
    3) change_port ;;
    4)
        if [ "$OS" = "alpine" ]; then
            rc-service 3proxy stop || true
            rc-update del 3proxy || true
            rm -f /etc/init.d/3proxy
        else
            systemctl stop 3proxy || true
            systemctl disable 3proxy || true
            rm -f /etc/systemd/system/3proxy.service
        fi
        rm -rf "$WORKDIR"
        echo -e "${GREEN}✅ 已卸载 HTTP代理${NC}"
        ;;
    *) exit 0 ;;
esac
