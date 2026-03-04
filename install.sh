#!/bin/bash
# 随机 IPv6 + v6-proxy + Xray VMess 一键部署
# 使用前编辑 config.sh 填入新 VPS 的 TunnelBroker 参数

set -e
cd "$(dirname "$0")"

if [ ! -f config.sh ]; then
    echo "错误: 请先编辑 config.sh 填入隧道参数"
    exit 1
fi

source config.sh

echo "=========================================="
echo "随机 IPv6 部署 - 参数确认"
echo "=========================================="
echo "HE Server:    $HE_SERVER_IP"
echo "Client 内网:  $CLIENT_INTERNAL_IP"
echo "隧道链路:     $TUNNEL_IPV6_CLIENT"
echo "Routed /64:   $ROUTED_CIDR"
echo "主网卡:       $PRIMARY_INTERFACE"
echo "=========================================="
read -p "确认无误后按回车继续，Ctrl+C 取消..."

# 1. 安装 v6-proxy
echo "[1/6] 安装 v6-proxy..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    BIN_URL="https://github.com/zbronya/v6-proxy/releases/latest/download/v6-proxy-linux-amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    BIN_URL="https://github.com/zbronya/v6-proxy/releases/latest/download/v6-proxy-linux-arm64"
else
    echo "不支持架构: $ARCH"
    exit 1
fi
if [ -f v6-proxy ]; then
    cp v6-proxy /usr/local/bin/v6-proxy
else
    wget -q -O /usr/local/bin/v6-proxy "$BIN_URL" || curl -sL -o /usr/local/bin/v6-proxy "$BIN_URL"
fi
chmod +x /usr/local/bin/v6-proxy

# 2. Netplan 隧道配置
echo "[2/6] 配置 HE 隧道..."
cat > /etc/netplan/99-he-tunnel.yaml << EOF
network:
  version: 2
  tunnels:
    he-ipv6:
      mode: sit
      remote: $HE_SERVER_IP
      local: $CLIENT_INTERNAL_IP
      addresses:
        - "$TUNNEL_IPV6_CLIENT"
      routes:
        - to: default
          via: "$TUNNEL_IPV6_GATEWAY"
          metric: 100
EOF

# 3. Systemd 服务
echo "[3/6] 安装 systemd 服务..."
cat > /etc/systemd/system/ipv6-anyip.service << EOF
[Unit]
Description=Configure IPv6 AnyIP Local Route
After=network.target
Before=v6-proxy.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip -6 route add local $ROUTED_CIDR dev he-ipv6 2>/dev/null; true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/v6-proxy.service << EOF
[Unit]
Description=v6-proxy IPv6 Random Exit Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v6-proxy --cidr=$ROUTED_CIDR --port=33300 --bind=127.0.0.1 --auto-route=false --force-ipv6
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 4. 保存配置到固定路径供 fix 脚本使用
cp config.sh /etc/v6-proxy-tunnel.conf

# 5. fix-he-ipv6-tunnel.sh
cat > /usr/local/bin/fix-he-ipv6-tunnel.sh << 'FIXSCRIPT'
#!/bin/bash
set -e
[ -f /etc/v6-proxy-tunnel.conf ] && source /etc/v6-proxy-tunnel.conf
TUNNEL_NAME="he-ipv6"
INTERFACE="${PRIMARY_INTERFACE:-enp0s3}"
get_local_ip() { ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d'/' -f1; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

TUNNEL_RECREATED=0
local_ip=$(get_local_ip)
[ -z "$local_ip" ] && { log "无法获取 $INTERFACE IP"; exit 1; }

if ip link show "$TUNNEL_NAME" &>/dev/null; then
    cur=$(ip tunnel show "$TUNNEL_NAME" | grep -oP "local \K[0-9.]+" || echo "")
    if [ "$cur" != "$local_ip" ] || ! ping6 -c 1 -W 2 "$TUNNEL_IPV6_GATEWAY" &>/dev/null; then
        ip link delete "$TUNNEL_NAME" 2>/dev/null || true
        TUNNEL_RECREATED=1
        sleep 1
    fi
fi

if ! ip link show "$TUNNEL_NAME" &>/dev/null; then
    ip tunnel add "$TUNNEL_NAME" mode sit remote "$HE_SERVER_IP" local "$local_ip" ttl 255
    TUNNEL_RECREATED=1
fi

ip link set "$TUNNEL_NAME" up
sleep 1

if ! ip -6 addr show "$TUNNEL_NAME" | grep -q "$TUNNEL_IPV6_CLIENT"; then
    ip -6 addr add "$TUNNEL_IPV6_CLIENT" dev "$TUNNEL_NAME" 2>/dev/null || true
fi
ip -6 route del default dev "$TUNNEL_NAME" 2>/dev/null || true
ip -6 route add default via "$TUNNEL_IPV6_GATEWAY" dev "$TUNNEL_NAME" metric 100 2>/dev/null || true

if ! ip -6 route | grep -q "local $ROUTED_CIDR dev $TUNNEL_NAME"; then
    ip -6 route add local "$ROUTED_CIDR" dev "$TUNNEL_NAME" 2>/dev/null || true
fi

[ "$TUNNEL_RECREATED" = "1" ] && systemctl restart xray 2>/dev/null || true
FIXSCRIPT
chmod +x /usr/local/bin/fix-he-ipv6-tunnel.sh

# 5. v6-proxy-auto-repair.sh
cat > /usr/local/bin/v6-proxy-auto-repair.sh << EOF
#!/bin/bash
set -e
CIDR="$ROUTED_CIDR"
DEV="he-ipv6"
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [v6-proxy-repair] \$*"; }

check_proxy() { curl -sf --connect-timeout 5 --max-time 10 --proxy http://127.0.0.1:33300 http://ipv6.icanhazip.com >/dev/null 2>&1; }

do_repair() {
    log "开始修复..."
    echo 1 > /proc/sys/net/ipv6/ip_nonlocal_bind 2>/dev/null || true
    ip -6 route add local "\$CIDR" dev "\$DEV" 2>/dev/null || true
    systemctl start ipv6-anyip 2>/dev/null || true
    systemctl restart v6-proxy
    sleep 2
    systemctl restart xray
    sleep 2
}

if check_proxy; then
    [ "\${1:-}" = "--force" ] && do_repair || { log "检测正常，无需修复"; exit 0; }
else
    log "检测不通，执行自动修复"
    do_repair
fi

sleep 3
if check_proxy; then log "修复成功"; exit 0; else log "修复后仍不通"; exit 1; fi
EOF
chmod +x /usr/local/bin/v6-proxy-auto-repair.sh

# 6. Xray 安装与配置
XRAY_DIR="/etc/v2ray-agent/xray"
XRAY_CONF="$XRAY_DIR/conf"

install_xray_if_missing() {
    if [ -x "$XRAY_DIR/xray" ]; then
        echo "[4/7] 已检测到 Xray，跳过安装..."
        return 0
    fi
    echo "[4/7] 安装 Xray（自动下载）..."
    mkdir -p "$XRAY_DIR" "$XRAY_CONF"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64" ;;
        aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
        armv7l) XRAY_ARCH="arm32-v7a" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    XRAY_VER=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$XRAY_VER" ] && XRAY_VER="v1.8.12"
    XRAY_ZIP="Xray-linux-${XRAY_ARCH}.zip"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"
    (cd /tmp && (wget -q -O xray.zip "$XRAY_URL" || curl -sL -o xray.zip "$XRAY_URL") && unzip -o -q xray.zip && mv xray "$XRAY_DIR/" && for f in geoip.dat geosite.dat; do [ -f "$f" ] && mv "$f" "$XRAY_DIR/"; done && rm -f xray.zip) || {
        echo "Xray 下载失败，请检查网络"
        exit 1
    }
    chmod +x "$XRAY_DIR/xray"
    for f in geoip.dat geosite.dat; do
        [ -f "$XRAY_DIR/$f" ] || (curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" -o "$XRAY_DIR/$f" 2>/dev/null || true)
    done
    # 基础配置
    echo '{"log":{"loglevel":"warning"}}' > "$XRAY_CONF/00_log.json"
    echo '{"policy":{"levels":{"0":{"handshake":3,"connIdle":261}}}}' > "$XRAY_CONF/12_policy.json"
    # 启动前确保隧道就绪
    cat > /etc/systemd/system/ipv6-tunnel-boot.service << 'BOOTSVC'
[Unit]
Description=HE IPv6 Tunnel Boot
After=network-online.target
Before=xray.service

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do ip link show he-ipv6 &>/dev/null && break; sleep 2; done'
ExecStart=/usr/local/bin/fix-he-ipv6-tunnel.sh
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
BOOTSVC

    # systemd
    cat > /etc/systemd/system/xray.service << 'XRAYSVC'
[Unit]
Description=Xray Service
After=network.target ipv6-tunnel-boot.service
[Service]
User=root
ExecStart=/etc/v2ray-agent/xray/xray run -confdir /etc/v2ray-agent/xray/conf
Restart=on-failure
LimitNPROC=infinity
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
XRAYSVC
}

install_xray_if_missing

if [ -d "$XRAY_CONF" ]; then
    echo "[5/7] 配置 Xray..."
    mkdir -p "$XRAY_CONF"
    
    # v6_proxy outbound
    cat > "$XRAY_CONF/15_v6_proxy_outbound.json" << 'OUT'
{
  "outbounds": [
    {
      "protocol": "http",
      "settings": {
        "servers": [{"address": "127.0.0.1", "port": 33300}]
      },
      "streamSettings": {"sockopt": {"tcpFastOpen": false, "mark": 100}},
      "tag": "v6_proxy_outbound"
    }
  ]
}
OUT

    # Routing
    cat > "$XRAY_CONF/09_routing.json" << 'ROUT'
{
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["VMessWS"], "outboundTag": "v6_proxy_outbound"},
      {"type": "field", "outboundTag": "v6_proxy_outbound", "network": "tcp,udp"}
    ]
  }
}
ROUT

    # VMess IPv6 Random inbounds
    cat > "$XRAY_CONF/13_VMess_WS_IPv6_Random_inbounds.json" << INBOUND
{
"inbounds":[
{"listen": "${ROUTED_PREFIX}::2", "port": 31310, "protocol": "vmess", "tag": "VMessWS_IPv6_1", "settings": {"clients": [{"id": "$VMESS_UUID", "email": "vmess-ipv6-1", "alterId": 0}]}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess-ipv6-random"}}},
{"listen": "${ROUTED_PREFIX}::3", "port": 31311, "protocol": "vmess", "tag": "VMessWS_IPv6_2", "settings": {"clients": [{"id": "$VMESS_UUID", "email": "vmess-ipv6-2", "alterId": 0}]}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess-ipv6-random"}}},
{"listen": "${ROUTED_PREFIX}::4", "port": 31312, "protocol": "vmess", "tag": "VMessWS_IPv6_3", "settings": {"clients": [{"id": "$VMESS_UUID", "email": "vmess-ipv6-3", "alterId": 0}]}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess-ipv6-random"}}},
{"listen": "${ROUTED_PREFIX}::5", "port": 31313, "protocol": "vmess", "tag": "VMessWS_IPv6_4", "settings": {"clients": [{"id": "$VMESS_UUID", "email": "vmess-ipv6-4", "alterId": 0}]}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess-ipv6-random"}}}
]
}
INBOUND

    # DNS 优先 IPv6
    cat > "$XRAY_CONF/11_dns.json" << 'DNS'
{
    "dns": {
        "servers": [
          {"address": "2001:4860:4860::8888", "domains": ["geosite:geolocation-!cn"], "expectIPs": ["geoip:!cn"]},
          {"address": "2001:4860:4860::8844", "domains": ["geosite:geolocation-!cn"], "expectIPs": ["geoip:!cn"]},
          "localhost"
        ],
        "queryStrategy": "UseIPv6",
        "disableCache": false,
        "rules": [{"type": "field", "outboundTag": ["v6_proxy_outbound"], "server": "2001:4860:4860::8888"}]
    }
}
DNS

    cat > "$XRAY_CONF/z_direct_outbound.json" << 'DIRECT'
{"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv6"},"tag":"z_direct_outbound"}]}
DIRECT
fi

# 7. sysctl + 启用服务
echo "[6/7] 系统配置..."
mkdir -p /etc/sysctl.d
echo "net.ipv6.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-ipv6-anyip.conf
sysctl -p /etc/sysctl.d/99-ipv6-anyip.conf 2>/dev/null || true

# 8. 隧道监控 + cron
cat > /etc/systemd/system/he-ipv6-tunnel-monitor.service << 'MON'
[Unit]
Description=HE IPv6 Tunnel Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/fix-he-ipv6-tunnel.sh
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
MON

cat > /etc/systemd/system/he-ipv6-tunnel-monitor.timer << 'TIM'
[Unit]
Description=HE IPv6 Tunnel Timer

[Timer]
OnBootSec=30
OnCalendar=*:0/2
Persistent=true
Unit=he-ipv6-tunnel-monitor.service
AccuracySec=30

[Install]
WantedBy=timers.target
TIM

systemctl daemon-reload
systemctl enable ipv6-anyip v6-proxy he-ipv6-tunnel-monitor.timer ipv6-tunnel-boot xray

# Cron 每分钟检测修复
(crontab -l 2>/dev/null | grep -v v6-proxy-auto-repair; echo '* * * * * /usr/local/bin/v6-proxy-auto-repair.sh >> /var/log/v6-proxy-repair.log 2>&1') | crontab -

echo "[7/7] 应用网络并启动..."
netplan apply 2>/dev/null || true
systemctl start ipv6-anyip
systemctl start v6-proxy
systemctl start he-ipv6-tunnel-monitor.timer
systemctl restart xray 2>/dev/null || true

echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo "VMess 地址: ${ROUTED_PREFIX}::2~5, 端口 31310-31313, 路径 /vmess-ipv6-random"
echo "测试: curl --proxy http://127.0.0.1:33300 http://ipv6.icanhazip.com"
echo "=========================================="
