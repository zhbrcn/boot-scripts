#!/usr/bin/env bash
# boot.sh - Unified entry point for boot-scripts

set -euo pipefail

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

BOOTSTRAP_SCRIPTS=(
  "first-boot.sh"
  "base-packages.sh"
  "network.sh"
  "sshman.sh"
  "fix-time.sh"
  "hostname.sh"
  "sysinfo.sh"
  "autopush.sh"
)
BOOTSTRAP_LIBS=(
  "common.sh"
  "ui.sh"
)

_src="${BASH_SOURCE[0]}"
_bin_dir="$(cd "$(dirname "$_src")" && pwd)"
_state_file="${_bin_dir}/.boot-scripts-dir"

if [[ -d "$_bin_dir/../scripts" ]] && [[ -d "$_bin_dir/../lib" ]]; then
  _repo_root="$(cd "$_bin_dir/.." && pwd)"
elif [[ "$(basename "$_bin_dir")" == "bin" ]]; then
  _repo_root="$(cd "$_bin_dir/.." && pwd)"
else
  _repo_root="$_bin_dir"
fi

if [[ -z "${BOOT_SCRIPTS_DIR:-}" ]] && [[ -f "$_state_file" ]]; then
  BOOT_SCRIPTS_DIR="$(tr -d '\r' < "$_state_file" 2>/dev/null || true)"
fi

SCRIPTS_DIR="${BOOT_SCRIPTS_DIR:-${_repo_root}/scripts}"
LIB_DIR="${_repo_root}/lib"
BOOT_SCRIPTS_BASE_URL="${BOOT_SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts}"
BOOT_LIB_BASE_URL="${BOOT_LIB_BASE_URL:-https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/lib}"

load_ui() {
  [[ -f "${_repo_root}/lib/common.sh" ]] && source "${_repo_root}/lib/common.sh"
  [[ -f "${_repo_root}/lib/ui.sh" ]] && source "${_repo_root}/lib/ui.sh"

  if declare -F menu >/dev/null 2>&1; then
    return 0
  fi

  export C_RESET=""
  export C_BOLD=""
  export C_DIM=""
  export C_RED=""
  export C_GREEN=""
  export C_YELLOW=""
  export C_BLUE=""
  export C_CYAN=""

  section() { printf '\n%s\n' "$1"; }
  section_end() { echo ""; }
  ok() { echo "  OK  $*"; }
  fail() { echo "  ERR $*"; }
  menu() {
    local title="$1"
    shift
    local items=("$@")
    local actions=()
    local labels=()
    local item label action choice idx

    while true; do
      printf '\n%s\n' "$title"
      actions=()
      labels=()
      idx=1
      for item in "${items[@]}"; do
        label="${item%%|*}"
        action="${item#*|}"
        if [[ "$action" == ":" || "$action" == "$item" ]]; then
          printf '  %s\n' "$label"
        else
          printf '  %d) %s\n' "$idx" "$label"
          labels+=("$label")
          actions+=("$action")
          idx=$((idx + 1))
        fi
      done
      printf '\n'
      read -rp "  select [q]: " choice
      case "$choice" in
        q|Q|"") return 0 ;;
        *)
          if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#actions[@]} )); then
            eval "${actions[$((choice - 1))]}"
          fi
          ;;
      esac
    done
  }
}

usage() {
  cat <<EOF
boot.sh - boot-scripts unified runner

Usage:
  boot.sh --list
  boot.sh --run <name>
  boot.sh --all
  boot.sh --menu
  boot.sh --bootstrap [--dir <path>]

Environment:
  BOOT_SCRIPTS_DIR       scripts directory
  BOOT_SCRIPTS_BASE_URL  scripts URL for bootstrap
  BOOT_LIB_BASE_URL      lib URL for bootstrap
EOF
}

list_scripts() {
  if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "scripts dir not found: $SCRIPTS_DIR" >&2
    return 1
  fi

  shopt -s nullglob
  local files=("$SCRIPTS_DIR"/*.sh)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no scripts found in $SCRIPTS_DIR" >&2
    return 1
  fi

  local file
  for file in "${files[@]}"; do
    basename "$file" .sh
  done | sort
}

downloader_cmd() {
  if has_cmd curl; then
    echo "curl -fsSL"
    return 0
  fi

  if has_cmd wget; then
    echo "wget -qO-"
    return 0
  fi

  if is_root && has_cmd apt-get; then
    echo "  curl/wget not found - installing curl..." >&2
    apt-get update -qq
    apt-get install -y curl >/dev/null 2>&1 || {
      echo "error: apt-get install curl failed" >&2
      return 1
    }
    echo "curl -fsSL"
    return 0
  fi

  echo "error: neither curl nor wget found" >&2
  return 1
}

download_file() {
  local downloader="$1"
  local url="$2"
  local dest="$3"
  local mode="${4:-0644}"
  local tmp="${dest}.tmp"

  printf '  downloading %s... ' "$(basename "$dest")"
  if $downloader "$url" > "$tmp" 2>/dev/null; then
    chmod "$mode" "$tmp"
    mv "$tmp" "$dest"
    echo "ok"
  else
    rm -f "$tmp"
    echo "failed"
    return 1
  fi
}

bootstrap_scripts() {
  local out_dir="${1:-$SCRIPTS_DIR}"
  local lib_dir="$LIB_DIR"
  local downloader
  local name

  mkdir -p "$out_dir" "$lib_dir"
  downloader="$(downloader_cmd)" || return 1

  for name in "${BOOTSTRAP_SCRIPTS[@]}"; do
    download_file "$downloader" "${BOOT_SCRIPTS_BASE_URL}/${name}" "${out_dir}/${name}" 0755 || true
  done

  for name in "${BOOTSTRAP_LIBS[@]}"; do
    download_file "$downloader" "${BOOT_LIB_BASE_URL}/${name}" "${lib_dir}/${name}" 0644 || true
  done

  printf '%s\n' "$out_dir" > "$_state_file"
  echo "  scripts dir saved to $_state_file"
}

resolve_script() {
  local name="$1"
  local direct="$SCRIPTS_DIR/$name"
  local with_ext="$SCRIPTS_DIR/$name.sh"

  [[ -n "$name" ]] || {
    echo "error: script name required" >&2
    return 1
  }
  [[ -f "$direct" ]] && { printf '%s' "$direct"; return 0; }
  [[ -f "$with_ext" ]] && { printf '%s' "$with_ext"; return 0; }

  echo "error: script not found: $name" >&2
  return 1
}

run_script() {
  local script="$1"
  shift

  [[ -f "$script" && -r "$script" ]] || {
    echo "error: not readable: $script" >&2
    return 1
  }

  local name
  name="$(basename "$script" .sh)"
  echo ""
  echo "=== running: $name ==="
  echo ""
  bash "$script" "$@"
}

has_script() {
  [[ -f "$SCRIPTS_DIR/$1.sh" ]]
}

interactive_menu() {
  load_ui
  list_scripts >/dev/null

  local items=(
    "- System -|:"
    "first boot|run_script \"\$SCRIPTS_DIR/first-boot.sh\""
    "system info|run_script \"\$SCRIPTS_DIR/sysinfo.sh\" --hold"
    "- Access -|:"
  )

  has_script sshman && items+=("ssh manager|run_script \"\$SCRIPTS_DIR/sshman.sh\" --interactive")

  if has_script autopush; then
    items+=("autopush|toggle_autopush")
  fi

  items+=(
    "- Repair -|:"
  )
  has_script network && items+=("network|run_script \"\$SCRIPTS_DIR/network.sh\"")
  has_script fix-time && items+=("time sync|run_script \"\$SCRIPTS_DIR/fix-time.sh\"")
  has_script hostname && items+=("hostname|run_script \"\$SCRIPTS_DIR/hostname.sh\"")
  has_script base-packages && items+=("base packages|run_script \"\$SCRIPTS_DIR/base-packages.sh\"")

  items+=(
    "- Utility -|:"
    "refresh scripts|bootstrap_scripts \"\$SCRIPTS_DIR\""
  )

  menu "boot-scripts" "${items[@]}"
}

toggle_autopush() {
  run_script "$SCRIPTS_DIR/autopush.sh" --toggle || return $?
}

run_all_scripts() {
  local scripts=()
  local name

  while IFS= read -r name; do
    scripts+=("$name")
  done < <(list_scripts)

  local failed=0
  for name in "${scripts[@]}"; do
    run_script "$SCRIPTS_DIR/${name}.sh" || failed=$((failed + 1))
  done

  if (( failed > 0 )); then
    echo ""
    echo "$failed script(s) failed"
    return 1
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 2
  fi

  case "$1" in
    --list)
      list_scripts
      ;;
    --run)
      shift
      local name="${1:-}"
      [[ -n "$name" ]] || {
        echo "error: --run requires <name>" >&2
        exit 2
      }
      local script
      script="$(resolve_script "$name")" || exit 1
      shift
      run_script "$script" "$@"
      ;;
    --all)
      run_all_scripts
      ;;
    --menu)
      interactive_menu
      ;;
    --bootstrap)
      shift
      local dir="$SCRIPTS_DIR"
      if [[ "${1:-}" == "--dir" ]]; then
        dir="${2:-$SCRIPTS_DIR}"
      fi
      bootstrap_scripts "$dir"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
