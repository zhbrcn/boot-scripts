#!/usr/bin/env bash
# tmux-workspace.sh - Configure SSH login auto-attach to a fixed tmux session

set -euo pipefail

SESSION_NAME="${TMUX_SESSION_NAME:-main}"
AUTOBLOCK_BEGIN="# >>> boot-scripts tmux auto attach >>>"
AUTOBLOCK_END="# <<< boot-scripts tmux auto attach <<<"

TMUX_CONF_FILE="${HOME}/.tmux.conf"
BASHRC_FILE="${HOME}/.bashrc"
ZSHRC_FILE="${HOME}/.zshrc"

usage() {
  cat <<EOF2
tmux-workspace.sh - Configure SSH login auto-attach to tmux session '${SESSION_NAME}'

Usage:
  tmux-workspace.sh [--session <name>] [--apply] [--remove] [--status]

Options:
  --session <name>  Override tmux session name (default: main)
  --apply           Install or update tmux + shell auto-attach config (default)
  --remove          Remove managed auto-attach block from shell rc files
  --status          Show current configuration status
  -h, --help        Show this help
EOF2
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
}

run_pkg_cmd() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif has_cmd sudo; then
    sudo "$@"
  else
    echo "error: need root or sudo to install tmux" >&2
    return 1
  fi
}

install_tmux() {
  if has_cmd tmux; then
    echo "tmux already installed"
    return 0
  fi

  if has_cmd apt-get; then
    run_pkg_cmd apt-get update -y
    run_pkg_cmd apt-get install -y tmux
  elif has_cmd dnf; then
    run_pkg_cmd dnf install -y tmux
  elif has_cmd yum; then
    run_pkg_cmd yum install -y tmux
  else
    echo "error: unsupported package manager (need apt-get/dnf/yum)" >&2
    return 1
  fi

  has_cmd tmux || { echo "error: tmux installation failed" >&2; return 1; }
  echo "tmux installed"
}

write_tmux_conf() {
  local begin="# >>> boot-scripts tmux defaults >>>"
  local end="# <<< boot-scripts tmux defaults <<<"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$TMUX_CONF_FILE" ]]; then
    backup_file "$TMUX_CONF_FILE"
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$TMUX_CONF_FILE" > "$tmp"
  fi

  {
    cat "$tmp" 2>/dev/null || true
    [[ -s "$tmp" ]] && echo ""
    cat <<EOF2
$begin
set -g mouse on
set -g history-limit 100000
setw -g mode-keys vi
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g detach-on-destroy off
set -g set-clipboard on
$end
EOF2
  } > "$TMUX_CONF_FILE"

  rm -f "$tmp"
}

managed_shell_block() {
  cat <<EOF2
$AUTOBLOCK_BEGIN
if [ -z "\${TMUX:-}" ] && [ -n "\${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
  exec tmux new-session -A -s "$SESSION_NAME"
fi
$AUTOBLOCK_END
EOF2
}

update_shell_rc() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  [[ -f "$file" ]] || touch "$file"
  backup_file "$file"

  awk -v b="$AUTOBLOCK_BEGIN" -v e="$AUTOBLOCK_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"

  {
    cat "$tmp"
    [[ -s "$tmp" ]] && echo ""
    managed_shell_block
  } > "$file"

  rm -f "$tmp"
}

remove_shell_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  backup_file "$file"
  awk -v b="$AUTOBLOCK_BEGIN" -v e="$AUTOBLOCK_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

status() {
  local bash_state="missing"
  local zsh_state="missing"
  local conf_state="missing"

  [[ -f "$BASHRC_FILE" ]] && grep -qF "$AUTOBLOCK_BEGIN" "$BASHRC_FILE" && bash_state="managed"
  [[ -f "$ZSHRC_FILE" ]] && grep -qF "$AUTOBLOCK_BEGIN" "$ZSHRC_FILE" && zsh_state="managed"
  [[ -f "$TMUX_CONF_FILE" ]] && grep -qF "set -g mouse on" "$TMUX_CONF_FILE" && conf_state="configured"

  echo "session: $SESSION_NAME"
  echo "tmux: $(has_cmd tmux && echo installed || echo missing)"
  echo "bashrc: $bash_state ($BASHRC_FILE)"
  echo "zshrc: $zsh_state ($ZSHRC_FILE)"
  echo "tmux.conf: $conf_state ($TMUX_CONF_FILE)"
}

apply() {
  install_tmux
  write_tmux_conf
  update_shell_rc "$BASHRC_FILE"
  update_shell_rc "$ZSHRC_FILE"

  echo ""
  echo "done: tmux auto-attach configured"
  echo "- session: $SESSION_NAME"
  echo "- quick return command: tmux new-session -A -s $SESSION_NAME"
  echo "- optional alias: alias t='tmux new-session -A -s $SESSION_NAME'"
}

main() {
  local action="apply"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        SESSION_NAME="${2:-}"
        [[ -n "$SESSION_NAME" ]] || { echo "error: --session requires a value" >&2; exit 2; }
        shift 2
        ;;
      --apply)
        action="apply"
        shift
        ;;
      --remove)
        action="remove"
        shift
        ;;
      --status)
        action="status"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done

  case "$action" in
    apply) apply ;;
    remove)
      remove_shell_block "$BASHRC_FILE"
      remove_shell_block "$ZSHRC_FILE"
      echo "removed managed shell blocks from $BASHRC_FILE and $ZSHRC_FILE"
      ;;
    status) status ;;
  esac
}

main "$@"
