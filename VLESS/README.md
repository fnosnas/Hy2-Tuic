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
注意: NAT机器端口转发的

Xray监听容器内端口(即是一键安装的时候要用内部的端口)

客户端端口要填公网端口(转发后的端口)
