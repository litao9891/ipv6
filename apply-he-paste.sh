#!/bin/bash
# 从 TunnelBroker 控制台复制的一大段文字中解析参数，写入 config.sh，
# 将 netplan local= 设为内网 IPv4（ip route get 8.8.8.8），应用配置、自检并输出 VMess。
#
# 用法:
#   sudo bash apply-he-paste.sh                    # 粘贴后 Ctrl+D 结束
#   sudo bash apply-he-paste.sh he.txt             # 从文件读
#   cat he.txt | sudo bash apply-he-paste.sh
#
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行: sudo bash $0"
  exit 1
fi

if [[ -n "${1:-}" ]]; then
  PASTE="$(cat -- "$1")"
else
  if [[ -t 0 ]]; then
    echo "请粘贴 TunnelBroker 信息（含 Server IPv4、Client IPv4/IPv6、Routed /64 /48、可选 netplan 片段），输入结束后按 Ctrl+D:" >&2
  fi
  PASTE="$(cat)"
fi

if [[ -z "${PASTE//[$'\t\n\r ']/}" ]]; then
  echo "未读取到内容"
  exit 1
fi

extract() {
  local pattern="$1"
  echo "$PASTE" | grep -oiE "$pattern" | head -1 | sed -E 's/^[^:0-9]*//; s/^[^0-9a-fA-F]*//; s/\[[^\]]*\]//g; s/[[:space:]]+$//' || true
}

HE_SERVER_IP="$(extract 'Server IPv4 Address:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+$' || true)"
[[ -z "$HE_SERVER_IP" ]] && HE_SERVER_IP="$(echo "$PASTE" | grep -oiE 'remote:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+$' || true)"

HE_CLIENT_IPV4_PUBLIC="$(extract 'Client IPv4 Address:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+$' || true)"

CLIENT_V6_LINE="$(echo "$PASTE" | grep -oiE 'Client IPv6 Address:[[:space:]]*[^[:space:]]+' || true)"
CLIENT_V6="${CLIENT_V6_LINE#*:}"
CLIENT_V6="${CLIENT_V6#Client IPv6 Address:}"
CLIENT_V6="${CLIENT_V6//[[:space:]]/}"
[[ -z "$CLIENT_V6" ]] && CLIENT_V6="$(echo "$PASTE" | grep -oiE '"2001:[0-9a-fA-F:]+::2/64"' | tr -d '"' || true)"
[[ -z "$CLIENT_V6" ]] && CLIENT_V6="$(echo "$PASTE" | grep -oiE '2001:[0-9a-fA-F:]+::2/64' | head -1 || true)"

ROUTED_64_CIDR="$(echo "$PASTE" | grep -oiE 'Routed /64:[[:space:]]*2001:[0-9a-fA-F:/]+' | head -1 | sed -E 's|.*Routed /64:||; s/[[:space:]]+//g' || true)"
ROUTED_48_LINE="$(echo "$PASTE" | grep -oiE 'Routed /48:[[:space:]]*2001:[0-9a-fA-F:/]+' | head -1 || true)"
ROUTED_48_CIDR="$(echo "$ROUTED_48_LINE" | sed -E 's|.*Routed /48:||; s/[[:space:]]+//g; s/\[X\]//gi; s/\[.\]//g')"

if [[ -z "$HE_SERVER_IP" || -z "$CLIENT_V6" || -z "$ROUTED_64_CIDR" || -z "$ROUTED_48_CIDR" ]]; then
  echo "解析失败，至少需要: Server IPv4、Client IPv6(::2/64)、Routed /64、Routed /48"
  echo "已解析: HE_SERVER_IP=[$HE_SERVER_IP] CLIENT_V6=[$CLIENT_V6] ROUTED_64=[$ROUTED_64_CIDR] ROUTED_48=[$ROUTED_48_CIDR]"
  exit 1
fi

if [[ "$CLIENT_V6" != *::2/64* ]]; then
  echo "警告: Client IPv6 未以 ::2/64 结尾，仍尝试截取前缀: $CLIENT_V6" >&2
fi

TUNNEL_IPV6_PREFIX="${CLIENT_V6%::2/64}"
if [[ "$TUNNEL_IPV6_PREFIX" == "$CLIENT_V6" ]]; then
  echo "无法从 Client IPv6 推导前缀（需要 ...::2/64 格式）: $CLIENT_V6"
  exit 1
fi

TUNNEL_LOCAL_IPV4="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{print $7;exit}' || true)"
if [[ -z "$TUNNEL_LOCAL_IPV4" ]]; then
  echo "无法通过 'ip -4 route get 8.8.8.8' 得到内网源 IP，请手工在 config.sh 设置 TUNNEL_LOCAL_IPV4"
  exit 1
fi

PRIMARY_INTERFACE="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' || true)"
[[ -z "$PRIMARY_INTERFACE" ]] && PRIMARY_INTERFACE="enp0s3"

VMESS_UUID="00b27eb5-deed-451e-8bea-9006726793ca"
VMESS_PORT_64="48442"
VMESS_PORT_48="54661"
VMESS_WS_PATH="/vmess-ipv6"
if [[ -f config.sh ]]; then
  # 仅保留 VMess 相关行，避免旧 HE 参数覆盖本次解析结果
  # shellcheck disable=SC1090
  eval "$(grep -E '^VMESS_(UUID|PORT_64|PORT_48|WS_PATH)=' config.sh 2>/dev/null | grep -v '^#' || true)"
fi

CLIENT_INTERNAL_IP="$TUNNEL_LOCAL_IPV4"

if [[ -z "$HE_CLIENT_IPV4_PUBLIC" ]]; then
  HE_CLIENT_IPV4_PUBLIC="$(curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
fi

write_config() {
  cat > config.sh << CFGEOF
# ============================================================
# 随机 IPv6 部署配置（由 apply-he-paste.sh 生成 / 更新）
# 时间: $(date -Iseconds)
# ============================================================

HE_SERVER_IP="${HE_SERVER_IP}"
HE_CLIENT_IPV4_PUBLIC="${HE_CLIENT_IPV4_PUBLIC}"
TUNNEL_LOCAL_IPV4="${TUNNEL_LOCAL_IPV4}"
CLIENT_INTERNAL_IP="${CLIENT_INTERNAL_IP}"

TUNNEL_IPV6_PREFIX="${TUNNEL_IPV6_PREFIX}"
TUNNEL_IPV6_CLIENT="\${TUNNEL_IPV6_PREFIX}::2/64"
TUNNEL_IPV6_GATEWAY="\${TUNNEL_IPV6_PREFIX}::1"

ROUTED_64_CIDR="${ROUTED_64_CIDR}"
ROUTED_48_CIDR="${ROUTED_48_CIDR}"

PRIMARY_INTERFACE="${PRIMARY_INTERFACE}"

VMESS_UUID="${VMESS_UUID}"
VMESS_PORT_64="${VMESS_PORT_64}"
VMESS_PORT_48="${VMESS_PORT_48}"
VMESS_WS_PATH="${VMESS_WS_PATH}"
CFGEOF
}

write_config
echo "[apply-he-paste] 已写入 config.sh"
echo "  HE_SERVER_IP=$HE_SERVER_IP"
echo "  HE_CLIENT_IPV4_PUBLIC=$HE_CLIENT_IPV4_PUBLIC (VMess 展示用)"
echo "  TUNNEL_LOCAL_IPV4=$TUNNEL_LOCAL_IPV4 (netplan/SIT local)"
echo "  TUNNEL_IPV6_PREFIX=$TUNNEL_IPV6_PREFIX"
echo "  ROUTED_64_CIDR=$ROUTED_64_CIDR"
echo "  ROUTED_48_CIDR=$ROUTED_48_CIDR"
echo "  PRIMARY_INTERFACE=$PRIMARY_INTERFACE"

exec bash ./install.sh --config-only
