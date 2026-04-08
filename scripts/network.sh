#!/usr/bin/env bash
# network.sh - Common network and region fixes for fresh hosts

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

RESOLV_FILE="/etc/resolv.conf"

public_ip() {
  has_cmd curl && curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "n/a"
}

primary_ipv4() {
  has_cmd ip && ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2; exit}' || echo "n/a"
}

current_timezone() {
  has_cmd timedatectl && timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown"
}

current_dns() {
  awk '/^nameserver/{print $2}' "$RESOLV_FILE" 2>/dev/null | paste -sd ', ' - || echo "n/a"
}

apt_reachable() {
  if has_cmd apt-get; then
    apt-get update -qq >/dev/null 2>&1 && echo "ok" || echo "failed"
  else
    echo "n/a"
  fi
}

apply_dns_servers() {
  local servers=("$@")

  need_root
  backup_file "$RESOLV_FILE"
  {
    echo "# managed by boot-scripts network.sh"
    for server in "${servers[@]}"; do
      echo "nameserver $server"
    done
  } > "$RESOLV_FILE"
  ok "updated $RESOLV_FILE"
}

apply_dns_preset() {
  case "${1:-}" in
    cloudflare) apply_dns_servers 1.1.1.1 1.0.0.1 ;;
    google) apply_dns_servers 8.8.8.8 8.8.4.4 ;;
    quad9) apply_dns_servers 9.9.9.9 149.112.112.112 ;;
    *)
      fail "unknown DNS preset: $1"
      return 1
      ;;
  esac
}

set_timezone_value() {
  local timezone="$1"

  need_root
  has_cmd timedatectl || {
    fail "timedatectl not available"
    return 1
  }
  timedatectl set-timezone "$timezone"
  ok "timezone set to $timezone"
}

show_status() {
  section "network"
  box_row "Hostname" "$(hostname -f 2>/dev/null || hostname)"
  box_row "IPv4" "$(primary_ipv4)"
  box_row "Public IP" "$(public_ip)"
  box_row "Timezone" "$(current_timezone)"
  box_row "DNS servers" "$(current_dns)"
  box_sep
  box_row "DNS lookup" "$(getent hosts github.com >/dev/null 2>&1 && echo ok || echo failed)"
  box_row "APT reachability" "$(apt_reachable)"
  section_end
}

test_connectivity() {
  show_status
  has_cmd ping && ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ok "ICMP to 1.1.1.1 ok" || warn "ICMP to 1.1.1.1 failed"
  getent hosts deb.debian.org >/dev/null 2>&1 && ok "DNS lookup for deb.debian.org ok" || warn "DNS lookup for deb.debian.org failed"
}

set_timezone_interactive() {
  local timezone
  echo ""
  echo -e "  ${C_BOLD}Set timezone${C_RESET}"
  echo -e "  ${C_DIM}example: Asia/Shanghai or America/Los_Angeles${C_RESET}"
  read -rp "  timezone: " timezone
  [[ -n "$timezone" ]] || { warn "empty timezone"; return 1; }
  set_timezone_value "$timezone"
}

set_dns_interactive() {
  local choice custom
  while true; do
    echo ""
    echo -e "  ${C_BOLD}DNS presets${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} Cloudflare (1.1.1.1 / 1.0.0.1)"
    echo -e "  ${C_CYAN}2)${C_RESET} Google (8.8.8.8 / 8.8.4.4)"
    echo -e "  ${C_CYAN}3)${C_RESET} Quad9 (9.9.9.9 / 149.112.112.112)"
    echo -e "  ${C_CYAN}4)${C_RESET} Custom nameserver list"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice
    case "$choice" in
      1) apply_dns_preset cloudflare; return 0 ;;
      2) apply_dns_preset google; return 0 ;;
      3) apply_dns_preset quad9; return 0 ;;
      4)
        read -rp "  nameservers (space-separated): " custom
        [[ -n "$custom" ]] || { warn "empty nameserver list"; return 1; }
        read -r -a _servers <<< "$custom"
        apply_dns_servers "${_servers[@]}"
        return 0
        ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

interactive_menu() {
  local choice
  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Network actions${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} test connectivity"
    echo -e "  ${C_CYAN}2)${C_RESET} set DNS"
    echo -e "  ${C_CYAN}3)${C_RESET} set timezone"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice
    case "$choice" in
      1) test_connectivity ;;
      2) set_dns_interactive ;;
      3) set_timezone_interactive ;;
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
    --dns)
      [[ -n "${2:-}" ]] || { echo "usage: network.sh --dns <cloudflare|google|quad9>" >&2; exit 2; }
      apply_dns_preset "$2"
      ;;
    --timezone)
      [[ -n "${2:-}" ]] || { echo "usage: network.sh --timezone <Area/City>" >&2; exit 2; }
      set_timezone_value "$2"
      ;;
    --test)
      test_connectivity
      ;;
    -h|--help)
      echo "Usage:"
      echo "  network.sh"
      echo "  network.sh --status"
      echo "  network.sh --dns <cloudflare|google|quad9>"
      echo "  network.sh --timezone <Area/City>"
      echo "  network.sh --test"
      ;;
    "")
      interactive_menu
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
}

main "$@"
