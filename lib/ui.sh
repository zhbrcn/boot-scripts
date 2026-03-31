#!/usr/bin/env bash
# lib/ui.sh — Shared TUI functions for boot-scripts
# Provides: colors, borders, menu, spinner, status indicators

set -euo pipefail

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || {
  echo "lib/ui.sh must be sourced, not executed" >&2
  exit 1
}

# ── Colors ────────────────────────────────────────────────────────────────────
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

# ── Status helpers ─────────────────────────────────────────────────────────────
ok()   { echo -e "  ${C_GREEN}✓${C_RESET}  $*"; }
fail() { echo -e "  ${C_RED}✗${C_RESET}  $*"; }
info() { echo -e "  ${C_BLUE}ℹ${C_RESET}  $*"; }
warn() { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }

# ── Box drawing ────────────────────────────────────────────────────────────────
HLINE=$(printf '─%.0s' {1..60})
TBORDER="┌${HLINE}┐"
BBORDER="└${HLINE}┘"

box_header() {
  echo -e "${C_BOLD}${C_CYAN}${TBORDER}${C_RESET}"
}

box_footer() {
  echo -e "${C_BOLD}${C_CYAN}${BBORDER}${C_RESET}"
}

box_row() {
  local label="$1"
  local value="$2"
  printf "  %-20s %s\n" "$label" "$value"
}

box_title() {
  local title="$1"
  local pad=$(( (60 - ${#title}) / 2 ))
  local left_pad=$(( pad + 2 ))
  printf "${C_BOLD}${C_CYAN}│%${left_pad}s${C_RESET}${C_BOLD}${C_WHITE}%s${C_RESET}${C_BOLD}${C_CYAN}%*s│${C_RESET}\n" "" "$title" $(( 60 - left_pad - ${#title} - 1 )) ""
}

# ── Spinner ────────────────────────────────────────────────────────────────────
_spin() {
  local pid=$1
  local delay=0.1
  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s  ' "${spin_chars:i%${#spin_chars}:1}"
    sleep "$delay"
    i=$(( (i + 1) % ${#spin_chars} ))
  done
  printf '\r     \r'
}

export -f _spin 2>/dev/null || true

run_with_spin() {
  local label="$1"
  shift
  echo -ne "  ${C_DIM}…${C_RESET} $label "
  "$@" &
  local pid=$!
  _spin "$pid" &
  local spin_pid=$!
  wait "$pid" 2>/dev/null || true
  kill "$spin_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  return $?
}

# ── Section ────────────────────────────────────────────────────────────────────
section() {
  local title="$1"
  echo ""
  box_header
  box_title "$title"
  echo -e "${C_BOLD}${C_CYAN}├${HLINE}┤${C_RESET}"
}

section_end() {
  box_footer
  echo ""
}

# ── Interactive menu ──────────────────────────────────────────────────────────
# $1 = title
# $2..$N = "label|action" pairs
menu() {
  local title="$1"
  shift
  local items=("$@")
  local choice
  local run_cmd=""

  while true; do
    clear
    section "$title"
    local i=1
    for item in "${items[@]}"; do
      local label="${item%%|*}"
      local val="${item#*|}"
      if [[ "$val" == "$item" ]]; then
        # No pipe — item is a category label (dim)
        echo -e "  ${C_DIM}$label${C_RESET}"
      else
        echo -e "  ${C_CYAN}[$i]${C_RESET} $label"
        i=$((i + 1))
      fi
    done
    section_end
    echo -e "  ${C_DIM}q) quit${C_RESET}"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      q|Q) return 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local idx=$((choice - 1))
          if (( idx >= 0 && idx < ${#items[@]} )); then
            local item="${items[$idx]}"
            local label="${item%%|*}"
            local val="${item#*|}"
            if [[ "$val" != "$item" ]]; then
              eval "$val"
              local ret=$?
              if (( ret != 0 )); then
                echo -e "\n  ${C_RED}✗ failed (exit $ret)${C_RESET}"
                read -rp "  press enter to continue…"
              fi
            fi
          fi
        fi
        ;;
    esac
  done
}

# ── Yes/No prompt ─────────────────────────────────────────────────────────────
yn() {
  local prompt="${1:-continue?}"
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]]
}

# ── Pause ─────────────────────────────────────────────────────────────────────
pause() {
  local msg="${1:-press enter to continue…}"
  read -rp "$msg"
}

# ── Progress bar ───────────────────────────────────────────────────────────────
progress_bar() {
  local current="${1:-0}"
  local total="${2:-100}"
  local width=40
  local pct=$(( current * 100 / total ))
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  printf "\r  [%s%s] %3d%% " \
    "$(printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null || echo '')" \
    "$(printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null || echo '')" \
    "$pct"
}
