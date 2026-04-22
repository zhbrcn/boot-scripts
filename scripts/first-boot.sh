#!/usr/bin/env bash
# first-boot.sh - Guided first-run checklist for a fresh host

set -euo pipefail

_src="${BASH_SOURCE[0]}"
_script_dir="$(cd "$(dirname "$_src")" && pwd)"
_dir="$_script_dir"
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

run_local_script() {
  local name="$1"
  shift
  bash "${_script_dir}/${name}.sh" "$@"
}

prompt_yes() {
  local prompt="$1"
  yn "$prompt"
}

choose_login_mode() {
  local choice preset=""

  echo ""
  echo -e "  ${C_BOLD}Choose SSH mode${C_RESET}"
  echo -e "  ${C_CYAN}1)${C_RESET} YubiKey direct"
  echo -e "  ${C_CYAN}2)${C_RESET} Daily admin"
  echo -e "  ${C_CYAN}3)${C_RESET} Key only"
  echo -e "  ${C_CYAN}4)${C_RESET} Root password"
  echo -e "  ${C_CYAN}0)${C_RESET} skip"
  echo ""
  read -rp "  select: " choice

  case "$choice" in
    1) preset="yubikey-only" ;;
    2) preset="daily-admin" ;;
    3) preset="key-only" ;;
    4) preset="root-password" ;;
    0|"") return 0 ;;
    *) warn "invalid choice"; return 1 ;;
  esac

  run_local_script sshman --apply "$preset"
}

show_summary() {
  section "first boot summary"
  box_row "Hostname" "$(hostname -f 2>/dev/null || hostname)"
  box_row "Timezone" "$(has_cmd timedatectl && timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
  box_row "IPv4" "$(has_cmd ip && ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2; exit}' || echo n/a)"
  box_row "SSH mode" "$(run_local_script sshman --status | awk '/Current mode/{sub(/^[[:space:]]+/, "", $0); print $0; exit}' || echo configured)"
  section_end
}

guided_run() {
  need_root
  refresh_screen
  section "first boot"
  box_row "Goal" "prepare a fresh Debian/Ubuntu host"
  box_row "Flow" "hostname -> network -> time -> SSH -> packages -> tmux"
  section_end

  if prompt_yes "set hostname now?"; then
    run_local_script hostname
  fi

  if prompt_yes "review network and region settings?"; then
    run_local_script network
  fi

  if prompt_yes "sync system time now?"; then
    run_local_script fix-time
  fi

  if prompt_yes "choose SSH login mode now?"; then
    choose_login_mode
  fi

  if prompt_yes "install core package set?"; then
    run_local_script base-packages --profile core
  fi

  if prompt_yes "install admin package set?"; then
    run_local_script base-packages --profile admin
  fi

  if prompt_yes "install network package set?"; then
    run_local_script base-packages --profile network
  fi

  if prompt_yes "configure SSH auto-attach tmux workspace?"; then
    run_local_script tmux-workspace --apply
  fi

  show_summary
}

main() {
  case "${1:-}" in
    -h|--help)
      echo "Usage:"
      echo "  first-boot.sh"
      ;;
    "")
      guided_run
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
}

main "$@"
