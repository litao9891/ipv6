# 随机 IPv6 + VMess 部署包

本机通过 [TunnelBroker](https://tunnelbroker.net/) + [v6-proxy](https://github.com/zbronya/v6-proxy) + [Xray](https://github.com/XTLS/Xray-core) 实现从 HE 下发的 **Routed /64** 与 **Routed /48** 中随机选源 IPv6 出站；入站为两条 **VMess over WebSocket**（分别走 /64 与 /48 的本地 HTTP 代理）。

## 一键（推荐）

在**已存在部署目录**（例如 `/root/v6-proxy-random-ipv6-deploy`）下执行：

```bash
sudo bash onekey.sh
```

会出现**数字菜单**：**1 安装**、**2 更新 IP**（粘贴 HE）、**3 重启服务**、**0 退出**。

| 目的 | 命令 |
|------|------|
| **数字菜单** | `sudo bash onekey.sh` |
| **更新脚本 + 按本机配置重启** | `sudo bash onekey.sh update` |
| **换隧道 / 换 IP（粘贴 HE 整段说明）** | `sudo bash onekey.sh ip`（粘贴后 Ctrl+D；或 `sudo bash onekey.sh ip he.txt`） |
| **仅重启服务**（不拉脚本） | `sudo bash onekey.sh restart` |
| **完整重装 / 首次强制全量安装** | `sudo bash onekey.sh install` |

`onekey.sh` 会先从 **`https://raw.githubusercontent.com/litao9891/ipv6/main`** 拉取最新 `install.sh`、`apply-he-paste.sh` 等（**不会覆盖**你已存在的 `config.sh`）。可用环境变量 **`V6_REPO_RAW`** 指向自己的 fork。

**新机第一次**：只下载 `onekey.sh` 后执行 **`onekey.sh ip`** 粘贴 HE 信息即可；若本机尚未安装 v6-proxy/Xray，会自动走**完整** `install.sh`。

```bash
sudo mkdir -p /root/v6-proxy-random-ipv6-deploy
sudo curl -fsSL https://raw.githubusercontent.com/litao9891/ipv6/main/onekey.sh \
  -o /root/v6-proxy-random-ipv6-deploy/onekey.sh
sudo bash /root/v6-proxy-random-ipv6-deploy/onekey.sh ip
```

子命令说明：`sudo bash onekey.sh help`。

## 功能概要

- 双随机 IPv6 出口：**Routed /64**（`127.0.0.1:33300`）与 **Routed /48**（`127.0.0.1:33301`）
- **VMess + WS**：`0.0.0.0` 监听，路由按入站标签分流到上述两个代理
- **Netplan SIT** 隧道：`local` 使用 **内网 IPv4**（`ip -4 route get 8.8.8.8` 的 `src`），与 HE 控制台里填写的 Client IPv4（公网）可不一致（适合 Oracle 等仅内网走协议 41 的环境）
- `fix-he-ipv6-tunnel.sh` + **timer** 周期性对齐隧道与本地路由
- **cron** 每分钟调用 `v6-proxy-auto-repair.sh` 做连通性自检与修复

## 首次部署

1. **推荐**：使用上一节 **`onekey.sh ip`** 粘贴 HE 信息（自动生成 `config.sh` 并完成安装）。
2. 或手工编辑 `config.sh` 后在本目录执行：

```bash
cd v6-proxy-random-ipv6-deploy
sudo bash install.sh
```

3. 验证：

```bash
curl --proxy http://127.0.0.1:33300 --max-time 15 http://ipv6.icanhazip.com
curl --proxy http://127.0.0.1:33301 --max-time 15 http://ipv6.icanhazip.com
```

成功后同目录会生成 **`vmess-links.txt`**（含两条 `vmess://`，备注为 `公网IP+64` / `公网IP+48`）。

## 从 HE 控制台粘贴自动更新（推荐）

把 TunnelBroker 页面上的说明整段复制（需包含 **Server IPv4**、**Client IPv4**、**Client IPv6**、**Routed /64**、**Routed /48**；可附带 netplan 片段，脚本会忽略其中的 `local:` 公网地址）。

```bash
cd v6-proxy-random-ipv6-deploy
sudo bash apply-he-paste.sh
# 粘贴后 Ctrl+D

# 或从文件:
sudo bash apply-he-paste.sh he-info.txt
```

脚本会：

1. 解析 HE 参数；**`TUNNEL_LOCAL_IPV4` / netplan `local:`** 一律改为当前机器 **`ip -4 route get 8.8.8.8` 的内网 `src`**
2. 将 **`HE_CLIENT_IPV4_PUBLIC`** 设为粘贴里的 Client IPv4（用于 VMess 里的 `add` 展示）
3. 写入 `config.sh` 与 `/etc` 下相关配置；若已装过 v6-proxy/Xray 则执行 **`install.sh --config-only`**，否则执行**完整** **`install.sh`**
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
| `config.sh` | 全部可调参数 |
| `install.sh` | 一键安装；`--config-only` 仅同步系统配置并重启服务 |
| `apply-he-paste.sh` | 从粘贴文本解析并安装/应用配置 |
| `onekey.sh` | 从 GitHub 拉脚本后执行 `update` / `ip` / `install` |
| `v6-proxy` | 可选本地二进制；若无则从 GitHub Release 下载 |
| `vmess-links.txt` | 由安装/应用脚本生成的连接（勿提交含隐私的副本） |

## 与上游仓库

部署逻辑与说明同步维护在 GitHub：**[litao9891/ipv6](https://github.com/litao9891/ipv6)**。将本目录内容推送到该仓库即可更新文档与脚本。

## 安装时像「卡住」？

1. **先按一下回车**：`install.sh` 在下载前会打印参数摘要并 **`read` 等待回车**，不是死机。  
2. **不想人工确认**：`SKIP_CONFIRM=1 sudo bash install.sh`  
3. **长时间无输出**：多半在静默下载 **v6-proxy / Xray**（需能访问 GitHub）；已加超时与提示；若机房屏蔽 GitHub，需代理或本地上传二进制。

## VMess UUID 与客户端连不上

- **`install.sh` / `install.sh --config-only`**：若 `config.sh` 里 **`VMESS_UUID` 为空** 或为仓库**占位 UUID**（`00000000-0000-4000-8000-000000000001`），会按顺序尝试 **`uuidgen`** → **`/proc/sys/kernel/random/uuid`（Linux）** → **`openssl`** → **`python3`** 生成随机 UUID，写回 `config.sh` 并同步到 Xray；**不强制依赖 Python**。  
- **自检通过但外网客户端连不上**：多半是 **云安全组未放行入站 TCP `VMESS_PORT_64` / `VMESS_PORT_48`**（默认 48442、54661）。安装结束会再次提示。

## 安全提示

- `config.sh` / `vmess-links.txt` 含 **UUID** 与地址信息，请勿公开泄露。
- 生产环境建议为 VMess 增加 **TLS + CDN** 或 **防火墙限制来源 IP**，本仓库默认方案为快速验证用途。
