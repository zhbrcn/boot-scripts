#!/usr/bin/env bash
# sshman.sh - SSH configuration manager
#
# Modes:
#   sshman.sh                interactive TUI
#   sshman.sh --apply NAME   apply preset
#   sshman.sh --status       show current SSH config
#   sshman.sh --keys         manage authorized_keys
#   sshman.sh --yubikey CMD  manage YubiKey OTP integration

set -euo pipefail

_src="${BASH_SOURCE[0]}"
_dir="$(cd "$(dirname "$_src")" && pwd)"
while [[ "$_dir" != "/" ]]; do
  if [[ -f "$_dir/lib/common.sh" ]]; then
    # shellcheck disable=SC1090
    source "$_dir/lib/common.sh"
    # shellcheck disable=SC1090
    source "$_dir/lib/ui.sh"
    LIB_LOADED=1
    break
  fi
  _dir="$(dirname "$_dir")"
done
[[ "${LIB_LOADED:-}" ]] || {
  echo "fatal: cannot find lib/common.sh - run from boot.sh or repo root" >&2
  exit 1
}

NAME="sshman"
VERSION="v2.1.0"
LOG_PREFIX="[$NAME]"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/sshman-backups}"

PAM_SSHD_FILE="/etc/pam.d/sshd"
YUBIKEY_AUTHFILE_DEFAULT="/etc/ssh/authorized_yubikeys"
YUBIKEY_PAM_BEGIN="# boot-scripts yubikey begin"
YUBIKEY_PAM_END="# boot-scripts yubikey end"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/boot-scripts-sshd.local"
BUILTIN_YUBI_CLIENT_ID="85975"
BUILTIN_YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="
BUILTIN_HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"

TARGET_USER="${TARGET_USER:-}"
TARGET_HOME="${TARGET_HOME:-}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-}"
SSH_CONFIG_FILE="${SSH_CONFIG_TARGET:-}"

AUTO_INJECT_DEFAULT_PUBKEY="${AUTO_INJECT_DEFAULT_PUBKEY:-0}"
DEFAULT_PUBKEY="${DEFAULT_PUBKEY:-}"

HARDENED_YUBIKEYS="${HARDENED_YUBIKEYS:-}"
YUBI_CLIENT_ID="${YUBI_CLIENT_ID:-}"
YUBI_SECRET_KEY="${YUBI_SECRET_KEY:-}"
YUBIKEY_AUTHFILE="${YUBIKEY_AUTHFILE:-$YUBIKEY_AUTHFILE_DEFAULT}"

declare -A BACKED_UP_FILES=()

fmt_yn() {
  if [[ "$1" =~ ^(yes|true|1)$ ]]; then
    echo -e "${C_GREEN}on${C_RESET}"
  else
    echo -e "${C_RED}off${C_RESET}"
  fi
}

fmt_root() {
  case "$1" in
    yes) echo -e "${C_RED}allowed${C_RESET}" ;;
    prohibit-password) echo -e "${C_GREEN}key-only${C_RESET}" ;;
    no) echo -e "${C_GREEN}denied${C_RESET}" ;;
    *) echo -e "${C_YELLOW}$1${C_RESET}" ;;
  esac
}

resolve_target_home() {
  local user_name="$1"
  local home_dir=""

  if has_cmd getent; then
    home_dir="$(getent passwd "$user_name" 2>/dev/null | awk -F: '{print $6}')"
  fi
  [[ -n "$home_dir" ]] || home_dir="$(eval echo "~$user_name" 2>/dev/null || true)"
  echo "$home_dir"
}

refresh_runtime_config() {
  [[ -n "$TARGET_USER" ]] || TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-root}")}"
  [[ -n "$TARGET_HOME" ]] || TARGET_HOME="$(resolve_target_home "$TARGET_USER")"
  [[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"

  [[ -n "$AUTHORIZED_KEYS" ]] || AUTHORIZED_KEYS="$TARGET_HOME/.ssh/authorized_keys"
  [[ -n "$SSH_CONFIG_FILE" ]] || SSH_CONFIG_FILE="$(sshd_config_target)"
  [[ -n "$YUBIKEY_AUTHFILE" ]] || YUBIKEY_AUTHFILE="$YUBIKEY_AUTHFILE_DEFAULT"
  [[ -n "$YUBI_CLIENT_ID" ]] || YUBI_CLIENT_ID="$BUILTIN_YUBI_CLIENT_ID"
  [[ -n "$YUBI_SECRET_KEY" ]] || YUBI_SECRET_KEY="$BUILTIN_YUBI_SECRET_KEY"
  [[ -n "$HARDENED_YUBIKEYS" ]] || HARDENED_YUBIKEYS="$BUILTIN_HARDENED_YUBIKEYS"
}

load_config_files() {
  local sys_conf="/etc/boot-scripts/sshman.conf"
  local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/boot-scripts/sshman.conf"
  local repo_conf="$_dir/config/sshman.conf.local"
  local conf

  for conf in "$sys_conf" "$user_conf" "$repo_conf"; do
    [[ -f "$conf" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]] || continue
      eval "$line" 2>/dev/null || true
    done < "$conf"
  done
}

backup_once() {
  local file="$1"

  [[ -f "$file" ]] || return 0
  [[ -n "${BACKED_UP_FILES[$file]:-}" ]] && return 0
  backup_file "$file"
  BACKED_UP_FILES["$file"]=1
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

apply_directives() {
  local entry key value

  for entry in "$@"; do
    key="${entry%% *}"
    value="${entry#* }"
    _update "$key" "$value"
  done
}

refresh_screen() {
  if has_cmd clear; then
    clear
  fi
}

yubikey_dependency_status() {
  if has_cmd dpkg-query && dpkg-query -W -f='${Status}' libpam-yubico 2>/dev/null | grep -q "install ok installed"; then
    echo -e "${C_GREEN}libpam-yubico installed${C_RESET}"
  elif has_cmd rpm && rpm -q pam_yubico >/dev/null 2>&1; then
    echo -e "${C_GREEN}pam_yubico installed${C_RESET}"
  else
    echo -e "${C_YELLOW}missing${C_RESET}"
  fi
}

fail2ban_dependency_status() {
  if has_cmd dpkg-query && dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q "install ok installed"; then
    echo -e "${C_GREEN}fail2ban installed${C_RESET}"
  else
    echo -e "${C_YELLOW}missing${C_RESET}"
  fi
}

fail2ban_service_enabled() {
  systemctl is-active --quiet fail2ban 2>/dev/null
}

fail2ban_status_text() {
  if fail2ban_service_enabled; then
    echo -e "${C_GREEN}enabled${C_RESET}"
  elif [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    echo -e "${C_YELLOW}configured, service down${C_RESET}"
  else
    echo -e "${C_DIM}disabled${C_RESET}"
  fi
}

install_yubikey_dependencies() {
  if detect_pam_yubico_module >/dev/null 2>&1; then
    return 0
  fi

  if has_cmd apt-get; then
    info "pam_yubico missing, installing dependencies..."
    apt-get update -y
    apt-get upgrade -y
    apt-get install libpam-yubico -y
  else
    fail "pam_yubico.so not found and no supported package manager was detected"
    return 1
  fi

  detect_pam_yubico_module >/dev/null 2>&1 || {
    fail "pam_yubico.so still not found after install"
    return 1
  }
}

install_fail2ban_dependencies() {
  if has_cmd fail2ban-client; then
    return 0
  fi

  if has_cmd apt-get; then
    info "fail2ban missing, installing..."
    apt-get update -y
    apt-get install fail2ban -y
  else
    fail "fail2ban not found and no supported package manager was detected"
    return 1
  fi

  has_cmd fail2ban-client || {
    fail "fail2ban still not found after install"
    return 1
  }
}

count_real_keys() {
  local count=0
  local line

  [[ -f "$AUTHORIZED_KEYS" ]] || {
    echo 0
    return
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    count=$((count + 1))
  done < "$AUTHORIZED_KEYS"

  echo "$count"
}

count_yubikey_pubkeys() {
  local count=0
  local line

  [[ -f "$AUTHORIZED_KEYS" ]] || {
    echo 0
    return
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^(sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]] ]] || continue
    count=$((count + 1))
  done < "$AUTHORIZED_KEYS"

  echo "$count"
}

config_get() {
  local key="$1"
  local default="${2:-}"
  local val

  val="$(
    grep -E "^[[:space:]]*${key}[[:space:]]" "$SSH_CONFIG_FILE" 2>/dev/null \
      | awk '{print $2}' \
      | tail -1
  )"

  echo "${val:-$default}"
}

keyboard_auth_value() {
  config_get KbdInteractiveAuthentication "$(config_get ChallengeResponseAuthentication "no")"
}

auth_methods_value() {
  config_get AuthenticationMethods "default"
}

legacy_yubikey_auth_state() {
  [[ "$(auth_methods_value)" == "publickey,keyboard-interactive:pam" ]]
}

yubikey_otp_only_state() {
  [[ "$(auth_methods_value)" == "keyboard-interactive:pam" ]] && [[ "$(config_get PubkeyAuthentication "yes")" == "no" ]]
}

_remove_directive() {
  local key="$1"
  local file="$SSH_CONFIG_FILE"

  [[ -f "$file" ]] || return 0
  backup_once "$file"
  sed -i -e "/^[[:space:]]*${key}[[:space:]]/d" "$file"
}

_ensure_dropin_header() {
  ensure_parent_dir "$SSH_CONFIG_FILE"
  if [[ ! -f "$SSH_CONFIG_FILE" ]] || [[ ! -s "$SSH_CONFIG_FILE" ]]; then
    cat > "$SSH_CONFIG_FILE" <<'EOF'
# boot-scripts / sshman - managed by sshman.sh
# Manual edits to this file may be overwritten.
# To revert: remove this file and restart sshd.
EOF
  fi
}

_update() {
  local key="$1"
  local val="$2"
  local file="$SSH_CONFIG_FILE"

  _ensure_dropin_header
  backup_once "$file"

  if grep -qE "^[[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null; then
    sed -i -e "s|^[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$file"
  else
    printf '%s %s\n' "$key" "$val" >> "$file"
  fi
  info "set ${key} = ${val}"
}

_restart_ssh() {
  local svc
  svc="$(ssh_service_name)"

  info "checking sshd config syntax..."
  if ! sshd -t 2>/dev/null; then
    warn "sshd config syntax error - not restarting"
    info "fix the config manually, then run: sudo systemctl restart $svc"
    return 1
  fi

  info "restarting ssh service ($svc)..."
  if systemctl restart "$svc"; then
    ok "ssh service restarted"
  else
    warn "restart failed - reconnect may be required"
    return 1
  fi
}

validate_pubkey() {
  local key="$1"
  local pubkey_re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$'
  [[ "$key" =~ $pubkey_re ]]
}

list_keys() {
  local count=0
  local line
  local file_line=0

  echo -e "\n  ${C_BOLD}Authorized keys${C_RESET} ($AUTHORIZED_KEYS)"
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      file_line=$((file_line + 1))
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      count=$((count + 1))
      echo -e "  ${C_CYAN}$count)${C_RESET} ${C_DIM}$(echo "$line" | awk '{print $1}')${C_RESET} $(echo "$line" | awk '{print $NF}')"
    done < "$AUTHORIZED_KEYS"
  fi
  (( count > 0 )) || echo -e "  ${C_DIM}(none)${C_RESET}"
  echo ""
}

add_key() {
  local key

  echo ""
  echo -e "  ${C_BOLD}Add public key${C_RESET}"
  echo -e "  ${C_DIM}Supported: ssh-ed25519, ecdsa, rsa, sk-ssh-ed25519, sk-ecdsa...${C_RESET}"
  read -rp "  > " key

  [[ -n "$key" ]] || {
    warn "empty key, skipping"
    return 1
  }
  validate_pubkey "$key" || {
    fail "key format looks invalid"
    return 1
  }

  ensure_parent_dir "$AUTHORIZED_KEYS"
  touch "$AUTHORIZED_KEYS"
  chmod 700 "$(dirname "$AUTHORIZED_KEYS")"

  if grep -qF "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
    info "key already present, skipping"
    return 0
  fi

  printf '%s\n' "$key" >> "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
  ok "key added"
}

remove_key() {
  local display_num
  local count=0
  local file_line=0
  local target_line=0
  local line

  [[ -f "$AUTHORIZED_KEYS" ]] || {
    warn "authorized_keys does not exist"
    return 0
  }

  list_keys
  (( "$(count_real_keys)" > 0 )) || return 0

  read -rp "  delete key number (or 0 to cancel): " display_num
  [[ -z "$display_num" || "$display_num" == "0" ]] && return 0
  [[ "$display_num" =~ ^[0-9]+$ ]] || {
    warn "invalid number"
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    file_line=$((file_line + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    count=$((count + 1))
    if [[ "$count" == "$display_num" ]]; then
      target_line="$file_line"
      break
    fi
  done < "$AUTHORIZED_KEYS"

  (( target_line > 0 )) || {
    warn "key number out of range"
    return 1
  }

  backup_once "$AUTHORIZED_KEYS"
  sed -i "${target_line}d" "$AUTHORIZED_KEYS"
  ok "key deleted"
}

auto_inject_pubkey() {
  [[ "$AUTO_INJECT_DEFAULT_PUBKEY" == "1" ]] || return 0
  [[ -n "$DEFAULT_PUBKEY" ]] || {
    warn "AUTO_INJECT_DEFAULT_PUBKEY=1 but DEFAULT_PUBKEY is empty"
    return 0
  }

  validate_pubkey "$DEFAULT_PUBKEY" || {
    warn "DEFAULT_PUBKEY format is invalid, skipping auto-inject"
    return 0
  }

  ensure_parent_dir "$AUTHORIZED_KEYS"
  mkdir -p "$(dirname "$AUTHORIZED_KEYS")"
  chmod 700 "$(dirname "$AUTHORIZED_KEYS")"

  if [[ -f "$AUTHORIZED_KEYS" ]] && grep -qF "$DEFAULT_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
    info "default pubkey already present"
    return 0
  fi

  printf '%s\n' "$DEFAULT_PUBKEY" >> "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
  ok "default pubkey injected to $AUTHORIZED_KEYS"
}

_preset_label() {
  local root_login password_auth pubkey_auth
  root_login="$(config_get PermitRootLogin "yes")"
  password_auth="$(config_get PasswordAuthentication "yes")"
  pubkey_auth="$(config_get PubkeyAuthentication "yes")"

  if yubikey_enabled; then
    echo -e "${C_GREEN}yubikey-only${C_RESET}"
  elif [[ "$root_login" == "yes" && "$password_auth" == "yes" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_RED}root-password${C_RESET}"
  elif [[ "$root_login" == "no" && "$password_auth" == "no" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_GREEN}key-only${C_RESET}"
  elif [[ "$root_login" == "prohibit-password" && "$password_auth" == "yes" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_YELLOW}daily-admin${C_RESET}"
  else
    echo -e "${C_DIM}custom${C_RESET}"
  fi
}

current_login_mode_label() {
  local root_login password_auth pubkey_auth kbd_auth

  root_login="$(config_get PermitRootLogin "yes")"
  password_auth="$(config_get PasswordAuthentication "yes")"
  pubkey_auth="$(config_get PubkeyAuthentication "yes")"
  kbd_auth="$(keyboard_auth_value)"

  if yubikey_otp_only_state && yubikey_enabled; then
    echo -e "${C_GREEN}YubiKey OTP only${C_RESET}"
  elif yubikey_enabled; then
    echo -e "${C_YELLOW}YubiKey mixed${C_RESET}"
  elif [[ "$root_login" == "yes" && "$password_auth" == "yes" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_RED}Root password${C_RESET}"
  elif [[ "$root_login" == "no" && "$password_auth" == "no" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_GREEN}Key only${C_RESET}"
  elif [[ "$root_login" == "prohibit-password" && "$password_auth" == "yes" && "$pubkey_auth" == "yes" ]]; then
    echo -e "${C_YELLOW}Daily admin${C_RESET}"
  elif [[ "$password_auth" == "yes" && "$pubkey_auth" == "no" ]]; then
    echo -e "${C_YELLOW}Password only${C_RESET}"
  elif [[ "$password_auth" == "no" && "$pubkey_auth" == "yes" && "$kbd_auth" == "yes" ]]; then
    echo -e "${C_YELLOW}Mixed auth${C_RESET}"
  else
    echo -e "${C_DIM}Custom${C_RESET}"
  fi
}

root_access_summary() {
  local root_login
  root_login="$(config_get PermitRootLogin "yes")"

  case "$root_login" in
    yes) echo -e "${C_RED}Allowed${C_RESET}" ;;
    prohibit-password) echo -e "${C_YELLOW}Key only${C_RESET}" ;;
    no) echo -e "${C_GREEN}Denied${C_RESET}" ;;
    *) echo -e "${C_DIM}${root_login}${C_RESET}" ;;
  esac
}

login_method_summary() {
  local password_auth pubkey_auth auth_methods

  password_auth="$(config_get PasswordAuthentication "yes")"
  pubkey_auth="$(config_get PubkeyAuthentication "yes")"
  auth_methods="$(auth_methods_value)"

  if yubikey_otp_only_state && yubikey_enabled; then
    echo -e "${C_GREEN}YubiKey HOTP only${C_RESET}"
  elif yubikey_enabled; then
    echo -e "${C_YELLOW}YubiKey HOTP + extra path${C_RESET}"
  elif [[ "$auth_methods" == "publickey,keyboard-interactive:pam" ]]; then
    echo -e "${C_YELLOW}Public key + OTP${C_RESET}"
  elif [[ "$password_auth" == "yes" && "$pubkey_auth" == "yes" ]]; then
    echo "Password or public key"
  elif [[ "$password_auth" == "yes" ]]; then
    echo "Password only"
  elif [[ "$pubkey_auth" == "yes" ]]; then
    echo "Public key only"
  else
    echo -e "${C_RED}No normal login enabled${C_RESET}"
  fi
}

key_inventory_summary() {
  local key_count sk_count

  key_count="$(count_real_keys)"
  sk_count="$(count_yubikey_pubkeys)"

  if (( key_count == 0 )); then
    echo -e "${C_YELLOW}None configured${C_RESET}"
  elif (( sk_count > 0 )); then
    echo "${key_count} total, ${sk_count} security key"
  else
    echo "${key_count} configured"
  fi
}

auth_methods_summary() {
  local auth_methods

  auth_methods="$(auth_methods_value)"
  if [[ "$auth_methods" == "keyboard-interactive:pam" ]]; then
    echo -e "${C_GREEN}OTP only${C_RESET}"
  elif [[ "$auth_methods" == "publickey,keyboard-interactive:pam" ]]; then
    echo -e "${C_YELLOW}public key + OTP${C_RESET}"
  else
    echo "$auth_methods"
  fi
}

password_summary() {
  local password_auth
  password_auth="$(config_get PasswordAuthentication "yes")"
  [[ "$password_auth" == "yes" ]] && echo "Enabled" || echo "Disabled"
}

pubkey_summary() {
  local pubkey_auth
  pubkey_auth="$(config_get PubkeyAuthentication "yes")"
  [[ "$pubkey_auth" == "yes" ]] && echo "Enabled" || echo "Disabled"
}

keyboard_summary() {
  local kbd_auth
  kbd_auth="$(keyboard_auth_value)"
  [[ "$kbd_auth" == "yes" ]] && echo "Enabled" || echo "Disabled"
}

preset_summary() {
  local preset
  preset="$(_preset_label)"
  echo -e "$preset"
}

show_main_actions() {
  echo -e "  ${C_BOLD}Main actions${C_RESET}"
  echo -e "  ${C_CYAN}1)${C_RESET} apply login mode"
  echo -e "  ${C_CYAN}2)${C_RESET} manage authorized keys"
  echo -e "  ${C_CYAN}3)${C_RESET} manage YubiKey HOTP"
  echo -e "  ${C_CYAN}4)${C_RESET} manage fail2ban"
  echo -e "  ${C_CYAN}5)${C_RESET} manual adjustments"
  echo -e "  ${C_CYAN}0)${C_RESET} back"
}

yubikey_enabled() {
  [[ -f "$PAM_SSHD_FILE" ]] || return 1
  grep -qF "$YUBIKEY_PAM_BEGIN" "$PAM_SSHD_FILE" 2>/dev/null
}

detect_pam_yubico_module() {
  local candidate
  local candidates=(
    "/lib/security/pam_yubico.so"
    "/lib64/security/pam_yubico.so"
    "/usr/lib/security/pam_yubico.so"
    "/usr/lib64/security/pam_yubico.so"
    "/usr/lib/x86_64-linux-gnu/security/pam_yubico.so"
  )

  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] && {
      echo "$candidate"
      return 0
    }
  done

  return 1
}

yubikey_status_text() {
  local security_key_count
  security_key_count="$(count_yubikey_pubkeys)"

  if yubikey_enabled; then
    if (( security_key_count > 0 )); then
      echo -e "${C_GREEN}OTP enabled + ${security_key_count} hardware-backed key(s)${C_RESET}"
    else
      echo -e "${C_YELLOW}OTP enabled${C_RESET}"
    fi
  elif (( security_key_count > 0 )); then
    echo -e "${C_GREEN}${security_key_count} hardware-backed key(s) only${C_RESET}"
  else
    echo -e "${C_DIM}disabled${C_RESET}"
  fi
}

enable_yubikey_ssh_mode() {
  apply_directives \
    "PermitRootLogin yes" \
    "PasswordAuthentication no" \
    "PubkeyAuthentication no" \
    "KbdInteractiveAuthentication yes" \
    "ChallengeResponseAuthentication yes" \
    "UsePAM yes" \
    "AuthenticationMethods keyboard-interactive:pam"
}

write_fail2ban_jail() {
  ensure_parent_dir "$FAIL2BAN_JAIL_FILE"
  cat > "$FAIL2BAN_JAIL_FILE" <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  ok "wrote $FAIL2BAN_JAIL_FILE"
}

enable_fail2ban_guard() {
  install_fail2ban_dependencies
  write_fail2ban_jail
  systemctl enable --now fail2ban >/dev/null 2>&1 || {
    fail "failed to enable fail2ban"
    return 1
  }
  systemctl restart fail2ban >/dev/null 2>&1 || {
    fail "failed to restart fail2ban"
    return 1
  }
  ok "fail2ban enabled for ssh"
}

disable_fail2ban_guard() {
  [[ -f "$FAIL2BAN_JAIL_FILE" ]] && rm -f "$FAIL2BAN_JAIL_FILE"
  if systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; then
    systemctl restart fail2ban >/dev/null 2>&1 || systemctl stop fail2ban >/dev/null 2>&1 || true
  fi
  ok "fail2ban ssh jail removed"
}

apply_safe_otp_only_recovery() {
  enable_yubikey_ssh_mode
  _restart_ssh
}

show_yubikey_fix_hint() {
  if yubikey_enabled && legacy_yubikey_auth_state; then
    warn "legacy publickey + otp state detected"
    warn "use 'recover to HOTP-only now' to normalize it"
  fi
}

write_managed_pam_block() {
  local tmp_file
  tmp_file="$(mktemp)"

  if yubikey_enabled; then
    awk -v begin="$YUBIKEY_PAM_BEGIN" -v end="$YUBIKEY_PAM_END" -v id="$YUBI_CLIENT_ID" -v key="$YUBI_SECRET_KEY" -v authfile="$YUBIKEY_AUTHFILE" '
      BEGIN {
        in_block = 0
      }
      $0 == begin {
        print begin
        print "auth [success=done default=die] pam_yubico.so id=" id " key=" key " authfile=" authfile
        print end
        in_block = 1
        next
      }
      $0 == end {
        in_block = 0
        next
      }
      !in_block { print }
    ' "$PAM_SSHD_FILE" > "$tmp_file"
  else
    {
      printf '%s\n' "$YUBIKEY_PAM_BEGIN"
      printf 'auth [success=done default=die] pam_yubico.so id=%s key=%s authfile=%s\n' "$YUBI_CLIENT_ID" "$YUBI_SECRET_KEY" "$YUBIKEY_AUTHFILE"
      printf '%s\n' "$YUBIKEY_PAM_END"
      cat "$PAM_SSHD_FILE"
    } > "$tmp_file"
  fi

  cat "$tmp_file" > "$PAM_SSHD_FILE"
  rm -f "$tmp_file"
}

remove_managed_pam_block() {
  local tmp_file

  [[ -f "$PAM_SSHD_FILE" ]] || return 0
  yubikey_enabled || return 0

  tmp_file="$(mktemp)"
  awk -v begin="$YUBIKEY_PAM_BEGIN" -v end="$YUBIKEY_PAM_END" '
    BEGIN { in_block = 0 }
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$PAM_SSHD_FILE" > "$tmp_file"
  cat "$tmp_file" > "$PAM_SSHD_FILE"
  rm -f "$tmp_file"
}

write_yubikey_authfile() {
  [[ -n "$HARDENED_YUBIKEYS" ]] || {
    fail "HARDENED_YUBIKEYS is empty"
    return 1
  }

  ensure_parent_dir "$YUBIKEY_AUTHFILE"
  mkdir -p "$(dirname "$YUBIKEY_AUTHFILE")"
  printf '%s\n' "$HARDENED_YUBIKEYS" > "$YUBIKEY_AUTHFILE"
  chmod 600 "$YUBIKEY_AUTHFILE"
  ok "wrote $YUBIKEY_AUTHFILE"
}

show_yubikey_tokens() {
  local mapping="${HARDENED_YUBIKEYS:-$BUILTIN_HARDENED_YUBIKEYS}"
  local user_name
  local token_list
  local token
  local idx=1

  user_name="${mapping%%:*}"
  token_list="${mapping#*:}"
  echo ""
  echo -e "  ${C_BOLD}Current YubiKey OTP mapping${C_RESET}"
  echo -e "  ${C_DIM}user:${C_RESET} $user_name"
  IFS=':' read -r -a _tokens <<< "$token_list"
  for token in "${_tokens[@]}"; do
    [[ -n "$token" ]] || continue
    echo -e "  ${C_CYAN}$idx)${C_RESET} $token"
    idx=$((idx + 1))
  done
  echo ""
}

add_manual_yubikey_token() {
  local mapping="${HARDENED_YUBIKEYS:-$BUILTIN_HARDENED_YUBIKEYS}"
  local user_name
  local token

  user_name="${mapping%%:*}"
  [[ -n "$user_name" && "$user_name" != "$mapping" ]] || user_name="$TARGET_USER"

  echo ""
  echo -e "  ${C_BOLD}Add YubiKey OTP token${C_RESET}"
  echo -e "  ${C_DIM}Current target user: $user_name${C_RESET}"
  read -rp "  token (e.g. cccccbenueru): " token

  [[ -n "$token" ]] || {
    warn "empty token, skipping"
    return 1
  }
  [[ "$token" =~ ^[cbdefghijklnrtuv]{12,64}$ ]] || {
    fail "token format looks invalid"
    return 1
  }

  if [[ "$mapping" == "$user_name" ]]; then
    mapping="$user_name:$token"
  else
    case ":$mapping:" in
      *":$token:"*)
        info "token already present"
        return 0
        ;;
      *)
        mapping="${mapping}:$token"
        ;;
    esac
  fi

  HARDENED_YUBIKEYS="$mapping"
  ok "token added"
  show_yubikey_tokens
}

enable_yubikey() {
  install_yubikey_dependencies
  [[ -n "$YUBI_CLIENT_ID" ]] || {
    fail "YUBI_CLIENT_ID is empty"
    return 1
  }
  [[ -n "$YUBI_SECRET_KEY" ]] || {
    fail "YUBI_SECRET_KEY is empty"
    return 1
  }

  backup_once "$PAM_SSHD_FILE"
  write_yubikey_authfile
  write_managed_pam_block
  enable_yubikey_ssh_mode
  _restart_ssh
}

disable_yubikey() {
  backup_once "$PAM_SSHD_FILE"
  remove_managed_pam_block

  _remove_directive AuthenticationMethods
  _remove_directive KbdInteractiveAuthentication
  _remove_directive ChallengeResponseAuthentication

  _restart_ssh
}

cleanup_yubikey_state() {
  backup_once "$PAM_SSHD_FILE"
  remove_managed_pam_block
  _remove_directive AuthenticationMethods
  _remove_directive KbdInteractiveAuthentication
  _remove_directive ChallengeResponseAuthentication
}

apply_standard_auth_mode() {
  local root_login="$1"
  local password_auth="$2"
  local pubkey_auth="$3"
  local keyboard_int="${4:-no}"

  cleanup_yubikey_state
  apply_directives \
    "PermitRootLogin $root_login" \
    "PasswordAuthentication $password_auth" \
    "PubkeyAuthentication $pubkey_auth" \
    "KbdInteractiveAuthentication $keyboard_int" \
    "ChallengeResponseAuthentication $keyboard_int" \
    "UsePAM yes"
  _restart_ssh
}

show_yubikey_help() {
  section "YubiKey notes"
  box_row "Login mode" "HOTP only"
  box_row "Password" "disabled"
  box_row "Public key" "disabled in OTP-only mode"
  box_row "Client keygen" "ssh-keygen -t ed25519-sk -O resident -C you@host"
  box_row "Config vars" "YUBI_CLIENT_ID / YUBI_SECRET_KEY / HARDENED_YUBIKEYS"
  box_row "Auth file" "$YUBIKEY_AUTHFILE"
  box_row "Built-in IDs" "$BUILTIN_HARDENED_YUBIKEYS"
  box_row "Install deps" "sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get install libpam-yubico -y"
  section_end
}

manage_yubikey_interactive() {
  local choice

  while true; do
    refresh_screen
    show_status
    show_yubikey_fix_hint
    echo -e "  ${C_BOLD}YubiKey HOTP${C_RESET}"
    box_row "Built-in tokens" "cccccbenueru / cccccbejiijg"
    box_row "Auth file" "$YUBIKEY_AUTHFILE"
    echo ""
    echo -e "  ${C_CYAN}1)${C_RESET} enable built-in OTP-only login"
    echo -e "  ${C_CYAN}2)${C_RESET} view current YubiKey tokens"
    echo -e "  ${C_CYAN}3)${C_RESET} add YubiKey token"
    echo -e "  ${C_CYAN}4)${C_RESET} disable YubiKey login"
    echo -e "  ${C_CYAN}5)${C_RESET} repair direct-login mode"
    echo -e "  ${C_CYAN}6)${C_RESET} show setup notes"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) enable_yubikey ;;
      2) show_yubikey_tokens ;;
      3) add_manual_yubikey_token ;;
      4) disable_yubikey ;;
      5) apply_safe_otp_only_recovery ;;
      6) show_yubikey_help ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

manage_keys_interactive() {
  local choice

  while true; do
    refresh_screen
    show_status
    list_keys
    echo -e "  ${C_BOLD}Authorized keys${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} add key"
    echo -e "  ${C_CYAN}2)${C_RESET} delete key"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) add_key ;;
      2) remove_key ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

quick_modes_menu() {
  local choice

  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Login modes${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} YubiKey OTP only ${C_DIM}root logs in with HOTP only${C_RESET}"
    echo -e "  ${C_CYAN}2)${C_RESET} Daily admin      ${C_DIM}root key-only, users may still use passwords${C_RESET}"
    echo -e "  ${C_CYAN}3)${C_RESET} Key only         ${C_DIM}passwords off, root denied${C_RESET}"
    echo -e "  ${C_CYAN}4)${C_RESET} Root password    ${C_DIM}most open, best for rescue access${C_RESET}"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) apply_preset yubikey-only ;;
      2) apply_preset daily-admin ;;
      3) apply_preset key-only ;;
      4) apply_preset root-password ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

manage_fail2ban_interactive() {
  local choice

  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Fail2ban${C_RESET}"
    box_row "Scope" "SSH login jail only"
    box_row "Jail file" "$FAIL2BAN_JAIL_FILE"
    echo ""
    echo -e "  ${C_CYAN}1)${C_RESET} install and enable fail2ban"
    echo -e "  ${C_CYAN}2)${C_RESET} disable boot-scripts ssh jail"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) enable_fail2ban_guard ;;
      2) disable_fail2ban_guard ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

advanced_menu() {
  local choice

  while true; do
    refresh_screen
    show_status
    echo -e "  ${C_BOLD}Manual adjustments${C_RESET}"
    echo -e "  ${C_CYAN}1)${C_RESET} toggle password auth"
    echo -e "  ${C_CYAN}2)${C_RESET} toggle public-key auth"
    echo -e "  ${C_CYAN}3)${C_RESET} cycle root policy"
    echo -e "  ${C_CYAN}0)${C_RESET} back"
    echo ""
    read -rp "  select: " choice

    case "$choice" in
      1) _toggle PasswordAuthentication "PasswordAuth" ;;
      2) _toggle PubkeyAuthentication "PubkeyAuth" ;;
      3) _cycle_root ;;
      0) return 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

_toggle() {
  local key="$1"
  local desc="$2"
  local current next

  if legacy_yubikey_auth_state && [[ "$key" =~ ^(PasswordAuthentication|PubkeyAuthentication)$ ]]; then
    warn "legacy publickey + otp state is active; use quick modes or YubiKey recovery instead"
    return 1
  fi

  current="$(config_get "$key" "yes")"
  [[ "$current" == "yes" ]] && next="no" || next="yes"
  _update "$key" "$next"
  echo -e "  ${desc}: $(fmt_yn "$next")"
  _restart_ssh
}

_cycle_root() {
  local current next
  current="$(config_get PermitRootLogin "yes")"

  case "$current" in
    yes) next="prohibit-password" ;;
    prohibit-password) next="no" ;;
    no) next="yes" ;;
    *) next="yes" ;;
  esac

  _update PermitRootLogin "$next"
  echo -e "  Root login: $(fmt_root "$next")"
  _restart_ssh
}

apply_preset() {
  local preset="${1:-}"

  case "$preset" in
    root-password|temp-open)
      info "applying preset: root-password"
      apply_standard_auth_mode yes yes yes no
      ;;
    key-only|hardened-prod)
      info "applying preset: key-only"
      apply_standard_auth_mode no no yes no
      ;;
    daily-admin|daily-dev)
      info "applying preset: daily-admin"
      apply_standard_auth_mode prohibit-password yes yes no
      ;;
    yubikey-only|hardened-yubikey)
      info "applying preset: yubikey-only"
      enable_yubikey
      ;;
    *)
      fail "unknown preset: $preset"
      return 1
      ;;
  esac
}

show_status() {
  local auth_methods
  auth_methods="$(auth_methods_value)"

  section "sshman"
  box_row "Current mode" "$(current_login_mode_label)"
  box_row "Login path" "$(login_method_summary)"
  box_row "Root policy" "$(root_access_summary)"
  box_row "YubiKey" "$(yubikey_status_text)"
  box_row "Fail2ban" "$(fail2ban_status_text)"
  box_row "Authorized keys" "$(key_inventory_summary)"
  box_sep
  box_row "Target user" "$TARGET_USER"
  box_row "Password auth" "$(password_summary)"
  box_row "Public-key auth" "$(pubkey_summary)"
  box_row "Keyboard-interactive" "$(keyboard_summary)"
  box_row "Preset match" "$(preset_summary)"
  box_row "PAM package" "$(yubikey_dependency_status)"
  box_row "Fail2ban pkg" "$(fail2ban_dependency_status)"
  box_row "Config file" "$SSH_CONFIG_FILE"
  box_row "YubiKey authfile" "$YUBIKEY_AUTHFILE"
  box_row "Auth methods" "$(auth_methods_summary)"
  section_end
}

show_help() {
  cat <<EOF
sshman $VERSION - SSH configuration manager

Usage:
  sshman.sh                    interactive TUI
  sshman.sh --status           show current config
  sshman.sh --keys             manage authorized keys
  sshman.sh --apply <preset>   apply preset and exit
  sshman.sh --yubikey <cmd>    enable|disable|status|help

Presets:
  root-password
  key-only
  daily-admin
  yubikey-only

Config:
  /etc/boot-scripts/sshman.conf
  ~/.config/boot-scripts/sshman.conf
  $_dir/config/sshman.conf.local
EOF
}

main() {
  local choice

  need_root
  load_config_files
  refresh_runtime_config
  auto_inject_pubkey

  case "${1:-}" in
    --apply)
      [[ -n "${2:-}" ]] || {
        fail "usage: sshman.sh --apply <preset>"
        exit 2
      }
      apply_preset "$2"
      ;;
    --status)
      show_status
      ;;
    --keys)
      manage_keys_interactive
      ;;
    --yubikey)
      case "${2:-status}" in
        enable) enable_yubikey ;;
        disable) disable_yubikey ;;
        status) show_status ;;
        help) show_yubikey_help ;;
        *)
          fail "usage: sshman.sh --yubikey <enable|disable|status|help>"
          exit 2
          ;;
      esac
      ;;
    --interactive|-i|"")
      while true; do
        refresh_screen
        show_status
        show_main_actions
        echo ""
        read -rp "  select: " choice

        case "$choice" in
          1) quick_modes_menu ;;
          2) manage_keys_interactive ;;
          3) manage_yubikey_interactive ;;
          4) manage_fail2ban_interactive ;;
          5) advanced_menu ;;
          0) exit 0 ;;
          *) warn "invalid choice" ;;
        esac
      done
      ;;
    -h|--help)
      show_help
      ;;
    *)
      fail "unknown option: $1"
      exit 2
      ;;
  esac
}

main "$@"
