使用方法

方法一：直接在 VPS 上运行（推荐）
```
bash <(curl -fsSL https://raw.githubusercontent.com/fnosnas/Hy2-Tuic/main/VLESS/vless.sh)
```

方法二：手动上传后运行
```
# 上传 vless.sh 到 VPS 后执行：
chmod +x vless.sh
bash vless.sh
```
## 功能说明

| 功能 | 说明 |
|------|------|
| 自动识别架构 | 支持 x86_64 / ARM64 / ARMv7 |
| 支持系统 | Alpine / Debian / Ubuntu |
| 自动保活 | 崩溃后 5 秒自动重启（`Restart=always`） |
| 开机自启 | systemd / OpenRC 均已注册 |
| 一键更换端口 | 保留 UUID，仅换端口 |
| 节点链接 | 自动生成 IPv4 / IPv6 节点链接 |
