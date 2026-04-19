#!/bin/bash
# 随机 IPv6：一键菜单 / 子命令
# 直接执行: sudo bash onekey.sh → 数字菜单
# 子命令: install | ip | update | restart | help
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="${V6_DEPLOY_DIR:-/root/v6-proxy-random-ipv6-deploy}"
  mkdir -p "$SCRIPT_DIR"
fi
RAW="${V6_REPO_RAW:-https://raw.githubusercontent.com/litao9891/ipv6/main}"

[[ "$(id -u)" -eq 0 ]] || {
  echo "需要 root，例如: sudo bash $0"
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

do_install() {
  sync_scripts
  cd "$SCRIPT_DIR"
  bash ./install.sh
}

do_update_ip() {
  sync_scripts
  cd "$SCRIPT_DIR"
  if [[ -t 0 ]]; then
    bash ./apply-he-paste.sh
  else
    echo "[onekey] 非交互终端，请提供 HE 文本文件: sudo bash onekey.sh ip /path/to/he.txt"
    exit 1
  fi
}

do_update_ip_file() {
  local f="$1"
  [[ -f "$f" ]] || {
    echo "文件不存在: $f"
    exit 1
  }
  sync_scripts
  cd "$SCRIPT_DIR"
  bash ./apply-he-paste.sh "$f"
}

restart_all_services() {
  echo "[onekey] 重启相关服务..."
  systemctl daemon-reload
  netplan apply 2>/dev/null || true
  /usr/local/bin/fix-he-ipv6-tunnel.sh 2>/dev/null || true
  systemctl restart ipv6-anyip.service 2>/dev/null || true
  systemctl restart v6-proxy.service v6-proxy-48.service v6-proxy-64.service 2>/dev/null || true
  systemctl try-restart xray.service 2>/dev/null || systemctl restart xray.service 2>/dev/null || true
  systemctl start he-ipv6-tunnel-monitor.timer 2>/dev/null || true
  if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
    bash "$SCRIPT_DIR/install.sh" --iptables-only 2>/dev/null || true
  fi
  echo "[onekey] 已执行重启。状态:"
  systemctl is-active ipv6-anyip.service v6-proxy.service v6-proxy-48.service xray.service 2>/dev/null || true
}

show_menu() {
  cat << 'EOF'
======== 随机 IPv6 一键 ========
  1) 安装        拉最新脚本 + 完整安装（v6-proxy / Xray / systemd）
  2) 更新 IP     拉最新脚本 + 粘贴 HE 控制台整段（换隧道/换 IP）
  3) 重启服务    同上 + 自动补 iptables VMess 端口（见 install.sh --iptables-only）
  0) 退出
================================
提示: 仅拉脚本并按本机 config 应用 → sudo bash onekey.sh update
EOF
}

run_menu() {
  local choice
  while true; do
    show_menu
    read -r -p "请选择 [0-3]: " choice || true
    case "${choice:-}" in
    1)
      do_install
      break
      ;;
    2)
      do_update_ip
      break
      ;;
    3)
      restart_all_services
      break
      ;;
    0 | "")
      echo "已退出。"
      exit 0
      ;;
    *)
      echo "无效选择，请重新输入。"
      ;;
    esac
  done
}

# ----- 入口 -----
if [[ $# -eq 0 ]]; then
  if [[ -t 0 ]]; then
    run_menu
  else
    echo "非交互环境请带子命令，例如: sudo bash $0 update"
    echo "子命令: install | ip | update | restart | help"
    exit 1
  fi
  exit 0
fi

cmd="$1"
case "$cmd" in
update | upgrade | sync)
  shift || true
  sync_scripts
  cd "$SCRIPT_DIR"
  exec bash ./install.sh --config-only
  ;;
ip | reip | paste | tunnel)
  shift || true
  sync_scripts
  cd "$SCRIPT_DIR"
  exec bash ./apply-he-paste.sh "$@"
  ;;
install | full)
  do_install
  ;;
restart | reload | services)
  restart_all_services
  ;;
help | -h | --help)
  cat << 'EOF'
用法:
  sudo bash onekey.sh              数字菜单（推荐）
  sudo bash onekey.sh install      完整安装
  sudo bash onekey.sh ip [文件]   粘贴或从文件更新 HE / IP
  sudo bash onekey.sh update       拉脚本后仅按 config 应用
  sudo bash onekey.sh restart      重启 netplan / 隧道 / 代理 / xray + iptables 放行

环境变量 V6_REPO_RAW 可指向 fork 的 raw 根路径。
EOF
  ;;
*)
  echo "未知子命令: $cmd （install | ip | update | restart | help）"
  exit 1
  ;;
esac
