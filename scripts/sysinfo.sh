#!/usr/bin/env bash
# sysinfo.sh — Quick system information summary

set -euo pipefail

_src="${BASH_SOURCE[0]}"
_dir="$(cd "$(dirname "$_src")" && pwd)"
while [[ "$_dir" != "/" ]]; do
  [[ -f "$_dir/lib/common.sh" ]] && { source "$_dir/lib/common.sh"; source "$_dir/lib/ui.sh"; LIB_LOADED=1; break; }
  _dir="$(dirname "$_dir")"
done
[[ "${LIB_LOADED:-}" ]] || {
  echo "fatal: cannot find lib/common.sh" >&2; exit 1
}

LOG_PREFIX="[sysinfo]"

show_sysinfo() {
  section "system information"

  local os arch kernel hostname uptime_str
  os="$(get_os)"
  arch="$(get_arch)"
  kernel="$(uname -r)"
  hostname="$(hostname -f 2>/dev/null || hostname)"
  uptime_str="$(uptime -p 2>/dev/null || uptime)"

  box_row "OS"       "$os"
  box_row "Arch"     "$arch"
  box_row "Kernel"   "$kernel"
  box_row "Hostname" "$hostname"
  box_row "Uptime"   "$uptime_str"

  echo -e "${C_BOLD}${C_CYAN}├${HLINE}┤${C_RESET}"

  # CPU
  if [[ -f /proc/cpuinfo ]]; then
    local cpu_model
    cpu_model=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo)
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    box_row "CPU"       "${cpu_model:-(unknown)} (${cpu_cores} cores)"
  fi

  # Memory
  if [[ -f /proc/meminfo ]]; then
    local mem_total mem_avail
    mem_total=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
    box_row "RAM"       "${mem_avail}GB available / ${mem_total}GB total"
  fi

  # Disk
  local disk_used disk_avail disk_total disk_pct
  disk_used=$(df -h / | awk 'NR==2{print $3}')
  disk_avail=$(df -h / | awk 'NR==2{print $4}')
  disk_total=$(df -h / | awk 'NR==2{print $2}')
  disk_pct=$(df / | awk 'NR==2{print $5}')
  box_row "Disk"      "${disk_used} used / ${disk_total} total (${disk_pct} full)"

  # Network
  echo -e "${C_BOLD}${C_CYAN}├${HLINE}┤${C_RESET}"
  if has_cmd ip; then
    local ip_addr
    ip_addr=$(ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2; exit}' || echo 'n/a')
    box_row "IPv4"      "$ip_addr"
  fi
  if has_cmd curl; then
    local ext_ip
    ext_ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo 'n/a')
    box_row "Public IP" "$ext_ip"
  fi

  # Docker
  if has_cmd docker; then
    local docker_ver
    docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    box_row "Docker"    "${docker_ver:-ok}"
  fi

  # Services
  echo -e "${C_BOLD}${C_CYAN}├${HLINE}┤${C_RESET}"
  local svc ssh_svc
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    ssh_svc="ssh"
  else
    ssh_svc="sshd"
  fi
  if systemctl is-active --quiet "$ssh_svc" 2>/dev/null; then
    box_row "SSH"       -e "${C_GREEN}running${C_RESET}"
  else
    box_row "SSH"       -e "${C_RED}stopped${C_RESET}"
  fi
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    box_row "NTP"       -e "${C_GREEN}synced${C_RESET}"
  else
    box_row "NTP"       -e "${C_YELLOW}not active${C_RESET}"
  fi

  section_end
}

show_sysinfo
