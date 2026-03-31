#!/usr/bin/env bash
# sshman.sh — SSH configuration manager
#
# Modes:
#   sshman.sh              interactive TUI
#   sshman.sh --apply      apply configured preset (from /etc/boot-scripts/sshman.conf)
#   sshman.sh --status     show current SSH config status
#   sshman.sh --keys       manage authorized keys (interactive)
#
# Config: /etc/boot-scripts/sshman.conf  (see config/sshman.conf.example)

set -euo pipefail

# ── Bootstrap lib ─────────────────────────────────────────────────────────────
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
  echo "fatal: cannot find lib/common.sh — run from boot.sh or set repo root" >&2
  exit 1
}

# ── Constants ─────────────────────────────────────────────────────────────────
NAME="sshman"
VERSION="v2.0.0"
LOG_PREFIX="[$NAME]"
SSH_CONFIG_DROPIN="${SSHD_CONFIG_DROPIN_DIR:-$(sshd_config_dropin_dir)}"
SSH_CONFIG_FILE="${SSH_CONFIG_TARGET:-$(sshd_config_target)}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/sshman-backups}"

# Default config values (overridden by /etc/boot-scripts/sshman.conf)
TARGET_USER="${TARGET_USER:-$(logname 2>/dev/null || echo $USER)}"
TARGET_HOME="${TARGET_HOME:-$(eval echo ~$TARGET_USER)}"
AUTO_INJECT_DEFAULT_PUBKEY="${AUTO_INJECT_DEFAULT_PUBKEY:-0}"
DEFAULT_PUBKEY="${DEFAULT_PUBKEY:-}"
HARDENED_YUBIKEYS="${HARDENED_YUBIKEYS:-}"
YUBI_CLIENT_ID="${YUBI_CLIENT_ID:-}"
YUBI_SECRET_KEY="${YUBI_SECRET_KEY:-}"

# ── Status formatters ─────────────────────────────────────────────────────────
fmt_yn() {
  if [[ "$1" =~ ^(yes|true|1)$ ]]; then
    echo -e "${C_GREEN}on${C_RESET}"
  else
    echo -e "${C_RED}off${C_RESET}"
  fi
}

fmt_root() {
  case "$1" in
    yes)           echo -e "${C_RED}allowed${C_RESET}" ;;
    prohibit-password) echo -e "${C_GREEN}key-only${C_RESET}" ;;
    no)            echo -e "${C_GREEN}denied${C_RESET}" ;;
    *)             echo -e "${C_YELLOW}$1${C_RESET}" ;;
  esac
}

fmt_yubikey() {
  local pam="/etc/pam.d/sshd"
  if [[ ! -f "$pam" ]]; then
    echo -e "${C_DIM}not configured${C_RESET}"
    return
  fi
  if grep -q 'pam_yubico.so' "$pam" 2>/dev/null; then
    if grep -q '^@include common-auth' "$pam" 2>/dev/null; then
      echo -e "${C_YELLOW}YubiKey + password (2FA)${C_RESET}"
    else
      echo -e "${C_GREEN}YubiKey only${C_RESET}"
    fi
  else
    echo -e "${C_DIM}disabled${C_RESET}"
  fi
}

# ── SSH config readers ────────────────────────────────────────────────────────
_get() {
  local key="$1"
  local default="${2:-}"
  local val
  val=$(grep -E "^[[:space:]]*${key}[[:space:]]" "$SSH_CONFIG_FILE" 2>/dev/null \
    | awk '{print $2}' | tail -1)
  echo "${val:-$default}"
}

_preset_label() {
  local r="$(_get PermitRootLogin)"
  local p="$(_get PasswordAuthentication)"
  local k="$(_get PubkeyAuthentication)"

  if   [[ "$r" == no ]] && [[ "$p" == no ]] && [[ "$k" == yes ]]; then
    echo -e "  ${C_GREEN}●${C_RESET} hardened-prod"
  elif [[ "$r" == prohibit-password ]] && [[ "$p" == yes ]] && [[ "$k" == yes ]]; then
    echo -e "  ${C_YELLOW}●${C_RESET} daily-dev"
  elif [[ "$r" == yes ]] && [[ "$p" == yes ]] && [[ "$k" == yes ]]; then
    echo -e "  ${C_RED}●${C_RESET} temp-open"
  else
    echo -e "  ${C_DIM}●${C_RESET} custom"
  fi
}

# ── Config writers ────────────────────────────────────────────────────────────
_ensure_dropin_header() {
  # Write a header to the drop-in /etc/ssh/sshd_config.d/99-boot-scripts.conf
  # if it's empty or doesn't exist yet
  if [[ ! -f "$SSH_CONFIG_FILE" ]] || [[ ! -s "$SSH_CONFIG_FILE" ]]; then
    cat > "$SSH_CONFIG_FILE" <<'HEADER'
# boot-scripts / sshman — managed by sshman.sh
# Manual edits to this file may be overwritten.
# To revert: remove this file and run: sudo systemctl restart ssh
HEADER
  fi
}

_update() {
  local key="$1"
  local val="$2"
  local file="$SSH_CONFIG_FILE"

  backup_file "$file"
  _ensure_dropin_header

  if grep -qE "^[[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null; then
    sed -i -e "s|^[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$file"
  else
    echo "${key} ${val}" >> "$file"
  fi
  info "set ${key} = ${val}"
}

_restart_ssh() {
  # Syntax check before restart — never restart with a broken config
  local svc
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    svc="ssh"
  else
    svc="sshd"
  fi

  info "checking sshd config syntax…"
  if ! sshd -t 2>/dev/null; then
    warn "sshd config syntax error — NOT restarting (you would lose SSH access!)"
    info "fix the config manually, then: sudo systemctl restart $svc"
    return 1
  fi

  info "restarting ssh service ($svc)…"
  if systemctl restart "$svc"; then
    ok "ssh service restarted"
  else
    warn "restart failed — you may need to reconnect manually"
    return 1
  fi
}

# ── Toggle helpers ────────────────────────────────────────────────────────────
_toggle() {
  local key="$1"
  local desc="$2"
  local current next
  current=$(_get "$key" "yes")
  [[ "$current" == yes ]] && next=no || next=yes
  _update "$key" "$next"
  echo -e "  ${desc}: $(fmt_yn "$next")"
  _restart_ssh
}

_cycle_root() {
  local current
  current=$(_get PermitRootLogin "yes")
  case "$current" in
    yes)                next=prohibit-password ;;
    prohibit-password)  next=no ;;
    no)                 next=yes ;;
    *)                  next=yes ;;
  esac
  _update PermitRootLogin "$next"
  echo -e "  Root login: $(fmt_root "$next")"
  _restart_ssh
}

# ── Key management ───────────────────────────────────────────────────────────
list_keys() {
  local count=0
  echo -e "\n  ${C_BOLD}Authorized keys${C_RESET} ($AUTHORIZED_KEYS)"
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      count=$((count + 1))
      local type comment
      type=$(echo "$line" | awk '{print $1}')
      comment=$(echo "$line" | awk '{print $NF}')
      echo -e "  ${C_CYAN}$count)${C_RESET} ${C_DIM}$type${C_RESET} $comment"
    done < "$AUTHORIZED_KEYS"
  fi
  if (( count == 0 )); then
    echo -e "  ${C_DIM}(none)${C_RESET}"
  fi
  echo ""
}

add_key() {
  echo ""
  echo -e "  ${C_BOLD}Add public key${C_RESET}"
  echo -e "  ${C_DIM}Paste the full line (ssh-ed25519 AAAA... comment)${C_RESET}"
  read -rp "  > " key
  [[ -z "$key" ]] && { warn "empty key, skipping"; return 1; }
  mkdir -p "$(dirname "$AUTHORIZED_KEYS")"
  chmod 700 "$(dirname "$AUTHORIZED_KEYS")"
  echo "$key" >> "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
  ok "key added"
}

remove_key() {
  list_keys
  (( $(wc -l < "$AUTHORIZED_KEYS" 2>/dev/null || echo 0) == 0 )) && return
  read -rp "  delete key number (or 0 to cancel): " num
  [[ "$num" == 0 || -z "$num" ]] && return
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    sed -i "${num}d" "$AUTHORIZED_KEYS" 2>/dev/null \
      && ok "key deleted" \
      || fail "delete failed"
  else
    warn "invalid number"
  fi
}

# ── Auto-inject pubkey ─────────────────────────────────────────────────────────
auto_inject_pubkey() {
  [[ "$AUTO_INJECT_DEFAULT_PUBKEY" != "1" ]] && return 0
  [[ -z "$DEFAULT_PUBKEY" ]] && { warn "AUTO_INJECT=1 but DEFAULT_PUBKEY is empty"; return 0; }

  local dir
  dir=$(dirname "$AUTHORIZED_KEYS")
  mkdir -p "$dir"
  chmod 700 "$dir"

  if [[ -f "$AUTHORIZED_KEYS" ]] && grep -qF "$DEFAULT_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
    info "default pubkey already present, skipping injection"
    return 0
  fi

  echo "$DEFAULT_PUBKEY" >> "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
  ok "default pubkey injected to $AUTHORIZED_KEYS"
}

# ── Presets ───────────────────────────────────────────────────────────────────
apply_preset() {
  local preset="${1:-}"
  case "$preset" in
    hardened-prod)
      info "applying preset: hardened-prod"
      _update PermitRootLogin no
      _update PasswordAuthentication no
      _update PubkeyAuthentication yes
      _restart_ssh
      ;;
    daily-dev)
      info "applying preset: daily-dev"
      _update PermitRootLogin prohibit-password
      _update PasswordAuthentication yes
      _update PubkeyAuthentication yes
      _restart_ssh
      ;;
    temp-open)
      warn "applying preset: temp-open (INSECURE — password + root allowed)"
      _update PermitRootLogin yes
      _update PasswordAuthentication yes
      _update PubkeyAuthentication yes
      _restart_ssh
      ;;
    *)
      fail "unknown preset: $preset"
      return 1
      ;;
  esac
}

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
  local r p k yk
  r=$(_get PermitRootLogin "yes")
  p=$(_get PasswordAuthentication "yes")
  k=$(_get PubkeyAuthentication "yes")
  yk=$(fmt_yubikey)

  section "sshman — current SSH config"
  box_row "PasswordAuth"    "$(fmt_yn "$p")"
  box_row "PubkeyAuth"      "$(fmt_yn "$k")"
  box_row "RootLogin"       "$(fmt_root "$r")"
  box_row "YubiKey"         "$yk"
  echo -e "${C_BOLD}${C_CYAN}├${HLINE}┤${C_RESET}"
  box_row "Config file"     "$SSH_CONFIG_FILE"
  box_row "Preset"          "$(_preset_label)"
  box_row "Authorized keys" "$([[ -f "$AUTHORIZED_KEYS" ]] && wc -l < "$AUTHORIZED_KEYS" || echo 0) keys"
  section_end
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  need_root

  # Load config if present
  local sys_conf="/etc/boot-scripts/sshman.conf"
  local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/boot-scripts/sshman.conf"
  for conf in "$sys_conf" "$user_conf"; do
    [[ -f "$conf" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]] || continue
      eval "$line" 2>/dev/null || true
    done < "$conf"
  done

  # Auto-inject pubkey on every run (idempotent)
  auto_inject_pubkey

  case "${1:-}" in
    --apply)
      local preset="${2:-}"
      [[ -z "$preset" ]] && { fail "usage: sshman.sh --apply <preset>"; exit 2; }
      apply_preset "$preset"
      ;;

    --status)
      show_status
      ;;

    --keys)
      list_keys
      echo -e "  ${C_CYAN}a)${C_RESET} add key    ${C_CYAN}d)${C_RESET} delete key    ${C_CYAN}q)${C_RESET} quit"
      read -rp "  choice: " c
      case "$c" in
        a) add_key ;;
        d) remove_key ;;
      esac
      ;;

    --interactive|-i|"")
      while true; do
        show_status
        echo -e "  ${C_CYAN}1)${C_RESET} toggle password auth"
        echo -e "  ${C_CYAN}2)${C_RESET} toggle pubkey auth"
        echo -e "  ${C_CYAN}3)${C_RESET} cycle root login"
        echo -e "  ${C_CYAN}4)${C_RESET} manage authorized keys"
        echo -e "  ${C_CYAN}5)${C_RESET} apply preset"
        echo -e "  ${C_CYAN}0)${C_RESET} quit"
        echo ""
        read -rp "  select: " choice
        case "$choice" in
          1) _toggle PasswordAuthentication "PasswordAuth" ;;
          2) _toggle PubkeyAuthentication "PubkeyAuth" ;;
          3) _cycle_root ;;
          4) list_keys; echo -e "  ${C_CYAN}a)${C_RESET} add  ${C_CYAN}d)${C_RESET} delete  ${C_CYAN}q)${C_RESET} quit"; read -rp "  > " kc; case "$kc" in a) add_key ;; d) remove_key ;; esac ;;
          5)
            echo -e "  ${C_CYAN}1)${C_RESET} hardened-prod  ${C_CYAN}2)${C_RESET} daily-dev  ${C_CYAN}3)${C_RESET} temp-open"
            read -rp "  preset [1]: " pc; pc="${pc:-1}"; case "$pc" in 1) apply_preset hardened-prod ;; 2) apply_preset daily-dev ;; 3) apply_preset temp-open ;; esac
            ;;
          0) echo "goodbye"; exit 0 ;;
          *) warn "invalid choice" ;;
        esac
        echo ""
        read -rp "press enter to refresh…"
      done
      ;;

    -h|--help)
      echo "sshman $VERSION — SSH configuration manager"
      echo ""
      echo "Usage:"
      echo "  sshman.sh               interactive TUI"
      echo "  sshman.sh --status       show current config"
      echo "  sshman.sh --keys         manage authorized keys"
      echo "  sshman.sh --apply <preset>   apply preset and exit"
      echo ""
      echo "Presets: hardened-prod | daily-dev | temp-open"
      echo "Config:  /etc/boot-scripts/sshman.conf"
      ;;
  esac
}

main "$@"
