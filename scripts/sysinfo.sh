#!/usr/bin/env bash
# sysinfo.sh - System overview plus core health checks

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

PAM_SSHD_FILE="/etc/pam.d/sshd"
YUBIKEY_AUTHFILE="/etc/ssh/authorized_yubikeys"
HOSTS_FILE="/etc/hosts"

sshd_effective() {
  local key="$1"
  local sshd_dump
  local line

  sshd_dump="$(sshd -T 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ "$line" == "$key "* ]] || continue
    printf '%s\n' "${line#* }"
    return 0
  done <<< "$sshd_dump"

  return 1
}

sshd_effective_or_unknown() {
  local key="$1"
  local value=""

  value="$(sshd_effective "$key" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf 'unknown\n'
  fi
}

yubikey_pam_line() {
  grep 'pam_yubico' "$PAM_SSHD_FILE" 2>/dev/null | head -n 1 || true
}

color_bool() {
  case "$1" in
    yes|on|enabled|valid|ok|matched|configured)
      echo -e "${C_GREEN}$1${C_RESET}"
      ;;
    no|off|disabled|invalid|failed|stopped)
      echo -e "${C_YELLOW}$1${C_RESET}"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

host_short_name() {
  hostname -s 2>/dev/null || hostname
}

summary_status() {
  local issues=0
  sshd -t >/dev/null 2>&1 || issues=$((issues + 1))
  [[ "$(sshd_effective_or_unknown permitrootlogin)" == "yes" ]] && issues=$((issues + 1))
  [[ "$(sshd_effective_or_unknown passwordauthentication)" == "yes" ]] && issues=$((issues + 1))
  getent hosts github.com >/dev/null 2>&1 || issues=$((issues + 1))

  if (( issues == 0 )); then
    echo -e "${C_GREEN}System ready${C_RESET}"
  elif (( issues <= 2 )); then
    echo -e "${C_YELLOW}Needs attention${C_RESET}"
  else
    echo -e "${C_RED}Risky state${C_RESET}"
  fi
}

summary_ssh_posture() {
  if yubikey_pam_line >/dev/null 2>&1 && [[ -n "$(yubikey_pam_line)" ]]; then
    echo "YubiKey protected"
  elif [[ "$(sshd_effective_or_unknown passwordauthentication)" == "no" ]]; then
    echo "Password disabled"
  else
    echo "Password exposed"
  fi
}

summary_network() {
  if getent hosts github.com >/dev/null 2>&1; then
    echo "DNS ok / apt likely reachable"
  else
    echo "DNS needs review"
  fi
}

show_summary_block() {
  box_row "Summary" "$(summary_status)"
  box_row "SSH posture" "$(summary_ssh_posture)"
  box_row "Network" "$(summary_network)"
  box_sep
}

show_system_block() {
  local os arch kernel host uptime_str
  local cpu_model cpu_cores mem_total mem_avail disk_used disk_total disk_pct

  os="$(get_os)"
  arch="$(get_arch)"
  kernel="$(uname -r)"
  host="$(hostname -f 2>/dev/null || hostname)"
  uptime_str="$(get_uptime_human)"

  box_row "OS" "$os"
  box_row "Arch" "$arch"
  box_row "Kernel" "$kernel"
  box_row "Hostname" "$host"
  box_row "Uptime" "$uptime_str"
  box_sep

  if [[ -f /proc/cpuinfo ]]; then
    cpu_model="$(awk -F: '/model name/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
    box_row "CPU" "${cpu_model:-unknown} (${cpu_cores} cores)"
  fi

  if [[ -f /proc/meminfo ]]; then
    mem_total="$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)"
    mem_avail="$(awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)"
    box_row "RAM" "${mem_avail}GB available / ${mem_total}GB total"
  fi

  disk_used="$(df -h / | awk 'NR==2{print $3}')"
  disk_total="$(df -h / | awk 'NR==2{print $2}')"
  disk_pct="$(df -h / | awk 'NR==2{print $5}')"
  box_row "Disk" "${disk_used} used / ${disk_total} total (${disk_pct} full)"
}

show_network_block() {
  local ipv4="n/a"
  local public_ip="n/a"
  local docker_ver=""

  box_sep

  if has_cmd ip; then
    ipv4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2; exit}' || echo 'n/a')"
  fi
  box_row "IPv4" "$ipv4"

  if has_cmd curl; then
    public_ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo 'n/a')"
  fi
  box_row "Public IP" "$public_ip"

  if has_cmd docker; then
    docker_ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    box_row "Docker" "${docker_ver:-ok}"
  fi
}

show_access_block() {
  local svc root_login password_auth pubkey_auth keyboard_auth

  box_sep

  svc="$(ssh_service_name)"
  root_login="$(sshd_effective_or_unknown permitrootlogin)"
  password_auth="$(sshd_effective_or_unknown passwordauthentication)"
  pubkey_auth="$(sshd_effective_or_unknown pubkeyauthentication)"
  keyboard_auth="$(sshd_effective_or_unknown kbdinteractiveauthentication)"

  if sshd -t 2>/dev/null; then
    box_row "SSH config" "$(color_bool valid)"
  else
    box_row "SSH config" "$(color_bool invalid)"
  fi

  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    box_row "SSH service" "${C_GREEN}${svc} running${C_RESET}"
  else
    box_row "SSH service" "${C_YELLOW}${svc} stopped${C_RESET}"
  fi

  box_row "Root login" "$root_login"
  box_row "Password auth" "$password_auth"
  box_row "Public-key auth" "$pubkey_auth"
  box_row "Keyboard-int" "$keyboard_auth"
}

show_health_block() {
  local ntp_sync="unknown"
  local hosts_line pam_line dns_state mapping_count

  if has_cmd timedatectl; then
    ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
  fi
  box_row "NTP sync" "$(color_bool "$ntp_sync")"

  hosts_line="$(grep -E '^127\.0\.1\.1[[:space:]]+' "$HOSTS_FILE" 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$hosts_line" && "$hosts_line" == *"$(host_short_name)"* ]]; then
    box_row "Hosts mapping" "$(color_bool matched)"
  else
    box_row "Hosts mapping" "${C_YELLOW}not aligned${C_RESET}"
  fi

  if getent hosts github.com >/dev/null 2>&1; then
    dns_state="$(color_bool ok)"
  else
    dns_state="$(color_bool failed)"
  fi
  box_row "DNS lookup" "$dns_state"

  pam_line="$(yubikey_pam_line)"
  if [[ -n "$pam_line" ]]; then
    box_row "YubiKey PAM" "$(color_bool configured)"
    box_row "YubiKey rule" "$pam_line"
  else
    box_row "YubiKey PAM" "${C_DIM}not configured${C_RESET}"
  fi

  if [[ -f "$YUBIKEY_AUTHFILE" ]]; then
    mapping_count="$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$YUBIKEY_AUTHFILE" 2>/dev/null || echo 0)"
    box_row "YubiKey maps" "${mapping_count} entry(s)"
  fi
}

show_sysinfo() {
  section "system info"
  show_summary_block
  show_system_block
  show_network_block
  show_access_block
  show_health_block
  section_end
}

main() {
  show_sysinfo
  if [[ "${1:-}" == "--hold" ]]; then
    pause "press enter to go back..."
  fi
}

main "$@"
