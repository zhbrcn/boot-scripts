#!/usr/bin/env bash
# fix-time.sh - Robust time repair for Debian/Ubuntu systems

set -euo pipefail

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

info() { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARNING: $*" >&2; }

time_systemd_ready() {
  [[ -d /run/systemd/system ]] && has_cmd systemctl && has_cmd timedatectl
}

ensure_timesyncd() {
  time_systemd_ready || {
    warn "systemd not detected; skipping timesyncd setup"
    return 1
  }

  if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
    info "installing systemd-timesyncd..."
    apt-get update -qq
    apt-get install -y systemd-timesyncd >/dev/null 2>&1 || true
  fi
}

configure_timesyncd() {
  local conf="/etc/systemd/timesyncd.conf"
  mkdir -p /etc/systemd

  if [[ ! -f "$conf" ]]; then
    {
      echo "[Time]"
      echo "NTP=$NTP_SERVERS"
      echo "FallbackNTP=pool.ntp.org"
    } > "$conf"
    info "created $conf"
    return 0
  fi

  grep -q '^\[Time\]' "$conf" || printf '\n[Time]\n' >> "$conf"

  if grep -q '^NTP=' "$conf"; then
    sed -i "s/^NTP=.*/NTP=$NTP_SERVERS/" "$conf"
  else
    sed -i '/^\[Time\]/a NTP='"$NTP_SERVERS" "$conf"
  fi

  if ! grep -q '^FallbackNTP=' "$conf"; then
    sed -i '/^\[Time\]/a FallbackNTP=pool.ntp.org' "$conf"
  fi

  info "updated $conf"
}

restart_time_services() {
  time_systemd_ready || return 1
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
  systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true
}

is_synced() {
  local value
  time_systemd_ready || return 1
  value="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
  [[ "$value" == "yes" ]]
}

wait_for_sync() {
  local start deadline now
  start="$(date +%s)"
  deadline=$((start + TIMEOUT_SEC))

  while true; do
    is_synced && return 0
    now="$(date +%s)"
    (( now >= deadline )) && return 1
    sleep 2
  done
}

http_bootstrap_time() {
  local date_hdr=""
  warn "NTP sync timed out; falling back to HTTP Date bootstrap"

  if has_cmd curl; then
    date_hdr="$(curl -sI "$HTTP_BOOTSTRAP_URL" | awk -F': ' 'tolower($1)=="date"{print $2}' | tail -n 1 || true)"
  elif has_cmd wget; then
    date_hdr="$(wget -qSO- "$HTTP_BOOTSTRAP_URL" 2>&1 | awk -F': ' 'tolower($1)=="  date"{print $2}' | tail -n 1 || true)"
  else
    warn "neither curl nor wget found; cannot bootstrap time over HTTP"
    return 1
  fi

  [[ -n "$date_hdr" ]] || {
    warn "could not read HTTP Date header"
    return 1
  }

  info "HTTP Date: $date_hdr"
  if date -u -s "$date_hdr" >/dev/null 2>&1; then
    info "set system time from HTTP header"
  else
    warn "failed to set time"
    return 1
  fi
}

write_hwclock() {
  has_cmd hwclock || {
    warn "hwclock not available; skipping RTC sync"
    return 0
  }
  [[ -e /dev/rtc || -e /dev/rtc0 ]] || {
    warn "RTC device not present; skipping"
    return 0
  }

  has_cmd timedatectl && timedatectl set-local-rtc 0 >/dev/null 2>&1 || true

  hwclock --systohc --utc >/dev/null 2>&1 ||
  hwclock --systohc >/dev/null 2>&1 || {
    warn "failed to write system time to RTC"
    return 1
  }

  info "wrote system time to RTC"
}

show_status() {
  info "=== current time ==="
  date -u || true
  time_systemd_ready && timedatectl || true
  has_cmd hwclock && hwclock || true
}

do_install() {
  local script_path="/usr/local/sbin/fix-time"
  local unit_path="/etc/systemd/system/fix-time.service"

  need_root

  if [[ "$(realpath "$0")" != "$script_path" ]]; then
    install -m 0755 "$0" "$script_path"
    info "installed to $script_path"
  fi

  {
    echo "[Unit]"
    echo "Description=Fix system time after snapshot or boot"
    echo "Wants=network-online.target"
    echo "After=network-online.target systemd-timesyncd.service"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=/usr/local/sbin/fix-time"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "$unit_path"

  systemctl daemon-reload
  systemctl enable fix-time.service
  info "installed and enabled fix-time.service"
  info "run now with: sudo systemctl start fix-time"
}

run_fix() {
  if time_systemd_ready; then
    ensure_timesyncd
    configure_timesyncd
    restart_time_services

    if wait_for_sync; then
      info "NTP synced"
    else
      warn "NTP sync timed out (${TIMEOUT_SEC}s)"
      if http_bootstrap_time; then
        info "HTTP bootstrap succeeded; retrying NTP..."
        restart_time_services
        wait_for_sync || warn "still not NTP-synced, but system time is set"
      else
        warn "HTTP bootstrap failed; time may still be incorrect"
      fi
    fi
  else
    warn "systemd not available; using HTTP bootstrap only"
    http_bootstrap_time || warn "HTTP bootstrap failed"
  fi

  write_hwclock || true
  show_status
}

main() {
  case "${1:-run}" in
    run) run_fix ;;
    --status) show_status ;;
    --install) do_install ;;
    -h|--help)
      echo "Usage:"
      echo "  fix-time.sh"
      echo "  fix-time.sh --status"
      echo "  fix-time.sh --install"
      ;;
    *)
      echo "unknown arg: $1" >&2
      echo "Usage: fix-time.sh [--status|--install]" >&2
      exit 2
      ;;
  esac
}

main "$@"
