# ============================================================
# 随机 IPv6 部署配置
# 推荐：在 VPS 上执行 sudo bash apply-he-paste.sh 从 HE 控制台粘贴自动生成。
# 或手工修改下列变量后执行 sudo bash install.sh
# ============================================================

# HE 隧道服务器 IPv4（TunnelBroker → Server IPv4 Address）
HE_SERVER_IP="CHANGE_ME"

# TunnelBroker 控制台里的 Client IPv4（公网，用于 VMess 地址展示；可先留空后由脚本填充）
HE_CLIENT_IPV4_PUBLIC=""

# SIT / netplan 的 local= 须为「默认出口内网源地址」；留空则 install / apply-he-paste 自动探测
TUNNEL_LOCAL_IPV4=""
CLIENT_INTERNAL_IP=""

# 隧道链路前缀：来自 Client IPv6 Address 中 ::2/64 前一段（例 2001:470:c:12e5::2/64 → 2001:470:c:12e5）
TUNNEL_IPV6_PREFIX="2001:470:c:12e5"
TUNNEL_IPV6_CLIENT="${TUNNEL_IPV6_PREFIX}::2/64"
TUNNEL_IPV6_GATEWAY="${TUNNEL_IPV6_PREFIX}::1"

# HE Routed 前缀
ROUTED_64_CIDR="2001:470:d:12e1::/64"
ROUTED_48_CIDR="2001:470:example::/48"

# 主网卡；留空则自动从 default route 推断
PRIMARY_INTERFACE=""

# VMess：留空或保持占位则首次 install 会自动 uuidgen 并写回本文件（勿多人共用示例 UUID）
VMESS_UUID=""
VMESS_PORT_64="48442"
VMESS_PORT_48="54661"
VMESS_WS_PATH="/vmess-ipv6"

# IPv4 出站封锁开关：0=默认不启用（推荐）；1=启用
BLOCK_IPV4_OUTBOUND="0"
# 封锁模式：proxy_only=仅限制代理进程（推荐）；global=全机 OUTPUT（风险较高）
IPV4_BLOCK_MODE="proxy_only"
