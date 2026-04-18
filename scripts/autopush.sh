#!/usr/bin/env bash
# autopush.sh - Configure git autopush alias

set -uo pipefail

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

Behavior:
  - only runs inside a git repository
  - stages all changes before commit
  - exits cleanly when there is nothing to commit
  - sets upstream automatically on first push

EOF
}

is_enabled() {
  (git config --global alias.autopush >/dev/null 2>&1) && return 0 || return 1
}

alias_value() {
  cat <<'EOF'
!f() { if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo "error: not a git repository" >&2; return 1; fi; git add -A; if git diff --cached --quiet --exit-code >/dev/null 2>&1; then echo "nothing to commit"; return 0; fi; if [ -z "$1" ]; then git commit -m "Auto Push on $(date +'%Y-%m-%d %H:%M:%S')"; else git commit -m "$1"; fi; branch=$(git branch --show-current); if [ -z "$branch" ]; then echo "error: could not determine current branch" >&2; return 1; fi; if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then git push; else git push -u origin "$branch"; fi; }; f
EOF
}

enable() {
  if is_enabled; then
    echo "  autopush is already enabled"
    echo "  Current alias:"
    (git config --global alias.autopush 2>/dev/null) || true
    return 0
  fi

  git config --global alias.autopush "$(alias_value)"
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
