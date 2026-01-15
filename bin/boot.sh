#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/../scripts" ]]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  ROOT_DIR="$SCRIPT_DIR"
fi
SCRIPTS_DIR="${BOOT_SCRIPTS_DIR:-$ROOT_DIR/scripts}"

usage() {
  cat <<'EOF'
Usage:
  boot.sh --list
  boot.sh --run <name> [-- <args...>]
  boot.sh --all
  boot.sh --bootstrap [--dir <path>]
  boot.sh --menu

Notes:
- Scripts are loaded from ./scripts/*.sh
- Order for --all is lexicographic; use numeric prefixes to control order.
- --bootstrap downloads known scripts when scripts dir is empty.
 - --menu provides an interactive selector.
EOF
}

list_scripts() {
  if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "scripts dir not found: $SCRIPTS_DIR" >&2
    return 1
  fi
  shopt -s nullglob
  local files=("$SCRIPTS_DIR"/*.sh)
  for f in "${files[@]}"; do
    basename "$f" .sh
  done | sort
}

download_scripts() {
  local out_dir="${1:-$SCRIPTS_DIR}"
  local base_url="${BOOT_SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts}"
  local scripts=("sshman.sh" "fix-time.sh")

  mkdir -p "$out_dir"
  local downloader=""
  if command -v curl >/dev/null 2>&1; then
    downloader="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    downloader="wget -qO-"
  else
    echo "neither curl nor wget found; cannot bootstrap" >&2
    return 1
  fi

  local name url tmp
  for name in "${scripts[@]}"; do
    url="${base_url}/${name}"
    tmp="${out_dir}/${name}.tmp"
    if ! $downloader "$url" >"$tmp"; then
      echo "failed to download: $url" >&2
      rm -f "$tmp"
      return 1
    fi
    mv "$tmp" "${out_dir}/${name}"
    chmod +x "${out_dir}/${name}" || true
  done
}

resolve_script() {
  local name="$1"
  local cand
  if [[ -z "$name" ]]; then
    return 1
  fi
  if [[ -f "$SCRIPTS_DIR/$name" ]]; then
    cand="$SCRIPTS_DIR/$name"
  else
    cand="$SCRIPTS_DIR/$name.sh"
  fi
  if [[ ! -f "$cand" ]]; then
    echo "script not found: $name" >&2
    return 1
  fi
  printf '%s' "$cand"
}

interactive_menu() {
  local scripts=()
  while IFS= read -r s; do
    scripts+=("$s")
  done < <(list_scripts)

  if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "no scripts found in $SCRIPTS_DIR" >&2
    return 1
  fi

  while true; do
    echo ""
    echo "boot-scripts menu"
    echo "----------------------------------------"
    local i=1
    for s in "${scripts[@]}"; do
      printf " %2d) %s\n" "$i" "$s"
      i=$((i + 1))
    done
    echo "  a) run all"
    echo "  r) refresh list"
    echo "  q) quit"
    echo ""

    read -rp "select: " choice
    case "$choice" in
      q|Q) return 0 ;;
      r|R)
        scripts=()
        while IFS= read -r s; do
          scripts+=("$s")
        done < <(list_scripts)
        ;;
      a|A)
        local script
        for script in "${scripts[@]}"; do
          run_script "$SCRIPTS_DIR/$script.sh"
        done
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local idx=$((choice - 1))
          if (( idx >= 0 && idx < ${#scripts[@]} )); then
            run_script "$SCRIPTS_DIR/${scripts[$idx]}.sh"
          else
            echo "invalid selection: $choice" >&2
          fi
        else
          echo "invalid selection: $choice" >&2
        fi
        ;;
    esac
  done
}

run_script() {
  local script="$1"
  shift
  if [[ ! -x "$script" ]]; then
    echo "script is not executable: $script" >&2
    return 1
  fi
  "$script" "$@"
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
      shift || true
      local args=()
      if [[ "${1:-}" == "--" ]]; then
        shift
        args=("$@")
      else
        args=("$@")
      fi
      local script
      script="$(resolve_script "$name")"
      run_script "$script" "${args[@]}"
      ;;
    --all)
      local scripts=()
      while IFS= read -r s; do
        scripts+=("$SCRIPTS_DIR/$s.sh")
      done < <(list_scripts)
      if [[ ${#scripts[@]} -eq 0 ]]; then
        echo "no scripts found in $SCRIPTS_DIR" >&2
        exit 1
      fi
      for script in "${scripts[@]}"; do
        run_script "$script"
      done
      ;;
    --bootstrap)
      shift
      local dir="$SCRIPTS_DIR"
      if [[ "${1:-}" == "--dir" ]]; then
        dir="${2:-$SCRIPTS_DIR}"
      fi
      download_scripts "$dir"
      ;;
    --menu)
      interactive_menu
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
