#!/usr/bin/env bash
# base-packages.sh - Install common package sets for a fresh Debian/Ubuntu host

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

CORE_PACKAGES=(curl wget git vim htop rsync unzip ca-certificates bash-completion)
ADMIN_PACKAGES=(sudo tmux screen jq lsof file tree)
NETWORK_PACKAGES=(dnsutils net-tools traceroute iproute2 iputils-ping socat)

profile_packages() {
  case "${1:-}" in
    core) printf '%s\n' "${CORE_PACKAGES[@]}" ;;
    admin) printf '%s\n' "${ADMIN_PACKAGES[@]}" ;;
    network) printf '%s\n' "${NETWORK_PACKAGES[@]}" ;;
    *)
      echo "unknown profile: $1" >&2
      return 1
      ;;
  esac
}

is_installed_pkg() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'
}

install_package_list() {
  local packages=("$@")
  local pkg
  local pending=()

  need_root
  has_cmd apt-get || {
    fail "apt-get not found"
    return 1
  }

  for pkg in "${packages[@]}"; do
    [[ -n "$pkg" ]] || continue
    is_installed_pkg "$pkg" && continue
    pending+=("$pkg")
  done

  if (( ${#pending[@]} == 0 )); then
    ok "all selected packages are already installed"
    return 0
  fi

  info "installing: ${pending[*]}"
  apt-get update -y
  apt-get install -y "${pending[@]}"
  ok "package installation complete"
}

show_status() {
  local core_count=0 admin_count=0 network_count=0 pkg

  for pkg in "${CORE_PACKAGES[@]}"; do is_installed_pkg "$pkg" && core_count=$((core_count + 1)); done
  for pkg in "${ADMIN_PACKAGES[@]}"; do is_installed_pkg "$pkg" && admin_count=$((admin_count + 1)); done
  for pkg in "${NETWORK_PACKAGES[@]}"; do is_installed_pkg "$pkg" && network_count=$((network_count + 1)); done

  section "base packages"
  box_row "Core profile" "${core_count}/${#CORE_PACKAGES[@]} installed"
  box_row "Admin profile" "${admin_count}/${#ADMIN_PACKAGES[@]} installed"
  box_row "Network profile" "${network_count}/${#NETWORK_PACKAGES[@]} installed"
  box_sep
  box_row "Core set" "${CORE_PACKAGES[*]}"
  box_row "Admin set" "${ADMIN_PACKAGES[*]}"
  box_row "Network set" "${NETWORK_PACKAGES[*]}"
  section_end
}

install_custom_packages() {
  local input
  local packages=()

  echo ""
  echo -e "  ${C_BOLD}Install custom packages${C_RESET}"
  echo -e "  ${C_DIM}space-separated apt package names${C_RESET}"
  read -rp "  packages: " input
  [[ -n "$input" ]] || {
    warn "empty package list"
    return 1
  }
  read -r -a packages <<< "$input"
  install_package_list "${packages[@]}"
}

interactive_menu() {
  local choice

  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Install sets${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} core packages"
    echo -e "  ${C_CYAN}2)${C_RESET} admin packages"
    echo -e "  ${C_CYAN}3)${C_RESET} network packages"
    echo -e "  ${C_CYAN}4)${C_RESET} install all profiles"
    echo -e "  ${C_CYAN}5)${C_RESET} custom package list"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) mapfile -t _pkgs < <(profile_packages core); install_package_list "${_pkgs[@]}" ;;
      2) mapfile -t _pkgs < <(profile_packages admin); install_package_list "${_pkgs[@]}" ;;
      3) mapfile -t _pkgs < <(profile_packages network); install_package_list "${_pkgs[@]}" ;;
      4) install_package_list "${CORE_PACKAGES[@]}" "${ADMIN_PACKAGES[@]}" "${NETWORK_PACKAGES[@]}" ;;
      5) install_custom_packages ;;
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
    --profile)
      [[ -n "${2:-}" ]] || { echo "usage: base-packages.sh --profile <core|admin|network>" >&2; exit 2; }
      mapfile -t _pkgs < <(profile_packages "$2")
      install_package_list "${_pkgs[@]}"
      ;;
    --install)
      shift
      [[ $# -gt 0 ]] || { echo "usage: base-packages.sh --install <pkg>..." >&2; exit 2; }
      install_package_list "$@"
      ;;
    -h|--help)
      echo "Usage:"
      echo "  base-packages.sh"
      echo "  base-packages.sh --status"
      echo "  base-packages.sh --profile <core|admin|network>"
      echo "  base-packages.sh --install <pkg>..."
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
