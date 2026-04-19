# 随机 IPv6 + VMess 部署包

本机通过 [TunnelBroker](https://tunnelbroker.net/) + [v6-proxy](https://github.com/zbronya/v6-proxy) + [Xray](https://github.com/XTLS/Xray-core) 实现从 HE 下发的 **Routed /64** 与 **Routed /48** 中随机选源 IPv6 出站；入站为两条 **VMess over WebSocket**（分别走 /64 与 /48 的本地 HTTP 代理）。

仓库：**[litao9891/ipv6](https://github.com/litao9891/ipv6)**

## 功能概要

- 双随机 IPv6 出口：**Routed /64**（`127.0.0.1:33300`）与 **Routed /48**（`127.0.0.1:33301`）
- **VMess + WS**：`0.0.0.0` 监听，路由按入站标签分流到上述两个代理
- **Netplan SIT** 隧道：`local` 使用 **内网 IPv4**（`ip -4 route get 8.8.8.8` 的 `src`），与 HE 控制台里填写的 Client IPv4（公网）可不一致（适合 Oracle 等仅内网走协议 41 的环境）
- `fix-he-ipv6-tunnel.sh` + **timer** 周期性对齐隧道与本地路由
- **cron** 每分钟调用 `v6-proxy-auto-repair.sh` 做连通性自检与修复

## 首次部署

```bash
git clone https://github.com/litao9891/ipv6.git
cd ipv6
# 编辑 config.sh（至少 HE_SERVER_IP、隧道与 Routed 前缀、VMESS_UUID），或使用下一节粘贴脚本
sudo bash install.sh
```

验证：

```bash
curl --proxy http://127.0.0.1:33300 --max-time 15 http://ipv6.icanhazip.com
curl --proxy http://127.0.0.1:33301 --max-time 15 http://ipv6.icanhazip.com
```

成功后同目录会生成 **`vmess-links.txt`**（含两条 `vmess://`，备注为 `公网IP+64` / `公网IP+48`）。

## 从 HE 控制台粘贴自动更新（推荐）

把 TunnelBroker 页面上的说明整段复制（需包含 **Server IPv4**、**Client IPv4**、**Client IPv6**、**Routed /64**、**Routed /48**；可附带 netplan 片段，脚本会忽略其中的 `local:` 公网地址）。

```bash
cd ipv6
sudo bash apply-he-paste.sh
# 粘贴后 Ctrl+D

# 或从文件:
sudo bash apply-he-paste.sh he-info.txt
```

脚本会：

1. 解析 HE 参数；**`TUNNEL_LOCAL_IPV4` / netplan `local:`** 一律改为当前机器 **`ip -4 route get 8.8.8.8` 的内网 `src`**
2. 将 **`HE_CLIENT_IPV4_PUBLIC`** 设为粘贴里的 Client IPv4（用于 VMess 里的 `add` 展示）
3. 写入 `config.sh` 与 `/etc` 下相关配置，执行 **`install.sh --config-only`**
4. 自检两条 v6-proxy，并刷新 **`vmess-links.txt`**

**注意**：若你在 HE 网页把 **Client IPv4** 改成了新公网，请与脚本解析结果一致；隧道在云上仍可能必须用 **内网 IP** 作 SIT `local`，以实际探测为准。

## 换 VPS / 仅换隧道后

- 用 **`apply-he-paste.sh`** 重新粘贴；或手工改 `config.sh` 后执行：

```bash
sudo bash install.sh --config-only
```

- 若隧道异常，可执行：`sudo /usr/local/bin/fix-he-ipv6-tunnel.sh`

## 文件说明

| 文件 | 说明 |
|------|------|
| `config.sh` | 全部可调参数（仓库内为示例，勿提交真实生产 UUID） |
| `install.sh` | 一键安装；`--config-only` 仅同步系统配置并重启服务 |
| `apply-he-paste.sh` | 从粘贴文本解析并调用 `install.sh --config-only` |
| `v6-proxy` | 可选本地二进制；若无则从 GitHub Release 下载 |
| `vmess-links.txt` | 由安装/应用脚本生成（已在 `.gitignore` 中忽略） |

## 安全提示

- `config.sh` / `vmess-links.txt` 含 **UUID** 与地址信息，请勿把生产配置推送到公开仓库。
- 生产环境建议为 VMess 增加 **TLS + CDN** 或 **防火墙限制来源 IP**。
