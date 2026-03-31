#!/usr/bin/env bash
# boot.sh — Unified entry point for boot-scripts
#
# Usage:
#   boot.sh --list              list available scripts
#   boot.sh --run <name>        run one script
#   boot.sh --all               run all scripts in order
#   boot.sh --menu              interactive TUI menu
#   boot.sh --bootstrap [--dir <path>]  bootstrap scripts dir from GitHub

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
_src="${BASH_SOURCE[0]}"
_bin_dir="$(cd "$(dirname "$_src")" && pwd)"
_repo_root="$(cd "$_bin_dir/.." && pwd)"

SCRIPTS_DIR="${BOOT_SCRIPTS_DIR:-${_repo_root}/scripts}"
BOOT_SCRIPTS_BASE_URL="${BOOT_SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts}"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
boot.sh — boot-scripts unified runner

Usage:
  boot.sh --list              list available scripts
  boot.sh --run <name>        run one script
  boot.sh --all               run all scripts in lexicographic order
  boot.sh --menu              interactive TUI menu
  boot.sh --bootstrap [--dir <path>]   bootstrap scripts from GitHub

Environment:
  BOOT_SCRIPTS_DIR      scripts directory (default: ./scripts)
  BOOT_SCRIPTS_BASE_URL  base URL for --bootstrap (default: GitHub raw)
EOF
}

# ── Source shared libs ────────────────────────────────────────────────────────
if [[ -f "${_repo_root}/lib/common.sh" ]]; then
  source "${_repo_root}/lib/common.sh"
fi
if [[ -f "${_repo_root}/lib/ui.sh" ]]; then
  source "${_repo_root}/lib/ui.sh"
fi

# ── List ──────────────────────────────────────────────────────────────────────
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
  for f in "${files[@]}"; do
    basename "$f" .sh
  done | sort
}

# ── Download / Bootstrap ──────────────────────────────────────────────────────
bootstrap_scripts() {
  local out_dir="${1:-$SCRIPTS_DIR}"
  mkdir -p "$out_dir"

  local scripts=("sshman.sh" "fix-time.sh" "sysinfo.sh")
  local downloader

  if has_cmd curl; then
    downloader="curl -fsSL"
  elif has_cmd wget; then
    downloader="wget -qO-"
  else
    echo "error: neither curl nor wget found" >&2
    return 1
  fi

  for name in "${scripts[@]}"; do
    local url="${BOOT_SCRIPTS_BASE_URL}/${name}"
    local dest="${out_dir}/${name}"
    local tmp="${dest}.tmp"

    echo -n "  downloading $name… "
    if $downloader "$url" > "$tmp" 2>/dev/null; then
      chmod +x "$tmp"
      mv "$tmp" "$dest"
      echo "ok"
    else
      rm -f "$tmp"
      echo "failed (skipping)"
    fi
  done
}

# ── Resolve & run ─────────────────────────────────────────────────────────────
resolve_script() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "error: script name required" >&2
    return 1
  fi
  local cand
  if [[ -f "$SCRIPTS_DIR/$name" ]]; then
    cand="$SCRIPTS_DIR/$name"
  elif [[ -f "$SCRIPTS_DIR/$name.sh" ]]; then
    cand="$SCRIPTS_DIR/$name.sh"
  else
    echo "error: script not found: $name" >&2
    return 1
  fi
  printf '%s' "$cand"
}

run_script() {
  local script="$1"
  shift
  [[ ! -f "$script" ]] && { echo "error: not found: $script" >&2; return 1; }
  [[ ! -r "$script" ]] && { echo "error: not readable: $script" >&2; return 1; }

  local name
  name=$(basename "$script" .sh)
  echo ""
  echo -e "${C_BOLD}═══ running: ${name} ═══${C_RESET}"
  echo ""

  # Run in current shell context so LIB_LOADED propagates
  # Use bash explicitly to respect shebang
  bash "$script" "$@"
  local ret=$?
  if (( ret == 0 )); then
    echo ""
    echo -e "${C_GREEN}✓ $name completed${C_RESET}"
  else
    echo ""
    echo -e "${C_RED}✗ $name failed (exit $ret)${C_RESET}"
  fi
  return $ret
}

# ── Interactive menu ───────────────────────────────────────────────────────────
interactive_menu() {
  local script_names=()
  while IFS= read -r s; do
    script_names+=("$s")
  done < <(list_scripts)

  if [[ ${#script_names[@]} -eq 0 ]]; then
    echo "no scripts found in $SCRIPTS_DIR" >&2
    return 1
  fi

  # Build menu items array: "Display Name|bash ..."
  local menu_items=()
  for s in "${script_names[@]}"; do
    menu_items+=("${s}|run_script \"\$SCRIPTS_DIR/${s}.sh\"")
  done

  # Prepend sysinfo as always-available
  local all_items=(
    "─ System Info ─|:"
  )
  all_items+=("sysinfo|run_script \"\$SCRIPTS_DIR/sysinfo.sh\"")
  all_items+=("─ SSH Management ─|:")

  # Find sshman
  for s in "${script_names[@]}"; do
    [[ "$s" == "sshman" ]] && all_items+=("${s}|run_script \"\$SCRIPTS_DIR/${s}.sh\" --interactive")
  done
  all_items+=("─ Time / Network ─|:")
  for s in "${script_names[@]}"; do
    [[ "$s" == "fix-time" ]] && all_items+=("${s}|run_script \"\$SCRIPTS_DIR/${s}.sh\"")
  done
  all_items+=("─ All Scripts ─|:")
  all_items+=("run all (--all)|run_all_scripts")
  all_items+=("─ Utility ─|:")
  all_items+=("bootstrap scripts|bootstrap_scripts \"\$SCRIPTS_DIR\"")
  all_items+=("quit|:|exit 0")

  menu "boot-scripts" "${all_items[@]}"
}

run_all_scripts() {
  local scripts=()
  while IFS= read -r s; do
    scripts+=("$s")
  done < <(list_scripts)

  local failed=0
  for s in "${scripts[@]}"; do
    run_script "$SCRIPTS_DIR/${s}.sh" || failed=$((failed + 1))
  done

  if (( failed > 0 )); then
    echo ""
    echo -e "${C_YELLOW}⚠ $failed script(s) failed${C_RESET}"
    return 1
  fi
  echo ""
  echo -e "${C_GREEN}✓ all scripts completed successfully${C_RESET}"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────
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
      [[ -z "$name" ]] && { echo "error: --run requires <name>" >&2; exit 2; }
      local script
      script=$(resolve_script "$name") || exit 1
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
        shift 2
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
