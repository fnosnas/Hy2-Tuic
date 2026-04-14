```bash
#!/usr/bin/env bash [cite: 32]
set -e [cite: 32]

### ===== 配置参数 ===== [cite: 32]
SERVER_NAME="www.bing.com" [cite: 32]
TAG="HY2" [cite: 32]
WORKDIR="/etc/hysteria" [cite: 32]
BIN="/usr/local/bin/hysteria" [cite: 32]
CONF="$WORKDIR/config.yaml" [cite: 32]
PORT_FILE="$WORKDIR/port.txt" [cite: 32]
PASS_FILE="$WORKDIR/password.txt" [cite: 32]
### ===================== [cite: 32]

GREEN='\e[32m' [cite: 32]
RED='\e[31m' [cite: 32]
YELLOW='\e[33m' [cite: 32]
NC='\e[0m' [cite: 32]

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; } [cite: 32]

# 环境判断 [cite: 32]
if command -v apk >/dev/null 2>&1; then [cite: 33]
    OS="alpine" [cite: 33]
elif command -v apt >/dev/null 2>&1; then [cite: 33]
    OS="debian" [cite: 34]
else [cite: 34]
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}" [cite: 34]
    exit 1 [cite: 34]
fi [cite: 34]

# 重启服务 [cite: 34]
restart_service() { [cite: 34]
    if [ "$OS" = "alpine" ]; then [cite: 34]
        rc-service hysteria restart [cite: 35]
    else [cite: 35]
        systemctl restart hysteria [cite: 35]
    fi [cite: 35]
} [cite: 35]

# 获取并显示信息 (双栈支持) [cite: 35]
show_info() { [cite: 35]
    if [ ! -f "$CONF" ]; then [cite: 35]
        echo -e "${RED}❌ Hysteria2 未安装或配置文件不存在${NC}" [cite: 35]
        return [cite: 35]
    fi [cite: 35]

    # 提取端口和密码 [cite: 35]
    PORT=$(grep "listen:" "$CONF" | sed 's/.*://' | tr -d ' ') [cite: 35]
    PASSWORD=$(grep "password:" "$CONF" | awk -F'"' '{print $2}') [cite: 35]

    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}" [cite: 35]
    
    # 获取 IP (设置 5 秒超时) [cite: 35]
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "") [cite: 36]
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 ifconfig.me || echo "") [cite: 36]

    echo -e "\n${GREEN}========== Hysteria2 配置信息 ==========${NC}" [cite: 36]
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}" [cite: 36]
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}" [cite: 36]
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}" [cite: 36]
    echo -e "🔐 认证密码: ${YELLOW}$PASSWORD${NC}" [cite: 36]
    
    # IPv4 显示逻辑 [cite: 36]
    if [[ -n "$IP4" ]]; then [cite: 36]
        echo -e "\n${GREEN}📎 节点链接 (IPv4):${NC}" [cite: 36]
        echo -e "${YELLOW}hy2://$PASSWORD@$IP4:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V4${NC}" [cite: 36]
    fi [cite: 36]

    # IPv6 显示逻辑 [cite: 37]
    if [[ -n "$IP6" ]]; then [cite: 38]
        echo -e "\n${GREEN}📎 节点链接 (IPv6):${NC}" [cite: 38]
        echo -e "${YELLOW}hy2://$PASSWORD@[$IP6]:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V6${NC}" [cite: 38]
    fi [cite: 38]

    # 如果两个都没有检测到 [cite: 38]
    if [[ -z "$IP4" && -z "$IP6" ]]; then [cite: 39]
        echo -e "${RED}❌ 无法检测到公网 IP，请检查服务器网络${NC}" [cite: 39]
    fi [cite: 39]
    echo -e "${GREEN}=======================================${NC}\n" [cite: 39]
} [cite: 39]

# 更改端口 (手动或随机) [cite: 39]
change_port() { [cite: 39]
    if [ ! -f "$CONF" ]; then [cite: 40]
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return [cite: 41]
    fi [cite: 41]
    OLD_PORT=$(cat "$PORT_FILE") [cite: 41]
    echo -e "当前端口为: ${YELLOW}$OLD_PORT${NC}" [cite: 41]
    read -p "请输入新端口 (直接回车则随机生成 10000-65535): " NEW_PORT [cite: 41]
    
    if [ -z "$NEW_PORT" ]; then [cite: 42]
        NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 )) [cite: 43]
    fi [cite: 43]

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then [cite: 44]
        echo -e "${RED}❌ 输入无效${NC}"; return [cite: 45]
    fi [cite: 45]

    sed -i "s/listen: :$OLD_PORT/listen: :$NEW_PORT/g" "$CONF" [cite: 45]
    echo "$NEW_PORT" > "$PORT_FILE" [cite: 45]
    
    # 尝试放行防火墙 [cite: 45]
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/udp [cite: 45]
    
    restart_service [cite: 45]
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}" [cite: 45]
    echo -e "${GREEN}✅ hysteria2 服务已重启" [cite: 45]
    show_info [cite: 45]
} [cite: 45]

# 安装 [cite: 45]
install_hy2() { [cite: 45]
    echo -e "${YELLOW}▶ 正在安装依赖...${NC}" [cite: 45]
    [ "$OS" = "alpine" ] && apk add --no-cache curl openssl ca-certificates bash || (apt update && apt install -y curl openssl ca-certificates bash) [cite: 46]
    
    mkdir -p "$WORKDIR" [cite: 46]
    ARCH=$(uname -m) [cite: 46]
    case "$ARCH" in [cite: 46]
        x86_64) FILE="hysteria-linux-amd64" ;; [cite: 47]
        aarch64) FILE="hysteria-linux-arm64" ;; [cite: 47]
        *) echo "❌ 不支持的架构"; exit 1 ;; [cite: 48]
    esac [cite: 48]

    echo -e "${YELLOW}▶ 下载 Hysteria2 主程序...${NC}" [cite: 48]
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE" [cite: 48]
    chmod +x "$BIN" [cite: 48]

    # 生成随机密码和 10000 以上随机端口 [cite: 48]
    PASSWORD=$(openssl rand -hex 4) [cite: 48]
    PORT=$(( ( RANDOM % 55535 ) + 10000 )) [cite: 48]
    echo "$PASSWORD" > "$PASS_FILE" [cite: 48]
    echo "$PORT" > "$PORT_FILE" [cite: 48]

    echo -e "${YELLOW}▶ 生成自签证书...${NC}" [cite: 48]
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$SERVER_NAME" [cite: 48]

    # 写入配置 [cite: 48]
    cat > "$CONF" <<EOF [cite: 49]
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
EOF [cite: 49]

    # 服务部署 [cite: 49]
    if [ "$OS" = "alpine" ]; then [cite: 50]
        cat > /etc/init.d/hysteria <<EOF [cite: 50]
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/hysteria.pid"
supervisor="supervise-daemon"
EOF [cite: 50]
        chmod +x /etc/init.d/hysteria [cite: 50]
        rc-update add hysteria default [cite: 50]
    else [cite: 50]
        cat > /etc/systemd/system/hysteria.service <<EOF [cite: 50]
[Unit]
Description=Hysteria2
After=network.target
[Service]
ExecStart=$BIN server -c $CONF
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF [cite: 50]
        systemctl daemon-reload [cite: 50]
        systemctl enable hysteria [cite: 50]
    fi [cite: 50]
    
    restart_service [cite: 50]
    echo -e "${GREEN}✅ Hysteria2 安装完成！${NC}" [cite: 50]
    show_info [cite: 50]
} [cite: 50]

# 卸载 [cite: 50]
uninstall_hy2() { [cite: 51]
    echo -e "${YELLOW}▶ 正在清理系统...${NC}" [cite: 51]
    if [ "$OS" = "alpine" ]; then [cite: 52]
        rc-service hysteria stop || true [cite: 53]
        rc-update del hysteria || true [cite: 54]
        rm -f /etc/init.d/hysteria [cite: 54]
    else [cite: 54]
        systemctl stop hysteria || true [cite: 55]
        systemctl disable hysteria || true [cite: 56]
        rm -f /etc/systemd/system/hysteria.service [cite: 56]
        systemctl daemon-reload [cite: 56]
    fi [cite: 56]
    rm -rf "$WORKDIR" [cite: 56]
    rm -f "$BIN" [cite: 56]
    echo -e "${GREEN}✅ 卸载成功${NC}" [cite: 56]
} [cite: 56]

# --- 菜单界面 --- [cite: 56]
clear [cite: 56]
echo -e "${GREEN}Hysteria2 管理脚本${NC}" [cite: 56]
echo "--------------------------" [cite: 56]
echo "1. 安装 Hysteria2" [cite: 56]
echo "2. 查看配置信息" [cite: 56]
echo "3. 更改监听端口" [cite: 56]
echo "4. 重启服务" [cite: 56]
echo "5. 卸载 Hysteria2" [cite: 56]
echo "0. 退出" [cite: 56]
echo "--------------------------" [cite: 56]
read -p "请输入数字选择: " choice [cite: 56]

case $choice in [cite: 56]
    1) install_hy2 ;; [cite: 57]
    2) show_info ;; [cite: 58]
    3) change_port ;; [cite: 58]
    4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;; [cite: 58]
    5) uninstall_hy2 ;; [cite: 58]
    *) exit 0 ;; [cite: 58]
esac [cite: 58]
