#!/usr/bin/env bash
# lib/common.sh — Shared utility functions for boot-scripts
# No dependencies beyond bash builtins

set -euo pipefail

# ── Guard ────────────────────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || {
  echo "lib/common.sh must be sourced, not executed" >&2
  exit 1
}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_PREFIX="${LOG_PREFIX:-[boot-scripts]}"
export LOG_PREFIX

log_info()  { echo "$LOG_PREFIX $*" >&2; }
log_warn()  { echo "$LOG_PREFIX WARNING: $*" >&2; }
log_error() { echo "$LOG_PREFIX ERROR: $*" >&2; }

# ── Checks ───────────────────────────────────────────────────────────────────
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

need_root() {
  if ! is_root; then
    log_error "this operation requires root — run with sudo"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_systemd() {
  [[ -d /run/systemd/system ]] && has_cmd systemctl
}

# ── File ops ─────────────────────────────────────────────────────────────────
backup_file() {
  local file="$1"
  local backup_dir="${BACKUP_DIR:-/var/tmp/boot-scripts-backups}"
  [[ -f "$file" ]] || return 0
  mkdir -p "$backup_dir"
  cp "$file" "$backup_dir/$(basename "$file").$(date +%Y%m%d-%H%M%S).bak"
  log_info "backed up $file → $backup_dir"
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 755 "$dir"
}

# ── Conf loading ──────────────────────────────────────────────────────────────
# Load config from /etc/boot-scripts/*.conf and ~/.config/boot-scripts/*.conf
load_confs() {
  local conf_dir="/etc/boot-scripts"
  local user_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/boot-scripts"
  local conf_files=(
    "${conf_dir}/defaults.conf"
    "${user_conf_dir}/defaults.conf"
  )
  for f in "${conf_files[@]}"; do
    [[ -f "$f" ]] || continue
    # Shell-safe: only accept simple var=value lines
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]] || continue
      eval "$line" 2>/dev/null || true
    done < "$f"
  done
}

# ── SSH helpers ──────────────────────────────────────────────────────────────
# Detect the drop-in dir for sshd_config
sshd_config_dropin_dir() {
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    echo "/etc/ssh/sshd_config.d"
  else
    echo "/etc/ssh"
  fi
}

sshd_config_target() {
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    echo "/etc/ssh/sshd_config.d/99-boot-scripts.conf"
  else
    echo "/etc/ssh/sshd_config"
  fi
}

restart_sshd() {
  local svc
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    svc="ssh"
  else
    svc="sshd"
  fi
  if systemctl restart "$svc"; then
    log_info "ssh service ($svc) restarted"
  else
    log_warn "failed to restart ssh service — you may need to reconnect manually"
  fi
}

# ── Misc ──────────────────────────────────────────────────────────────────────
get_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-${NAME:-unknown}}"
  else
    echo "unknown"
  fi
}

get_arch() {
  uname -m
}

get_uptime_human() {
  if has_cmd uptime; then
    uptime -s 2>/dev/null || uptime
  fi
}

confirm() {
  local prompt="${1:-continue?}"
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]]
}
