```bash
#!/usr/bin/env bash [cite: 2]
set -e [cite: 2]

### ===== 配置参数 ===== [cite: 2]
WORK_DIR="/usr/local/tuic" [cite: 2]
BIN="${WORK_DIR}/tuic-server" [cite: 2]
CONF="${WORK_DIR}/config.yaml" [cite: 2]
SERVICE_NAME="tuic" [cite: 2]
### ===================== [cite: 2]

GREEN='\033[32m' [cite: 2]
YELLOW='\033[33m' [cite: 2]
RED='\033[31m' [cite: 2]
NC='\033[0m' [cite: 2]

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; } [cite: 2]

# 环境判断 [cite: 2]
if [ -f /etc/alpine-release ]; then [cite: 2]
    OS="alpine" [cite: 2]
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then [cite: 3]
    OS="debian" [cite: 3]
else [cite: 3]
    echo -e "${RED}❌ 不支持的系统${NC}"; exit 1 [cite: 4]
fi [cite: 4]

# 重启服务 [cite: 4]
restart_service() { [cite: 4]
    if command -v systemctl >/dev/null; then [cite: 5]
        systemctl restart ${SERVICE_NAME} [cite: 5]
    else [cite: 5]
        rc-service ${SERVICE_NAME} restart [cite: 5]
    fi [cite: 5]
} [cite: 5]

# 获取并显示信息 [cite: 5]
show_info() { [cite: 5]
    if [ ! -f "$CONF" ]; then [cite: 6]
        echo -e "${RED}❌ TUIC 未安装或配置文件不存在${NC}"; return [cite: 7]
    fi [cite: 7]
    
    # 精准提取配置信息 [cite: 7]
    PORT=$(grep "server:" "$CONF" | sed 's/.*://' | tr -d '"' | tr -d ' ' | tr -d ']') [cite: 7]
    UUID=$(grep -A 1 "users:" "$CONF" | tail -n 1 | awk -F'"' '{print $2}') [cite: 7]
    PASS=$(grep -A 1 "users:" "$CONF" | tail -n 1 | awk -F'"' '{print $4}') [cite: 7]
    
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}" [cite: 7]
    
    # 获取 IP (5秒超时，失败则留空) [cite: 7]
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "") [cite: 8]
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "") [cite: 8]

    echo -e "\n${GREEN}========== TUIC 配置信息 ==========${NC}" [cite: 8]
    echo -e "🌐 IPv4地址: ${YELLOW}$IP4${NC}" [cite: 8]
    echo -e "🌐 IPv6地址: ${YELLOW}$IP6${NC}" [cite: 8]
    echo -e "📌 UUID: ${YELLOW}$UUID${NC}" [cite: 8]
    echo -e "🔐 密码: ${YELLOW}$PASS${NC}" [cite: 8]
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}" [cite: 8]
    
    # --- IPv4 显示逻辑 --- [cite: 8]
    if [[ -n "$IP4" ]]; then [cite: 8]
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv4):${NC}" [cite: 9]
        echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V4${NC}" [cite: 9]
    fi [cite: 9]
    
    # --- IPv6 显示逻辑 --- [cite: 9]
    if [[ -n "$IP6" ]]; then [cite: 10]
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv6):${NC}" [cite: 10]
        echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V6${NC}" [cite: 10]
    fi [cite: 10]

    # 兜底：如果两个都没检测到 [cite: 10]
    if [[ -z "$IP4" && -z "$IP6" ]]; then [cite: 11]
        echo -e "\n${RED}⚠️ 警告: 无法检测到任何公网 IP 地址，请检查服务器网络。${NC}" [cite: 11]
    fi [cite: 11]
    echo -e "${GREEN}=======================================${NC}\n" [cite: 11]
} [cite: 11]

# 修改端口 [cite: 11]
change_port() { [cite: 11]
    if [ ! -f "$CONF" ]; then [cite: 12]
        echo -e "${RED}❌ 请先安装 TUIC${NC}"; return [cite: 13]
    fi [cite: 13]
    
    # 提取旧端口 [cite: 13]
    OLD_PORT=$(grep "server:" "$CONF" | sed 's/.*://' | tr -d '"' | tr -d ' ' | tr -d ']') [cite: 13]
    
    echo -e "当前监听端口为: ${YELLOW}$OLD_PORT${NC}" [cite: 13]
    read -p "请输入新端口 (10000-65535，直接回车则随机): " NEW_PORT [cite: 13]
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 )) [cite: 13]

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then [cite: 13]
        echo -e "${RED}❌ 输入无效${NC}"; return [cite: 14]
    fi [cite: 14]

    sed -i "s/\(:[0-9]\{1,5\}\)\"/\:$NEW_PORT\"/g" "$CONF" [cite: 14]
    
    # 校验配置文件是否更改成功 [cite: 14]
    CHECK_PORT=$(grep "server:" "$CONF" | sed 's/.*://' | tr -d '"' | tr -d ' ' | tr -d ']') [cite: 14]
    
    if [ "$CHECK_PORT" != "$NEW_PORT" ]; then [cite: 15]
        echo -e "${RED}❌ 自动修改失败，正在尝试强制写入...${NC}" [cite: 15]
        # 备用方案：通过重新生成 server 行来强制修改 [cite: 15]
        BIND_ADDR="0.0.0.0" [cite: 15]
        grep -q "\[::\]" "$CONF" && BIND_ADDR="[::]" [cite: 15]
        sed -i "/server:/c\server: \"${BIND_ADDR}:${NEW_PORT}\"" "$CONF" [cite: 15]
    fi [cite: 15]

    # 放行防火墙 (Debian 常用 ufw 或 iptables) [cite: 15]
    if command -v ufw >/dev/null 2>&1; then [cite: 16]
        ufw allow "$NEW_PORT"/udp [cite: 16]
    elif command -v iptables >/dev/null 2>&1; then [cite: 17]
        iptables -I INPUT -p udp --dport "$NEW_PORT" -j ACCEPT [cite: 17]
    fi [cite: 17]
    
    restart_service [cite: 17]
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}" [cite: 17]
    echo -e "${GREEN}✅ TUIC 服务已重启" [cite: 17]
    show_info [cite: 17]
} [cite: 17]

# 安装 [cite: 17]
install_tuic() { [cite: 17]
    echo -e "${YELLOW}▶ 正在安装依赖...${NC}" [cite: 17]
    [ "$OS" = "alpine" ] && apk add --no-cache curl openssl bash openrc || (apt update -y && apt install -y curl openssl) [cite: 18]

    ARCH=$(uname -m) [cite: 18]
    case "$ARCH" in [cite: 18]
        x86_64) TUIC_ARCH="x86_64" ;; [cite: 18]
        aarch64|arm64) TUIC_ARCH="aarch64" ;; [cite: 19]
        *) echo "❌ 不支持架构: $ARCH"; exit 1 ;; [cite: 19]
    esac [cite: 20]

    mkdir -p $WORK_DIR [cite: 20]
    echo -e "${YELLOW}▶ 从 GitHub 官方下载 TUIC Server...${NC}" [cite: 20]
    
    URL="https://github.com/Itsusinn/tuic/releases/latest/download/tuic-server-${TUIC_ARCH}-linux-musl" [cite: 20]
    
    if ! curl -L -o $BIN "$URL"; then [cite: 21]
        echo -e "${RED}❌ 下载失败，请检查服务器是否能连接 GitHub${NC}"; exit 1 [cite: 22]
    fi [cite: 22]
    
    chmod +x $BIN [cite: 22]

    PORT=$(( ( RANDOM % 50000 ) + 10000 )) [cite: 22]
    UUID=$(cat /proc/sys/kernel/random/uuid) [cite: 22]
    PASS=$(openssl rand -hex 4) [cite: 22]
    BIND_ADDR="0.0.0.0" [cite: 22]
    ip -6 addr | grep -q "global" && BIND_ADDR="[::]" [cite: 23]

    cat > $CONF <<EOF [cite: 23]
server: "${BIND_ADDR}:${PORT}"
users:
  "${UUID}": "${PASS}"
congestion_control: "bbr"
auth_timeout: "3s"
zero_rtt_handshake: false
tls:
  certificate: "${WORK_DIR}/cert.pem"
  private_key: "${WORK_DIR}/key.pem"
  alpn:
    - "h3"
EOF [cite: 23]

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" -days 3650 -nodes [cite: 23]

    if command -v systemctl >/dev/null; then [cite: 24]
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF [cite: 24]
[Unit]
Description=TUIC Server
After=network.target
[Service]
ExecStart=${BIN} -c ${CONF}
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF [cite: 24]
        systemctl daemon-reload [cite: 24]
        systemctl enable ${SERVICE_NAME} [cite: 24]
    else [cite: 24]
        cat > /etc/init.d/${SERVICE_NAME} <<EOF [cite: 24]
#!/sbin/openrc-run
description="TUIC v5 Server"
command="${BIN}"
command_args="-c ${CONF}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF [cite: 24]
        chmod +x /etc/init.d/${SERVICE_NAME} [cite: 24]
        rc-update add ${SERVICE_NAME} default [cite: 24]
    fi [cite: 24]

    restart_service [cite: 24]
    echo -e "${GREEN}✅ 安装完成${NC}" [cite: 24]
    show_info [cite: 24]
} [cite: 24]

# 卸载 [cite: 24]
uninstall_tuic() { [cite: 24]
    if command -v systemctl >/dev/null; then [cite: 25]
        systemctl stop ${SERVICE_NAME} || true [cite: 26]
        systemctl disable ${SERVICE_NAME} || true [cite: 27]
        rm -f /etc/systemd/system/${SERVICE_NAME}.service [cite: 27]
        systemctl daemon-reload [cite: 27]
    else [cite: 27]
        rc-service ${SERVICE_NAME} stop || true [cite: 28]
        rc-update del ${SERVICE_NAME} || true [cite: 29]
        rm -f /etc/init.d/${SERVICE_NAME} [cite: 29]
    fi [cite: 29]
    rm -rf $WORK_DIR [cite: 29]
    echo -e "${GREEN}✅ 卸载成功${NC}" [cite: 29]
} [cite: 29]

# --- 菜单 --- [cite: 29]
clear [cite: 29]
echo -e "${GREEN}TUIC 管理脚本${NC}" [cite: 29]
echo "--------------------------" [cite: 29]
echo "1. 安装 TUIC" [cite: 29]
echo "2. 查看配置信息" [cite: 29]
echo "3. 更改监听端口" [cite: 29]
echo "4. 重启服务" [cite: 29]
echo "5. 卸载 TUIC" [cite: 29]
echo "0. 退出" [cite: 29]
echo "--------------------------" [cite: 29]
read -p "请选择: " choice [cite: 29]

case $choice in [cite: 29]
    1) install_tuic ;; [cite: 30]
    2) show_info ;; 
    3) change_port ;; 
    4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;; 
    5) uninstall_tuic ;; 
    *) exit 0 ;; 
esac
