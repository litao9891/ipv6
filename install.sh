#!/bin/bash
# 随机 IPv6（TunnelBroker + v6-proxy + Xray VMess）一键部署 / 仅应用配置
# 首次安装: sudo bash install.sh
# 仅根据 config.sh 重写系统配置并重启: sudo bash install.sh --config-only
set -euo pipefail
cd "$(dirname "$0")"

CONFIG_ONLY=0
[[ "${1:-}" == "--config-only" ]] && CONFIG_ONLY=1

if [[ "$(id -u)" -ne 0 ]] && [[ "$CONFIG_ONLY" -eq 0 ]]; then
  echo "请使用 root 运行: sudo bash $0"
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]] && [[ "$CONFIG_ONLY" -eq 1 ]]; then
  echo "--config-only 需要 root"
  exit 1
fi

if [[ ! -f config.sh ]]; then
  echo "缺少 config.sh"
  exit 1
fi
# shellcheck disable=SC1091
source config.sh

# 自动补全
if [[ -z "${TUNNEL_LOCAL_IPV4:-}" ]]; then
  TUNNEL_LOCAL_IPV4="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{print $7;exit}' || true)"
fi
if [[ -z "${TUNNEL_LOCAL_IPV4:-}" ]]; then
  echo "无法探测 TUNNEL_LOCAL_IPV4，请在 config.sh 中设置"
  exit 1
fi
if [[ -z "${CLIENT_INTERNAL_IP:-}" ]]; then
  CLIENT_INTERNAL_IP="$TUNNEL_LOCAL_IPV4"
fi
if [[ -z "${PRIMARY_INTERFACE:-}" ]]; then
  PRIMARY_INTERFACE="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' || true)"
fi
[[ -z "${PRIMARY_INTERFACE:-}" ]] && PRIMARY_INTERFACE="enp0s3"

: "${VMESS_WS_PATH:=/vmess-ipv6}"
: "${VMESS_PORT_64:=48442}"
: "${VMESS_PORT_48:=54661}"

# 仓库示例 UUID / 空值 会导致客户端与「占位」一致或易混淆；首次安装自动替换并写回 config.sh
PLACEHOLDER_VMESS_UUID="00000000-0000-4000-8000-000000000001"
ensure_vmess_uuid() {
  if [[ -n "${VMESS_UUID:-}" ]] && [[ "$VMESS_UUID" != "$PLACEHOLDER_VMESS_UUID" ]]; then
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    VMESS_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    VMESS_UUID="$(python3 -c 'import uuid; print(str(uuid.uuid4()))')"
  fi
  echo "[install] 已生成新的 VMess UUID 并写入本目录 config.sh（请勿使用仓库占位 UUID）"
  if [[ -f config.sh ]] && grep -qE '^[[:space:]]*VMESS_UUID=' config.sh; then
    sed -i "s|^[[:space:]]*VMESS_UUID=.*|VMESS_UUID=\"${VMESS_UUID}\"|" config.sh
  else
    printf '\nVMESS_UUID="%s"\n' "$VMESS_UUID" >>config.sh
  fi
}
ensure_vmess_uuid

write_tunnel_conf() {
  cat > /etc/v6-proxy-tunnel.conf << EOF
# ============================================================
# 随机 IPv6 部署配置（由 install.sh 写入）
# ============================================================
HE_SERVER_IP="${HE_SERVER_IP}"
CLIENT_INTERNAL_IP="${CLIENT_INTERNAL_IP}"
TUNNEL_LOCAL_IPV4="${TUNNEL_LOCAL_IPV4}"
TUNNEL_IPV6_PREFIX="${TUNNEL_IPV6_PREFIX}"
TUNNEL_IPV6_CLIENT="${TUNNEL_IPV6_CLIENT}"
TUNNEL_IPV6_GATEWAY="${TUNNEL_IPV6_GATEWAY}"
ROUTED_64_CIDR="${ROUTED_64_CIDR}"
ROUTED_48_CIDR="${ROUTED_48_CIDR}"
PRIMARY_INTERFACE="${PRIMARY_INTERFACE}"
EOF
}

write_netplan() {
  cat > /etc/netplan/99-he-tunnel.yaml << EOF
network:
  version: 2
  tunnels:
    he-ipv6:
      mode: sit
      remote: ${HE_SERVER_IP}
      local: ${TUNNEL_LOCAL_IPV4}
      addresses:
        - "${TUNNEL_IPV6_CLIENT}"
      routes:
        - to: default
          via: "${TUNNEL_IPV6_GATEWAY}"
          metric: 100
EOF
}

write_systemd_units() {
  cat > /etc/systemd/system/ipv6-anyip.service << EOF
[Unit]
Description=Configure IPv6 AnyIP Local Route (/48 + /64)
After=network.target
Before=v6-proxy.service v6-proxy-48.service v6-proxy-64.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip -6 route add local ${ROUTED_64_CIDR} dev he-ipv6 2>/dev/null; ip -6 route add local ${ROUTED_48_CIDR} dev he-ipv6 2>/dev/null; true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/v6-proxy.service << EOF
[Unit]
Description=v6-proxy IPv6 Random Exit (/64 → 33300)
After=network.target ipv6-anyip.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v6-proxy --cidr=${ROUTED_64_CIDR} --port=33300 --bind=127.0.0.1 --auto-route=false --auto-forwarding=false --auto-ip-nonlocal-bind=false
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/v6-proxy-48.service << EOF
[Unit]
Description=v6-proxy IPv6 Random Exit (/48 → 33301)
After=network.target ipv6-anyip.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v6-proxy --cidr=${ROUTED_48_CIDR} --port=33301 --bind=127.0.0.1 --auto-route=false --auto-forwarding=false --auto-ip-nonlocal-bind=false
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/v6-proxy-64.service << EOF
[Unit]
Description=v6-proxy IPv6 Random Exit (/64 备用 → 33302)
After=network.target ipv6-anyip.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v6-proxy --cidr=${ROUTED_64_CIDR} --port=33302 --bind=127.0.0.1 --auto-route=false --auto-forwarding=false --auto-ip-nonlocal-bind=false
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_fix_script() {
  cat > /usr/local/bin/fix-he-ipv6-tunnel.sh << 'FIXEOF'
#!/bin/bash
set -e
[ -f /etc/v6-proxy-tunnel.conf ] && source /etc/v6-proxy-tunnel.conf
TUNNEL_NAME="he-ipv6"
INTERFACE="${PRIMARY_INTERFACE:-enp0s3}"
get_local_ip() { ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d'/' -f1; }

local_ip="${TUNNEL_LOCAL_IPV4:-$(get_local_ip)}"
[ -z "$local_ip" ] && { echo "[$(date '+%Y-%m-%d %H:%M:%S')] 无法获取隧道 local IPv4"; exit 1; }

TUNNEL_RECREATED=0
if ip link show "$TUNNEL_NAME" &>/dev/null; then
 cur_local=$(ip tunnel show "$TUNNEL_NAME" | grep -oP "local \K[0-9.]+" || echo "")
 cur_remote=$(ip tunnel show "$TUNNEL_NAME" | grep -oP "remote \K[0-9.]+" || echo "")
 if [ "$cur_local" != "$local_ip" ] || [ "$cur_remote" != "$HE_SERVER_IP" ]; then
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

if ! ip -6 addr show "$TUNNEL_NAME" | grep -q "${TUNNEL_IPV6_CLIENT%/64}"; then
 ip -6 addr add "$TUNNEL_IPV6_CLIENT" dev "$TUNNEL_NAME" 2>/dev/null || true
fi
ip -6 route del default dev "$TUNNEL_NAME" 2>/dev/null || true
ip -6 route replace default via "$TUNNEL_IPV6_GATEWAY" dev "$TUNNEL_NAME" metric 100 2>/dev/null || \
 ip -6 route add default via "$TUNNEL_IPV6_GATEWAY" dev "$TUNNEL_NAME" metric 100 2>/dev/null || true

for cidr in "$ROUTED_64_CIDR" "$ROUTED_48_CIDR"; do
 [ -n "$cidr" ] && ip -6 route replace local "$cidr" dev "$TUNNEL_NAME" 2>/dev/null || \
  ip -6 route add local "$cidr" dev "$TUNNEL_NAME" 2>/dev/null || true
done
[ "$TUNNEL_RECREATED" = "1" ] && systemctl restart v6-proxy.service v6-proxy-48.service v6-proxy-64.service 2>/dev/null || true
FIXEOF
  chmod +x /usr/local/bin/fix-he-ipv6-tunnel.sh
}

write_auto_repair() {
  cat > /usr/local/bin/v6-proxy-auto-repair.sh << EOF
#!/bin/bash
set -e
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [v6-proxy-repair] \$*"; }

check_proxy() {
  curl -sf --connect-timeout 5 --max-time 12 --proxy http://127.0.0.1:33300 http://ipv6.icanhazip.com >/dev/null 2>&1 \\
   && curl -sf --connect-timeout 5 --max-time 12 --proxy http://127.0.0.1:33301 http://ipv6.icanhazip.com >/dev/null 2>&1
}

do_repair() {
 log "开始修复..."
 echo 1 > /proc/sys/net/ipv6/ip_nonlocal_bind 2>/dev/null || true
 systemctl start ipv6-anyip 2>/dev/null || true
 /usr/local/bin/fix-he-ipv6-tunnel.sh 2>/dev/null || true
 systemctl restart v6-proxy.service v6-proxy-48.service v6-proxy-64.service 2>/dev/null || true
 sleep 2
 systemctl restart xray 2>/dev/null || true
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
}

write_xray_fragments() {
  local XRAY_DIR="/etc/v2ray-agent/xray"
  local XRAY_CONF="$XRAY_DIR/conf"
  mkdir -p "$XRAY_CONF"

  cat > "$XRAY_CONF/00_log.json" << 'EOF'
{"log":{"loglevel":"warning"}}
EOF
  cat > "$XRAY_CONF/12_policy.json" << 'EOF'
{"policy":{"levels":{"0":{"handshake":3,"connIdle":261}}}}
EOF

  cat > "$XRAY_CONF/15_v6_proxy_outbound.json" << EOF
{
  "outbounds": [
    {
      "protocol": "http",
      "settings": {"servers": [{"address": "127.0.0.1", "port": 33300}]},
      "streamSettings": {"sockopt": {"tcpFastOpen": false, "mark": 100}},
      "tag": "v6_proxy_64_outbound"
    },
    {
      "protocol": "http",
      "settings": {"servers": [{"address": "127.0.0.1", "port": 33301}]},
      "streamSettings": {"sockopt": {"tcpFastOpen": false, "mark": 101}},
      "tag": "v6_proxy_48_outbound"
    }
  ]
}
EOF

  cat > "$XRAY_CONF/09_routing.json" << 'EOF'
{
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["VMess_64"], "outboundTag": "v6_proxy_64_outbound"},
      {"type": "field", "inboundTag": ["VMess_48"], "outboundTag": "v6_proxy_48_outbound"}
    ]
  }
}
EOF

  cat > "$XRAY_CONF/13_VMess_64_48_inbounds.json" << EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT_64},
      "protocol": "vmess",
      "tag": "VMess_64",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${VMESS_WS_PATH}"}
      }
    },
    {
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT_48},
      "protocol": "vmess",
      "tag": "VMess_48",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${VMESS_WS_PATH}"}
      }
    }
  ]
}
EOF

  cat > "$XRAY_CONF/11_dns.json" << 'EOF'
{
  "dns": {
    "servers": [
      {"address": "2001:4860:4860::8888", "domains": ["geosite:geolocation-!cn"], "expectIPs": ["geoip:!cn"]},
      "localhost"
    ],
    "queryStrategy": "UseIPv6",
    "disableCache": false
  }
}
EOF

  cat > "$XRAY_CONF/z_direct_outbound.json" << 'EOF'
{"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv6"},"tag":"z_direct_outbound"}]}
EOF
}

write_xray_systemd() {
  cat > /etc/systemd/system/xray.service << 'EOF'
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
EOF

  cat > /etc/systemd/system/ipv6-tunnel-boot.service << 'EOF'
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
EOF

  cat > /etc/systemd/system/he-ipv6-tunnel-monitor.service << 'EOF'
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
EOF

  cat > /etc/systemd/system/he-ipv6-tunnel-monitor.timer << 'EOF'
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
EOF
}

install_v6_proxy_binary() {
  local ARCH BIN_URL
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    BIN_URL="https://github.com/zbronya/v6-proxy/releases/latest/download/v6-proxy-linux-amd64"
  elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    BIN_URL="https://github.com/zbronya/v6-proxy/releases/latest/download/v6-proxy-linux-arm64"
  else
    echo "不支持的架构: $ARCH"
    exit 1
  fi
  if [[ -f ./v6-proxy ]]; then
    cp ./v6-proxy /usr/local/bin/v6-proxy
  elif [[ ! -x /usr/local/bin/v6-proxy ]]; then
    echo "[install] 正在下载 v6-proxy（若久无输出，请检查能否访问 GitHub）..."
    if command -v curl >/dev/null 2>&1; then
      curl -fL --connect-timeout 20 --max-time 300 -o /usr/local/bin/v6-proxy "$BIN_URL" || {
        echo "[install] curl 失败，尝试 wget..."
        wget -q --timeout=300 -O /usr/local/bin/v6-proxy "$BIN_URL"
      }
    else
      wget -q --timeout=300 -O /usr/local/bin/v6-proxy "$BIN_URL"
    fi
  fi
  chmod +x /usr/local/bin/v6-proxy
}

install_xray_if_missing() {
  local XRAY_DIR="/etc/v2ray-agent/xray"
  if [[ -x "$XRAY_DIR/xray" ]]; then
    return 0
  fi
  echo "[install] 下载 Xray（查询版本与拉包可能需要 1～3 分钟，请稍候）..."
  mkdir -p "$XRAY_DIR" "$XRAY_DIR/conf"
  local ARCH XRAY_ARCH XRAY_VER XRAY_ZIP XRAY_URL
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l) XRAY_ARCH="arm32-v7a" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
  esac
  XRAY_VER=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | head -1)
  [[ -z "$XRAY_VER" ]] && XRAY_VER="v25.1.1"
  echo "[install] 使用 Xray 版本: $XRAY_VER"
  XRAY_ZIP="Xray-linux-${XRAY_ARCH}.zip"
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"
  (cd /tmp && rm -f xray.zip && (curl -fL --connect-timeout 30 --max-time 600 -o xray.zip "$XRAY_URL" || wget -q --timeout=600 -O xray.zip "$XRAY_URL") && unzip -o -q xray.zip && mv xray "$XRAY_DIR/" && for f in geoip.dat geosite.dat; do [[ -f "$f" ]] && mv "$f" "$XRAY_DIR/"; done && rm -f xray.zip) || {
    echo "Xray 下载失败（网络或 GitHub 受限），请换网络或代理后重试"
    exit 1
  }
  chmod +x "$XRAY_DIR/xray"
  for f in geoip.dat geosite.dat; do
    [[ -f "$XRAY_DIR/$f" ]] || curl -fsSL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" -o "$XRAY_DIR/$f" 2>/dev/null || true
  done
}

apply_sysctl_cron() {
  mkdir -p /etc/sysctl.d
  echo "net.ipv6.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-ipv6-anyip.conf
  sysctl -p /etc/sysctl.d/99-ipv6-anyip.conf 2>/dev/null || true
  (crontab -l 2>/dev/null | grep -v v6-proxy-auto-repair; echo '* * * * * /usr/local/bin/v6-proxy-auto-repair.sh >> /var/log/v6-proxy-repair.log 2>&1') | crontab -
}

restart_stack() {
  systemctl daemon-reload
  netplan apply 2>/dev/null || true
  /usr/local/bin/fix-he-ipv6-tunnel.sh 2>/dev/null || true
  systemctl enable ipv6-anyip v6-proxy v6-proxy-48 v6-proxy-64 ipv6-tunnel-boot he-ipv6-tunnel-monitor.timer xray 2>/dev/null || true
  systemctl restart ipv6-anyip.service 2>/dev/null || true
  systemctl restart v6-proxy.service v6-proxy-48.service v6-proxy-64.service 2>/dev/null || true
  systemctl restart xray.service 2>/dev/null || true
  systemctl start he-ipv6-tunnel-monitor.timer 2>/dev/null || true
}

public_ip_for_vmess() {
  if [[ -n "${HE_CLIENT_IPV4_PUBLIC:-}" ]]; then
    echo "$HE_CLIENT_IPV4_PUBLIC"
    return
  fi
  curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || echo "127.0.0.1"
}

print_inbound_client_hint() {
  echo ""
  echo "[install] 客户端入站：请在云安全组/防火墙放行 TCP ${VMESS_PORT_64}、${VMESS_PORT_48}（WebSocket，路径 ${VMESS_WS_PATH}，无 TLS）"
  echo "[install] 若本机自检通过但外网连不上，多半是上述端口未对公网开放。"
}

write_vmess_links_file() {
  local pub path64 path48
  pub="$(public_ip_for_vmess)"
  path64="${VMESS_WS_PATH:-/vmess-ipv6}"
  path48="$path64"
  python3 << PY
import json, base64
pub = "${pub}"
uuid = "${VMESS_UUID}"
p64 = int("${VMESS_PORT_64}")
p48 = int("${VMESS_PORT_48}")
path = "${path64}"

def link(ps, port):
    o = {
        "v": "2",
        "ps": ps,
        "add": pub,
        "port": str(port),
        "id": uuid,
        "aid": "0",
        "scy": "auto",
        "net": "ws",
        "type": "none",
        "host": "",
        "path": path,
        "tls": "none",
    }
    return "vmess://" + base64.b64encode(
        json.dumps(o, separators=(",", ":"), ensure_ascii=False).encode()
    ).decode()

lines = [
    "# VMess（随机 IPv6 出口：/64 与 /48）",
    "# 生成时间: $(date -Iseconds)",
    f"# 公网展示: {pub}  隧道 local(内网): ${TUNNEL_LOCAL_IPV4}",
    "",
    "## " + pub + "+64",
    link(pub + "+64", p64),
    "",
    "## " + pub + "+48",
    link(pub + "+48", p48),
    "",
]
open("vmess-links.txt", "w", encoding="utf-8").write("\\n".join(lines) + "\\n")
for x in lines:
    if x.startswith("vmess://"):
        print(x)
PY
}

run_self_tests() {
  echo ""
  echo "======== 自检 ========"
  local ok=1
  if ping6 -c 2 -W 4 "${TUNNEL_IPV6_GATEWAY}" >/dev/null 2>&1; then
    echo "ping6 网关 OK"
  else
    echo "ping6 网关 无响应（若下方 v6-proxy 正常可忽略）"
  fi
  local o64 o48
  o64="$(curl -sf --max-time 15 --proxy http://127.0.0.1:33300 http://ipv6.icanhazip.com || true)"
  o48="$(curl -sf --max-time 15 --proxy http://127.0.0.1:33301 http://ipv6.icanhazip.com || true)"
  if [[ -n "$o64" ]]; then echo "v6-proxy /64 → $o64"; else echo "v6-proxy 33300 失败"; ok=0; fi
  if [[ -n "$o48" ]]; then echo "v6-proxy /48 → $o48"; else echo "v6-proxy 33301 失败"; ok=0; fi
  [[ "$ok" -eq 1 ]] && echo "======== 核心自检通过（随机 IPv6 出口可用）========" || echo "======== v6-proxy 异常，请查隧道/防火墙/HE 控制台 Client IPv4 =========="
}

render_all_configs() {
  write_tunnel_conf
  write_netplan
  write_systemd_units
  write_fix_script
  write_auto_repair
  write_xray_fragments
  write_xray_systemd
}

# --- 入口 ---
if [[ "$CONFIG_ONLY" -eq 1 ]]; then
  echo "[install] --config-only: 写入系统配置并重启服务"
  render_all_configs
  restart_stack
  sleep 2
  run_self_tests
  echo ""
  echo "[install] vmess-links.txt 与 vmess:// 如下:"
  write_vmess_links_file
  print_inbound_client_hint
  exit 0
fi

echo "=========================================="
echo "随机 IPv6 一键部署"
echo "HE Server: $HE_SERVER_IP"
echo "隧道 local(内网): $TUNNEL_LOCAL_IPV4"
echo "隧道链路: $TUNNEL_IPV6_CLIENT"
echo "Routed /64: $ROUTED_64_CIDR"
echo "Routed /48: $ROUTED_48_CIDR"
echo "主网卡: $PRIMARY_INTERFACE"
echo "VMess: ${VMESS_PORT_64}(/64) ${VMESS_PORT_48}(/48) path=${VMESS_WS_PATH}"
echo "=========================================="
if [[ -t 0 ]] && [[ "${SKIP_CONFIRM:-0}" != "1" ]]; then
  echo ""
  echo ">>> 停在这里不是卡死：请核对上面参数，确认后按【回车】继续下载与安装 <<<"
  echo "    （全自动可: SKIP_CONFIRM=1 sudo bash $0）"
  echo ""
  read -r -p "按回车继续，Ctrl+C 取消..."
else
  echo "跳过确认（非交互或 SKIP_CONFIRM=1），继续安装..."
fi

install_v6_proxy_binary
install_xray_if_missing
render_all_configs
apply_sysctl_cron

systemctl daemon-reload
systemctl enable ipv6-anyip v6-proxy v6-proxy-48 v6-proxy-64 ipv6-tunnel-boot he-ipv6-tunnel-monitor.timer xray

netplan apply 2>/dev/null || true
/usr/local/bin/fix-he-ipv6-tunnel.sh 2>/dev/null || true
systemctl start ipv6-anyip
systemctl start v6-proxy v6-proxy-48 v6-proxy-64
systemctl start he-ipv6-tunnel-monitor.timer
systemctl restart xray 2>/dev/null || true

sleep 2
run_self_tests
write_vmess_links_file
print_inbound_client_hint

echo ""
echo "部署完成。详情见 README.md；换隧道可运行: sudo bash apply-he-paste.sh"
