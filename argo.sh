#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
TAG="ARGO"
WORKDIR="/etc/argo-proxy"
XRAY_BIN="/usr/local/bin/xray"
ARGO_BIN="/usr/local/bin/cloudflared"
XRAY_CONF="$WORKDIR/config.json"
ARGO_CONF="$WORKDIR/argo.conf"
INFO_FILE="$WORKDIR/info.txt"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
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

# 架构判断
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)           ARCH_XRAY="64";    ARCH_ARGO="amd64" ;;
        aarch64|arm64)    ARCH_XRAY="arm64"; ARCH_ARGO="arm64" ;;
        armv7l)           ARCH_XRAY="arm32"; ARCH_ARGO="arm"   ;;
        *)
            echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"
            exit 1
        ;;
    esac
}

# 重启服务
restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service xray restart   2>/dev/null || true
        rc-service cloudflared restart 2>/dev/null || true
    else
        systemctl restart xray        2>/dev/null || true
        systemctl restart cloudflared 2>/dev/null || true
    fi
}

# 安装依赖
install_deps() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl ca-certificates bash unzip wget jq file 2>/dev/null || true
    else
        apt-get update -qq
        apt-get install -y -qq curl openssl ca-certificates unzip wget jq file 2>/dev/null || true
    fi
}

# 获取公网IP
get_ip() {
    IP4=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || \
          curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || \
          curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
}

# 显示信息
show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ Argo 代理节点未安装${NC}"
        return
    fi
    source "$INFO_FILE"
    echo -e "\n${GREEN}========== Argo 隧道代理配置信息 ==========${NC}"
    echo -e "📌 UUID:        ${YELLOW}$UUID${NC}"
    echo -e "🌐 Argo 域名:   ${YELLOW}$ARGO_DOMAIN${NC}"
    echo -e "🔌 本地XRAY端口:${YELLOW}$XRAY_PORT${NC}"
    echo -e "🔐 隧道类型:    ${YELLOW}$TUNNEL_TYPE${NC}"
    if [[ "$TUNNEL_TYPE" == "fixed" ]]; then
        echo -e "🎟️  Token:       ${YELLOW}$TUNNEL_TOKEN${NC}"
    fi
    echo -e "\n${GREEN}📎 VLESS 节点链接 (通过Argo隧道):${NC}"
    echo -e "${YELLOW}vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2Fvless#${TAG}${NC}"
    echo -e "\n${CYAN}💡 v2rayN / Clash Meta 导入以上链接即可使用${NC}"
    echo -e "${GREEN}=============================================${NC}\n"
}

# 更改端口（本地Xray监听端口）
change_port() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ 请先安装 Argo 代理${NC}"; return
    fi
    source "$INFO_FILE"
    echo -e "${YELLOW}当前本地端口: $XRAY_PORT${NC}"
    read -p "请输入新本地端口 (回车则随机 10000-65535): " NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))

    # 更新 xray 配置中的端口
    sed -i "s/\"port\": $XRAY_PORT/\"port\": $NEW_PORT/" "$XRAY_CONF"

    # 更新 argo 配置中的端口
    if [ "$TUNNEL_TYPE" == "temp" ]; then
        # 临时隧道，服务文件中的端口需更新
        if [ "$OS" = "alpine" ]; then
            sed -i "s|localhost:$XRAY_PORT|localhost:$NEW_PORT|g" /etc/init.d/cloudflared
        else
            sed -i "s|localhost:$XRAY_PORT|localhost:$NEW_PORT|g" /etc/systemd/system/cloudflared.service
            systemctl daemon-reload
        fi
    else
        # 固定隧道更新 ingress 配置
        sed -i "s|localhost:$XRAY_PORT|localhost:$NEW_PORT|g" "$WORKDIR/tunnel.yml"
    fi

    # 保存新端口
    sed -i "s/^XRAY_PORT=.*/XRAY_PORT=$NEW_PORT/" "$INFO_FILE"
    XRAY_PORT=$NEW_PORT

    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装 Xray
install_xray() {
    echo -e "${CYAN}⬇️  正在获取 Xray 最新版本号...${NC}"

    # ---- 修复点 1：用 jq 精确解析 tag_name，不再用容易出错的 grep/sed 管道 ----
    XRAY_VER=$(curl -sf "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name' 2>/dev/null || true)

    # ---- 修复点 2：去掉写死的过时保底版本号，获取失败就直接报错退出 ----
    if [[ -z "$XRAY_VER" || "$XRAY_VER" == "null" ]]; then
        echo -e "${RED}❌ 无法获取 Xray 最新版本号，请检查网络（能否访问 api.github.com）或稍后重试${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 最新版本: $XRAY_VER${NC}"

    XRAY_ZIP="Xray-linux-${ARCH_XRAY}.zip"
    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"

    echo -e "${CYAN}⬇️  正在下载 Xray ($XRAY_ZIP)...${NC}"

    # ---- 修复点 3：curl 加 -f，HTTP 4xx/5xx 直接失败，不会把错误页面当正常文件保存 ----
    if ! curl -Lf -o /tmp/xray.zip "$DOWNLOAD_URL"; then
        echo -e "${RED}❌ 下载失败: $DOWNLOAD_URL${NC}"
        echo -e "${RED}   请检查该版本/架构对应的资源是否存在${NC}"
        exit 1
    fi

    # ---- 修复点 4：下载后校验文件类型，确认确实是 zip，而不是错误页面 ----
    if ! file /tmp/xray.zip | grep -q "Zip archive"; then
        echo -e "${RED}❌ 下载的文件不是有效的 zip 包，可能是链接失效或网络异常${NC}"
        rm -f /tmp/xray.zip
        exit 1
    fi

    unzip -o /tmp/xray.zip xray -d /tmp/
    mv /tmp/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -f /tmp/xray.zip
}

# 安装 cloudflared
install_cloudflared() {
    echo -e "${CYAN}⬇️  正在下载 cloudflared...${NC}"
    if ! curl -Lf -o "$ARGO_BIN" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_ARGO}"; then
        echo -e "${RED}❌ cloudflared 下载失败，请检查网络${NC}"
        exit 1
    fi
    chmod +x "$ARGO_BIN"
}

# 注册服务（systemd / openrc）
register_services() {
    UUID="$1"
    XRAY_PORT="$2"
    TUNNEL_TYPE="$3"
    TUNNEL_TOKEN="$4"

    # ------- Xray 服务 -------
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONF"
command_background=true
pidfile="/run/xray.pid"
supervisor="supervise-daemon"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default 2>/dev/null || true
    else
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Core
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray
    fi

    # ------- cloudflared 服务 -------
    if [ "$TUNNEL_TYPE" == "fixed" ]; then
        # 固定隧道：用 token 运行
        ARGO_CMD="$ARGO_BIN tunnel --no-autoupdate run --token $TUNNEL_TOKEN"
    else
        # 临时隧道：quick 模式，输出写入日志
        ARGO_CMD="$ARGO_BIN tunnel --no-autoupdate --url http://localhost:$XRAY_PORT --logfile $WORKDIR/argo.log"
    fi

    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/cloudflared <<'EOFA'
#!/sbin/openrc-run
name="cloudflared"
EOFA
        cat >> /etc/init.d/cloudflared <<EOF
command="$ARGO_BIN"
EOF
        if [ "$TUNNEL_TYPE" == "fixed" ]; then
            cat >> /etc/init.d/cloudflared <<EOF
command_args="tunnel --no-autoupdate run --token $TUNNEL_TOKEN"
EOF
        else
            cat >> /etc/init.d/cloudflared <<EOF
command_args="tunnel --no-autoupdate --url http://localhost:$XRAY_PORT --logfile $WORKDIR/argo.log"
EOF
        fi
        cat >> /etc/init.d/cloudflared <<EOF
command_background=true
pidfile="/run/cloudflared.pid"
supervisor="supervise-daemon"
depend() { need net; }
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default 2>/dev/null || true
    else
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
ExecStart=$ARGO_CMD
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable cloudflared
    fi
}

# 获取临时隧道域名（重试等待）
get_temp_domain() {
    echo -e "${CYAN}⏳ 等待 Argo 临时域名生成（最多60秒）...${NC}"
    for i in $(seq 1 30); do
        sleep 2
        DOMAIN=$(grep -oP 'https://\K[a-zA-Z0-9\-]+\.trycloudflare\.com' "$WORKDIR/argo.log" 2>/dev/null | head -1 || true)
        if [[ -n "$DOMAIN" ]]; then
            echo -e "${GREEN}✅ 临时域名: $DOMAIN${NC}"
            return 0
        fi
    done
    # 再尝试一次长超时
    DOMAIN=$(grep -oP 'https://\K[a-zA-Z0-9\-]+\.trycloudflare\.com' "$WORKDIR/argo.log" 2>/dev/null | head -1 || true)
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}⚠️  未能自动获取临时域名，请查看日志: $WORKDIR/argo.log${NC}"
        DOMAIN="<临时域名未获取，请手动查看日志>"
    fi
}

# 主安装函数
install_argo() {
    install_deps
    detect_arch
    mkdir -p "$WORKDIR"

    # ---- 询问域名/端口/token ----
    echo -e "\n${CYAN}======= Argo 隧道配置 =======${NC}"
    echo -e "${YELLOW}如需使用固定域名，请输入 Cloudflare 隧道信息；直接回车则使用免费临时域名${NC}\n"

    read -p "请输入域名 (留空=临时域名): " INPUT_DOMAIN
    read -p "请输入 Token (留空=临时隧道): " INPUT_TOKEN

    # 本地 Xray 监听端口
    read -p "请输入本地监听端口 (留空则随机): " XRAY_PORT
    [[ -z "$XRAY_PORT" ]] && XRAY_PORT=$(( ( RANDOM % 40000 ) + 10000 ))

    # 判断隧道类型
    if [[ -n "$INPUT_TOKEN" ]]; then
        TUNNEL_TYPE="fixed"
        TUNNEL_TOKEN="$INPUT_TOKEN"
        ARGO_DOMAIN="${INPUT_DOMAIN:-<你的Cloudflare域名>}"
    else
        TUNNEL_TYPE="temp"
        TUNNEL_TOKEN=""
        ARGO_DOMAIN=""  # 启动后获取
    fi

    # 生成 UUID
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
           python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
           openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')

    # 生成自签证书（本地 TLS，供 xray 内部使用，sha256 可校验）
    echo -e "${CYAN}🔐 生成自签证书...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$WORKDIR/key.pem" \
        -out "$WORKDIR/cert.pem" \
        -days 3650 \
        -subj "/CN=www.bing.com" \
        -addext "subjectAltName=DNS:www.bing.com" 2>/dev/null

    # 提取 SHA256 指纹
    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$WORKDIR/cert.pem" 2>/dev/null | \
                  sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')

    # 写 Xray 配置（VLESS + WS，ws path=/vless）
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    # 安装 Xray 和 cloudflared
    install_xray
    install_cloudflared

    # 注册开机服务（自动保活）
    register_services "$UUID" "$XRAY_PORT" "$TUNNEL_TYPE" "$TUNNEL_TOKEN"

    # 启动服务
    echo -e "${CYAN}🚀 启动服务...${NC}"
    if [ "$OS" = "alpine" ]; then
        rc-service xray start 2>/dev/null || true
        rc-service cloudflared start 2>/dev/null || true
    else
        systemctl start xray        2>/dev/null || true
        systemctl start cloudflared 2>/dev/null || true
    fi

    # 临时隧道：等待获取域名
    if [[ "$TUNNEL_TYPE" == "temp" ]]; then
        get_temp_domain
        ARGO_DOMAIN="$DOMAIN"
    fi

    # 保存配置信息
    cat > "$INFO_FILE" <<EOF
UUID=$UUID
XRAY_PORT=$XRAY_PORT
ARGO_DOMAIN=$ARGO_DOMAIN
TUNNEL_TYPE=$TUNNEL_TYPE
TUNNEL_TOKEN=$TUNNEL_TOKEN
CERT_SHA256=$CERT_SHA256
EOF

    echo -e "\n${GREEN}✅ Argo 隧道代理安装完成！${NC}"
    show_info

    # 额外输出 sha256
    echo -e "${CYAN}🔏 自签证书 SHA256 指纹（v2rayN fingerprint 填写）:${NC}"
    echo -e "${YELLOW}$CERT_SHA256${NC}\n"
}

# 卸载
uninstall_argo() {
    echo -e "${YELLOW}正在卸载 Argo 代理...${NC}"
    if [ "$OS" = "alpine" ]; then
        rc-service xray stop           2>/dev/null || true
        rc-service cloudflared stop    2>/dev/null || true
        rc-update del xray             2>/dev/null || true
        rc-update del cloudflared      2>/dev/null || true
        rm -f /etc/init.d/xray /etc/init.d/cloudflared
    else
        systemctl stop xray            2>/dev/null || true
        systemctl stop cloudflared     2>/dev/null || true
        systemctl disable xray         2>/dev/null || true
        systemctl disable cloudflared  2>/dev/null || true
        rm -f /etc/systemd/system/xray.service \
               /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f  "$XRAY_BIN" "$ARGO_BIN"
    echo -e "${GREEN}✅ 卸载完成${NC}"
}

# 按任意键返回主菜单
pause_return() {
    echo -e "\n${CYAN}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
}

# ========== 菜单 ==========
while true; do
    clear
    echo -e "${GREEN}Argo 隧道管理脚本${NC}"
    echo "1. 安装 Argo"
    echo "2. 查看信息"
    echo "3. 修改端口"
    echo "4. 卸载"
    echo "0. 退出脚本"
    read -p "选择: " choice
    case $choice in
        1) install_argo ; pause_return ;;
        2) show_info    ; pause_return ;;
        3) change_port  ; pause_return ;;
        4) uninstall_argo ; pause_return ;;
        0) echo -e "${GREEN}已退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; pause_return ;;
    esac
done
