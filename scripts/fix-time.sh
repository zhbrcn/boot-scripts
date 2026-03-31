#!/usr/bin/env bash
# fix-time.sh — Robust time fix for Debian snapshots / VPS images
#
# Logic:
#   1. Prefer systemd-timesyncd (NTP, UDP 123)
#   2. If NTP sync times out → HTTP Date header bootstrap (plain HTTP, no TLS)
#   3. Write system time back to RTC
#
# Usage:
#   fix-time.sh             # run once
#   fix-time.sh --status    # show sync status only
#   fix-time.sh --install   # install as systemd oneshot at boot

set -euo pipefail

# ── Source shared lib ─────────────────────────────────────────────────────────
# If sourced from boot.sh context, lib/ is already in BASH_SOURCE hierarchy.
# Otherwise fall back to relative path from this script's location.
if [[ -z "${LIB_LOADED:-}" ]]; then
  _src="${BASH_SOURCE[0]}"
  _dir="$(cd "$(dirname "$_src")" && pwd)"
  while [[ "$_dir" != "/" ]]; do
    if [[ -f "$_dir/lib/common.sh" ]]; then
      source "$_dir/lib/common.sh"
      break
    fi
    _dir="$(dirname "$_dir")"
  done
fi

LOG_PREFIX="${LOG_PREFIX:-[fix-time]}"
TIMEOUT_SEC="${TIMEOUT_SEC:-60}"
HTTP_BOOTSTRAP_URL="${HTTP_BOOTSTRAP_URL:-http://neverssl.com/}"
NTP_SERVERS="${NTP_SERVERS:-time.cloudflare.com time.google.com pool.ntp.org}"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "$LOG_PREFIX $*"; }
warn()  { echo "$LOG_PREFIX WARNING: $*" >&2; }

is_systemd() {
  [[ -d /run/systemd/system ]] && has_cmd systemctl && has_cmd timedatectl
}

# ── NTP sync ──────────────────────────────────────────────────────────────────
ensure_timesyncd() {
  is_systemd || { warn "systemd not detected; skipping timesyncd setup"; return 1; }
  if ! systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
    info "installing systemd-timesyncd…"
    apt-get update -qq && apt-get install -y systemd-timesyncd 2>/dev/null || true
  fi
}

configure_timesyncd() {
  local conf="/etc/systemd/timesyncd.conf"
  mkdir -p /etc/systemd

  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=pool.ntp.org
EOF
    info "created $conf"
    return
  fi

  # Ensure [Time] section exists
  grep -q '^\[Time\]' "$conf" || printf '\n[Time]\n' >> "$conf"

  # Update or insert NTP=
  if grep -q '^NTP=' "$conf"; then
    sed -i "s/^NTP=.*/NTP=$NTP_SERVERS/" "$conf"
  else
    sed -i '/^\[Time\]/a NTP='"$NTP_SERVERS" "$conf"
  fi

  # Ensure FallbackNTP
  if ! grep -q '^FallbackNTP=' "$conf"; then
    sed -i '/^\[Time\]/a FallbackNTP=pool.ntp.org' "$conf"
  fi
  info "updated $conf"
}

restart_time_services() {
  is_systemd || return 1
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
  systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true
}

is_synced() {
  is_systemd || return 1
  local v
  v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
  [[ "$v" == yes ]]
}

wait_for_sync() {
  local start end now
  start=$(date +%s)
  end=$((start + TIMEOUT_SEC))
  while true; do
    is_synced && return 0
    now=$(date +%s)
    (( now >= end )) && return 1
    sleep 2
  done
}

# ── HTTP bootstrap ─────────────────────────────────────────────────────────────
http_bootstrap_time() {
  warn "NTP sync timed out; falling back to HTTP Date bootstrap"
  local date_hdr=""

  if has_cmd curl; then
    date_hdr=$(curl -sI "$HTTP_BOOTSTRAP_URL" \
      | awk -F': ' 'tolower($1)=="date"{print $2}' \
      | tail -n1 \
      || true)
  elif has_cmd wget; then
    date_hdr=$(wget -qSO- "$HTTP_BOOTSTRAP_URL" 2>&1 \
      | awk -F': ' 'tolower($1)=="  date"{print $2}' \
      | tail -n1 \
      || true)
  else
    warn "neither curl nor wget found; cannot HTTP bootstrap"
    return 1
  fi

  [[ -z "$date_hdr" ]] && { warn "could not read HTTP Date header"; return 1; }

  info "HTTP Date: $date_hdr"
  date -u -s "$date_hdr" >/dev/null 2>&1 \
    && info "set system time from HTTP header" \
    || { warn "failed to set time"; return 1; }
}

# ── RTC ───────────────────────────────────────────────────────────────────────
write_hwclock() {
  has_cmd hwclock || { warn "hwclock not available; skipping RTC sync"; return 0; }
  [[ -e /dev/rtc || -e /dev/rtc0 ]] \
    || { warn "RTC device not present; skipping"; return 0; }

  has_cmd timedatectl && timedatectl set-local-rtc 0 >/dev/null 2>&1 || true

  hwclock --systohc --utc >/dev/null 2>&1 \
    || hwclock --systohc >/dev/null 2>&1 \
    || { warn "failed to write system time to RTC"; return 1; }
  info "wrote system time to RTC"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  info "=== current time ==="
  date -u || true
  if is_systemd; then
    timedatectl || true
  fi
  if has_cmd hwclock; then
    hwclock || true
  fi
}

# ── Install ───────────────────────────────────────────────────────────────────
do_install() {
  need_root
  local script_path="/usr/local/sbin/fix-time"
  local unit_path="/etc/systemd/system/fix-time.service"

  if [[ "$(realpath "$0")" != "$script_path" ]]; then
    install -m 0755 "$0" "$script_path"
    info "installed to $script_path"
  fi

  cat > "$unit_path" <<'EOF'
[Unit]
Description=Fix system time after snapshot/boot (NTP + HTTP fallback)
Wants=network-online.target
After=network-online.target systemd-timesyncd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fix-time

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable fix-time.service
  info "installed and enabled fix-time.service"
  info "run now with: sudo systemctl start fix-time"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  case "${1:-run}" in
    run)
      if is_systemd; then
        ensure_timesyncd
        configure_timesyncd
        restart_time_services

        if wait_for_sync; then
          info "NTP synced ✓"
        else
          warn "NTP sync timed out (${TIMEOUT_SEC}s)"
          if http_bootstrap_time; then
            info "HTTP bootstrap ok; retrying NTP…"
            restart_time_services
            wait_for_sync || warn "still not NTP-synced (system time is set)"
          else
            warn "HTTP bootstrap failed; time may be incorrect"
          fi
        fi
      else
        warn "systemd not available; using HTTP bootstrap only"
        http_bootstrap_time || warn "HTTP bootstrap failed"
      fi

      write_hwclock || true
      show_status
      ;;

    --status)
      show_status
      ;;

    --install)
      do_install
      ;;

    -h|--help)
      echo "Usage:"
      echo "  fix-time.sh               # run once"
      echo "  fix-time.sh --status      # show status only"
      echo "  fix-time.sh --install     # install as systemd service"
      ;;

    *)
      echo "unknown arg: $1" >&2
      echo "Usage: fix-time.sh [--status|--install]" >&2
      exit 2
      ;;
  esac
}

main "$@"
