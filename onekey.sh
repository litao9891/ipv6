#!/bin/bash
# 一键：从 GitHub 同步脚本 + 部署更新 / 换隧道 IP
# 用法见末尾 help；默认子命令为 update。
# 请先保存本文件到固定目录再执行（勿 curl|bash 管道，否则无法确定安装路径）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="${V6_DEPLOY_DIR:-/root/v6-proxy-random-ipv6-deploy}"
  mkdir -p "$SCRIPT_DIR"
fi
RAW="${V6_REPO_RAW:-https://raw.githubusercontent.com/litao9891/ipv6/main}"

[[ "$(id -u)" -eq 0 ]] || {
  echo "需要 root，例如: sudo bash $0 $*"
  exit 1
}

sync_scripts() {
  echo "[onekey] 同步脚本: ${RAW}"
  local f failed=0
  for f in install.sh apply-he-paste.sh onekey.sh .gitignore README.md; do
    if curl -fsSL "$RAW/$f" -o "$SCRIPT_DIR/$f.part"; then
      mv "$SCRIPT_DIR/$f.part" "$SCRIPT_DIR/$f"
    else
      echo "[onekey] 下载失败: $f（保留本地旧文件）"
      failed=1
      rm -f "$SCRIPT_DIR/$f.part"
    fi
  done
  if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    if curl -fsSL "$RAW/config.sh" -o "$SCRIPT_DIR/config.sh.part"; then
      mv "$SCRIPT_DIR/config.sh.part" "$SCRIPT_DIR/config.sh"
    else
      rm -f "$SCRIPT_DIR/config.sh.part"
    fi
  fi
  chmod +x "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/apply-he-paste.sh" "$SCRIPT_DIR/onekey.sh" 2>/dev/null || true
  [[ "$failed" -eq 0 ]] || echo "[onekey] 部分下载失败，将使用目录内已有脚本继续"
}

cmd="${1:-update}"
case "$cmd" in
update | upgrade | sync)
  sync_scripts
  cd "$SCRIPT_DIR"
  exec bash ./install.sh --config-only
  ;;
ip | reip | paste | tunnel)
  sync_scripts
  cd "$SCRIPT_DIR"
  shift || true
  exec bash ./apply-he-paste.sh "$@"
  ;;
install | full)
  sync_scripts
  cd "$SCRIPT_DIR"
  exec bash ./install.sh
  ;;
help | -h | --help)
  cat << 'EOF'
一键命令（在部署目录执行；首次可把本脚本下载到该目录）。

  sudo bash onekey.sh update     从 GitHub 拉最新脚本 → 按本机 config.sh 写入 / 并重启（日常更新）
  sudo bash onekey.sh ip         同上 → 粘贴 HE 控制台整段文字换隧道/换 IP（Ctrl+D 结束；或: ip he.txt）
  sudo bash onekey.sh install    拉脚本后执行「完整安装」（重装 / 首次未装 v6-proxy、Xray 时用）

新机一条线（先下载 onekey 再换 IP，首次会自动完整安装）：

  sudo mkdir -p /root/v6-proxy-random-ipv6-deploy
  sudo curl -fsSL https://raw.githubusercontent.com/litao9891/ipv6/main/onekey.sh \
    -o /root/v6-proxy-random-ipv6-deploy/onekey.sh
  sudo bash /root/v6-proxy-random-ipv6-deploy/onekey.sh ip

环境变量 V6_REPO_RAW 可指向自己的 fork，例如:
  export V6_REPO_RAW=https://raw.githubusercontent.com/你的用户/ipv6/main
EOF
  ;;
*)
  echo "未知子命令: $cmd"
  echo "可用: update | ip | install | help"
  exit 1
  ;;
esac
