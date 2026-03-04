# 随机 IPv6 + VMess 部署包

本机通过 TunnelBroker + v6-proxy + Xray 实现随机 IPv6 出口，仅 IPv4 拒绝，带自动修复。

## 功能
- 随机 IPv6 出口（从 Routed /64 中随机）
- VMess WebSocket 入站
- 仅 IPv6，不返回 IPv4（--force-ipv6）
- 每分钟自动检测并修复
- IP 变化时隧道自动修复

## 前提
- 新 VPS 已申请 [TunnelBroker.net](https://tunnelbroker.net) 隧道
- 新 VPS 已安装 v2ray-agent（Xray）

## 部署到新 VPS

### 1. 下载部署包

在当前 VPS 上打包：
```bash
cd /root
tar czvf v6-proxy-random-ipv6-deploy.tar.gz v6-proxy-random-ipv6-deploy/
# 用 scp 或对象存储下载到本地，再上传到新 VPS
```

### 2. 在新 VPS 上修改配置

解压后编辑 `config.sh`，填入**新 VPS** 的 TunnelBroker 参数：

| 参数 | 说明 | 示例 |
|------|------|------|
| HE_SERVER_IP | HE 隧道服务器 IPv4 | 66.220.18.42 |
| CLIENT_INTERNAL_IP | 本机内网 IPv4 | 10.0.0.83 |
| TUNNEL_IPV6_PREFIX | 隧道链路前缀（Client ::2, Gateway ::1） | 2001:470:c:12e5 |
| ROUTED_PREFIX | 随机出口的 /64 前缀 | 2001:470:d:12e1 |
| PRIMARY_INTERFACE | 主网卡名 | enp0s3 或 eth0 |

在 TunnelBroker 控制台可看到：
- Server IPv4 Address → HE_SERVER_IP
- Client IPv4 Address → 填**内网 IP**（如 10.0.0.83）
- Client IPv6 Address → 推导 TUNNEL_IPV6_PREFIX（如 2001:470:c:12e5::2/64 → 2001:470:c:12e5）
- Routed /64 → 推导 ROUTED_PREFIX（如 2001:470:d:12e1::/64 → 2001:470:d:12e1）

### 3. 运行安装

```bash
cd v6-proxy-random-ipv6-deploy
sudo bash install.sh
```

### 4. 验证

```bash
curl --proxy http://127.0.0.1:33300 http://ipv6.icanhazip.com
# 应返回 2001:470:xx:xx:xxxx:xxxx:xxxx:xxxx 形式
```

## 换 IP 后

VPS 公网 IP 变更时：

1. 在 TunnelBroker 控制台把 **Client IPv4 Address** 改为新公网 IP
2. 若内网 IP 也变，编辑 `/etc/v6-proxy-tunnel.conf` 中的 `CLIENT_INTERNAL_IP`
3. 执行：
   ```bash
   ip link delete he-ipv6 2>/dev/null
   netplan apply
   systemctl start ipv6-anyip
   systemctl restart v6-proxy xray
   ```
   或运行：`/usr/local/bin/fix-he-ipv6-tunnel.sh`

## 文件说明

- config.sh - 部署参数（换 VPS 必改）
- install.sh - 一键安装
- v6-proxy - 二进制（可选，无则自动下载）
- README.md - 本说明
