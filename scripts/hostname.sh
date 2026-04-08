#!/usr/bin/env bash
# hostname.sh - Manage system hostname and /etc/hosts mapping
#
# Usage:
#   hostname.sh                     # interactive menu
#   hostname.sh --status            # show hostname status
#   hostname.sh --set NAME          # set hostname only
#   hostname.sh --sync-hosts        # sync /etc/hosts only
#   hostname.sh --apply NAME        # set hostname and sync /etc/hosts

set -euo pipefail

_src="${BASH_SOURCE[0]}"
_dir="$(cd "$(dirname "$_src")" && pwd)"
while [[ "$_dir" != "/" ]]; do
  if [[ -f "$_dir/lib/common.sh" ]]; then
    source "$_dir/lib/common.sh"
    source "$_dir/lib/ui.sh"
    LIB_LOADED=1
    break
  fi
  _dir="$(dirname "$_dir")"
done
[[ "${LIB_LOADED:-}" ]] || {
  echo "fatal: cannot find lib/common.sh" >&2
  exit 1
}

LOG_PREFIX="[hostname]"
HOSTS_FILE="/etc/hosts"
HOSTNAME_FILE="/etc/hostname"
MANAGED_BEGIN="# boot-scripts hosts begin"
MANAGED_END="# boot-scripts hosts end"

current_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || cat "$HOSTNAME_FILE"
}

current_fqdn() {
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || true)"
  if [[ -n "$fqdn" && "$fqdn" != "(none)" ]]; then
    echo "$fqdn"
  else
    current_hostname
  fi
}

managed_hosts_line() {
  local short_name fqdn
  short_name="$(current_hostname)"
  fqdn="$(current_fqdn)"

  if [[ "$fqdn" == "$short_name" ]]; then
    printf '127.0.1.1 %s\n' "$short_name"
  else
    printf '127.0.1.1 %s %s\n' "$fqdn" "$short_name"
  fi
}

validate_hostname_name() {
  local value="$1"

  [[ -n "$value" && ${#value} -le 63 ]] || return 1
  [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

show_status() {
  section "hostname"
  box_row "Current name" "$(current_hostname)"
  box_row "Full name" "$(current_fqdn)"
  box_row "Hosts sync" "Managed block ready"
  box_sep
  box_row "Hostname file" "$HOSTNAME_FILE"
  box_row "Hosts file" "$HOSTS_FILE"
  box_row "Managed line" "$(managed_hosts_line)"
  section_end
}

sync_hosts() {
  local tmp_file

  need_root
  backup_file "$HOSTS_FILE"
  tmp_file="$(mktemp)"

  if [[ -f "$HOSTS_FILE" ]]; then
    awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
      BEGIN { in_block = 0 }
      $0 == begin { in_block = 1; next }
      $0 == end { in_block = 0; next }
      !in_block { print }
    ' "$HOSTS_FILE" > "$tmp_file"
  fi

  if ! grep -qE '^127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "$tmp_file" 2>/dev/null; then
    printf '127.0.0.1 localhost\n' >> "$tmp_file"
  fi
  if ! grep -qE '^::1[[:space:]]+localhost ip6-localhost ip6-loopback([[:space:]]|$)' "$tmp_file" 2>/dev/null; then
    printf '::1 localhost ip6-localhost ip6-loopback\n' >> "$tmp_file"
  fi

  {
    printf '\n%s\n' "$MANAGED_BEGIN"
    managed_hosts_line
    printf '%s\n' "$MANAGED_END"
  } >> "$tmp_file"

  cat "$tmp_file" > "$HOSTS_FILE"
  rm -f "$tmp_file"
  ok "updated $HOSTS_FILE"
}

set_hostname_value() {
  local new_name="$1"

  need_root
  validate_hostname_name "$new_name" || {
    fail "invalid hostname: $new_name"
    warn "allowed: letters, numbers, hyphen; must start/end with letter or number"
    return 1
  }

  backup_file "$HOSTNAME_FILE"

  if has_cmd hostnamectl; then
    hostnamectl set-hostname "$new_name"
  else
    printf '%s\n' "$new_name" > "$HOSTNAME_FILE"
    hostname "$new_name"
  fi

  ok "hostname set to $new_name"
}

set_hostname_interactive() {
  local current_name new_name

  current_name="$(current_hostname)"
  echo ""
  echo -e "  ${C_BOLD}Set hostname${C_RESET}"
  echo -e "  ${C_DIM}current:${C_RESET} $current_name"
  read -rp "  new hostname: " new_name

  [[ -n "$new_name" ]] || {
    warn "empty hostname, skipping"
    return 1
  }

  set_hostname_value "$new_name"
}

interactive_menu() {
  local choice

  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Main actions${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} set hostname"
    echo -e "  ${C_CYAN}2)${C_RESET} sync hosts file"
    echo -e "  ${C_CYAN}3)${C_RESET} set name and sync hosts"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) set_hostname_interactive ;;
      2) sync_hosts ;;
      3)
        set_hostname_interactive && sync_hosts
        ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --status)
      show_status
      ;;
    --set)
      [[ -n "${2:-}" ]] || {
        echo "usage: hostname.sh --set <name>" >&2
        exit 2
      }
      set_hostname_value "$2"
      ;;
    --sync-hosts)
      sync_hosts
      ;;
    --apply)
      [[ -n "${2:-}" ]] || {
        echo "usage: hostname.sh --apply <name>" >&2
        exit 2
      }
      set_hostname_value "$2"
      sync_hosts
      ;;
    -h|--help)
      echo "Usage:"
      echo "  hostname.sh                     # interactive menu"
      echo "  hostname.sh --status            # show hostname status"
      echo "  hostname.sh --set <name>        # set hostname only"
      echo "  hostname.sh --sync-hosts        # sync /etc/hosts only"
      echo "  hostname.sh --apply <name>      # set hostname and sync hosts"
      ;;
    "")
      interactive_menu
      ;;
    *)
      echo "unknown arg: $1" >&2
      echo "Usage: hostname.sh [--status|--set <name>|--sync-hosts|--apply <name>]" >&2
      exit 2
      ;;
  esac
}

main "$@"
