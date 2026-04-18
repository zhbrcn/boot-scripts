#!/usr/bin/env bash
# lib/ui.sh - Shared TUI helpers for boot-scripts

set -euo pipefail

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || {
  echo "lib/ui.sh must be sourced, not executed" >&2
  exit 1
}

export C_RESET='\033[0m'
export C_BOLD='\033[1m'
export C_DIM='\033[2m'
export C_RED='\033[31m'
export C_GREEN='\033[32m'
export C_YELLOW='\033[33m'
export C_BLUE='\033[34m'
export C_MAGENTA='\033[35m'
export C_CYAN='\033[36m'
export C_WHITE='\033[37m'

UI_BOX_WIDTH="${UI_BOX_WIDTH:-64}"
HLINE="$(printf -- '-%.0s' $(seq 1 "$UI_BOX_WIDTH"))"

status_line() {
  local marker="$1"
  local color="$2"
  shift 2
  echo -e "  ${color}${marker}${C_RESET}  $*"
}

ok()   { status_line "OK"  "$C_GREEN" "$@"; }
fail() { status_line "ERR" "$C_RED" "$@"; }
info() { status_line ".."  "$C_BLUE" "$@"; }
warn() { status_line "!!"  "$C_YELLOW" "$@"; }

box_header() {
  echo -e "${C_BOLD}${C_CYAN}+${HLINE}+${C_RESET}"
}

box_footer() {
  echo -e "${C_BOLD}${C_CYAN}+${HLINE}+${C_RESET}"
}

box_title() {
  local title=" $1 "
  printf "%b|%-${UI_BOX_WIDTH}s|%b\n" "${C_BOLD}${C_CYAN}" "$title" "${C_RESET}"
}

box_sep() {
  echo -e "${C_BOLD}${C_CYAN}+${HLINE}+${C_RESET}"
}

box_row() {
  local label="$1"
  local value="$2"
  printf "  %-18s %b\n" "$label" "$value"
}

section() {
  local title="$1"
  echo ""
  box_header
  box_title "$title"
  box_sep
}

section_end() {
  box_footer
  echo ""
}

_spin() {
  local pid=$1
  local chars='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s ' "${chars:i%${#chars}:1}"
    sleep 0.1
    i=$((i + 1))
  done
  printf '\r    \r'
}

export -f _spin 2>/dev/null || true

run_with_spin() {
  local label="$1"
  shift
  echo -ne "  ${C_DIM}${label}${C_RESET} "
  "$@" &
  local pid=$!
  _spin "$pid" &
  local spin_pid=$!
  wait "$pid" 2>/dev/null || true
  kill "$spin_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  return $?
}

clear_screen() {
  has_cmd clear && clear || true
}

refresh_screen() {
  clear_screen
}

read_choice() {
  local prompt="${1:-  select [q]: }"
  local value
  read -rp "$prompt" value
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

menu() {
  local title="$1"
  shift
  local items=("$@")
  local labels=()
  local actions=()
  local item label action
  local choice
  local i

  while true; do
    clear_screen
    section "$title"
    labels=()
    actions=()
    i=1
    for item in "${items[@]}"; do
      label="${item%%|*}"
      action="${item#*|}"
      if [[ "$action" == ":" || "$action" == "$item" ]]; then
        echo -e "  ${C_DIM}${label}${C_RESET}"
      else
        echo -e "  ${C_CYAN}$i)${C_RESET} $label"
        labels+=("$label")
        actions+=("$action")
        i=$((i + 1))
      fi
    done
    section_end
    choice="$(read_choice "  select [q]: ")"

    case "$choice" in
      q|Q|"") return 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#actions[@]} )); then
          eval "${actions[$((choice - 1))]}"
          local ret=$?
          if (( ret != 0 )); then
            echo ""
            fail "${labels[$((choice - 1))]} failed (exit $ret)"
            pause
          fi
        fi
        ;;
    esac
  done
}

yn() {
  local prompt="${1:-continue?}"
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]]
}

pause() {
  local msg="${1:-press enter to continue...}"
  read -rp "$msg"
}

progress_bar() {
  local current="${1:-0}"
  local total="${2:-100}"
  local width=40
  local pct=$(( current * 100 / total ))
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local filled_bar=""
  local empty_bar=""

  if (( filled > 0 )); then
    filled_bar="$(printf '#%.0s' $(seq 1 "$filled" 2>/dev/null) 2>/dev/null || true)"
  fi
  if (( empty > 0 )); then
    empty_bar="$(printf '.%.0s' $(seq 1 "$empty" 2>/dev/null) 2>/dev/null || true)"
  fi

  printf "\r  [%s%s] %3d%% " \
    "$filled_bar" \
    "$empty_bar" \
    "$pct"
}
