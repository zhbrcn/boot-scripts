#!/usr/bin/env bash
# lib/common.sh - Shared utility functions for boot-scripts

set -euo pipefail

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || {
  echo "lib/common.sh must be sourced, not executed" >&2
  exit 1
}

LOG_PREFIX="${LOG_PREFIX:-[boot-scripts]}"
export LOG_PREFIX

log_info()  { echo "$LOG_PREFIX $*" >&2; }
log_warn()  { echo "$LOG_PREFIX WARNING: $*" >&2; }
log_error() { echo "$LOG_PREFIX ERROR: $*" >&2; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
is_systemd() { [[ -d /run/systemd/system ]] && has_cmd systemctl; }

need_root() {
  if ! is_root; then
    log_error "this operation requires root - run with sudo"
    exit 1
  fi
}

backup_file() {
  local file="$1"
  local backup_dir="${BACKUP_DIR:-/var/tmp/boot-scripts-backups}"

  [[ -f "$file" ]] || return 0
  mkdir -p "$backup_dir"
  cp "$file" "$backup_dir/$(basename "$file").$(date +%Y%m%d-%H%M%S).bak"
  log_info "backed up $file -> $backup_dir"
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 755 "$dir"
}

load_confs() {
  local conf_files=(
    "/etc/boot-scripts/defaults.conf"
    "${XDG_CONFIG_HOME:-$HOME/.config}/boot-scripts/defaults.conf"
  )
  local file line

  for file in "${conf_files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]] || continue
      eval "$line" 2>/dev/null || true
    done < "$file"
  done
}

sshd_config_dropin_dir() {
  [[ -d /etc/ssh/sshd_config.d ]] && echo "/etc/ssh/sshd_config.d" || echo "/etc/ssh"
}

sshd_config_target() {
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    echo "/etc/ssh/sshd_config.d/99-boot-scripts.conf"
  else
    echo "/etc/ssh/sshd_config"
  fi
}

ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "sshd"
  fi
}

restart_sshd() {
  local svc
  svc="$(ssh_service_name)"

  if systemctl restart "$svc"; then
    log_info "ssh service ($svc) restarted"
  else
    log_warn "failed to restart ssh service - you may need to reconnect manually"
  fi
}

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
    uptime -p 2>/dev/null || uptime
  else
    echo "unknown"
  fi
}

confirm() {
  local prompt="${1:-continue?}"
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]]
}
