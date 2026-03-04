# ============================================================
# 随机 IPv6 部署配置 - 换 VPS 时修改此处
# 从 TunnelBroker.net 获取这些值
# ============================================================

# HE 隧道服务器 IPv4
HE_SERVER_IP="66.220.18.42"

# 本机内网 IPv4（VPS 主网卡 IP，如 10.0.0.83）
CLIENT_INTERNAL_IP="10.0.0.83"

# 隧道链路 IPv6 网段（/64，Client 用 ::2，Server 用 ::1）
TUNNEL_IPV6_PREFIX="2001:470:c:12e5"
TUNNEL_IPV6_CLIENT="${TUNNEL_IPV6_PREFIX}::2/64"
TUNNEL_IPV6_GATEWAY="${TUNNEL_IPV6_PREFIX}::1"

# 随机出口的 Routed /64 网段
ROUTED_PREFIX="2001:470:d:12e1"
ROUTED_CIDR="${ROUTED_PREFIX}::/64"

# 主网卡名称（enp0s3 或 eth0）
PRIMARY_INTERFACE="enp0s3"

# VMess UUID
VMESS_UUID="00b27eb5-deed-451e-8bea-9006726793ca"
