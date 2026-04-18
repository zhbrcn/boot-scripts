#!/usr/bin/env bash
# autopush.sh - Configure git autopush alias

set -euo pipefail

_src="${BASH_SOURCE[0]}"
_bin_dir="$(cd "$(dirname "$_src")" && pwd)"
_repo_root="$(cd "$_bin_dir/.." && pwd)"

usage() {
  cat <<EOF
autopush.sh - Configure git autopush alias

Usage:
  autopush.sh [--enable] [--disable] [--status]

Options:
  --enable   Enable autopush alias (default if no option)
  --disable  Remove autopush alias
  --status   Show current autopush configuration

EOF
}

is_enabled() {
  git config --global alias.autopush >/dev/null 2>&1 && return 0 || return 1
}

enable() {
  if is_enabled; then
    echo "  autopush is already enabled"
    echo "  Current alias:"
    git config --global alias.autopush
    return 0
  fi

  git config --global alias.autopush '!f() { git add -A; if [ -z "$1" ]; then git commit -m "Auto Push on $(date +"%Y-%m-%d %H:%M:%S")"; else git commit -m "$1"; fi; git push; }; f'
  echo "  autopush enabled"
  echo ""
  echo "  Usage:"
  echo "    git autopush              # commit with timestamp"
  echo "    git autopush \"message\"    # commit with custom message"
}

disable() {
  if ! is_enabled; then
    echo "  autopush is not enabled"
    return 0
  fi

  git config --global --unset alias.autopush
  echo "  autopush disabled"
}

status() {
  if is_enabled; then
    echo "  autopush: enabled"
    echo "  Alias: $(git config --global --get alias.autopush 2>/dev/null || echo 'N/A')"
  else
    echo "  autopush: disabled"
  fi
}

main() {
  case "${1:-}" in
    --enable)
      enable
      ;;
    --disable)
      disable
      ;;
    --status)
      status
      ;;
    -h|--help)
      usage
      ;;
    "")
      enable
      ;;
    *)
      echo "  Unknown option: $1"
      usage
      exit 2
      ;;
  esac
}

main "$@"
