#!/usr/bin/env bash
# install.sh - One-shot installer for boot-scripts

set -euo pipefail

REPO_SLUG="${BOOT_SCRIPTS_REPO:-zhbrcn/boot-scripts}"
REF="${BOOT_SCRIPTS_REF:-main}"

BOOT_FILES=(
  "bin/boot.sh:0755"
  "lib/common.sh:0644"
  "lib/ui.sh:0644"
  "scripts/first-boot.sh:0755"
  "scripts/base-packages.sh:0755"
  "scripts/network.sh:0755"
  "scripts/sshman.sh:0755"
  "scripts/fix-time.sh:0755"
  "scripts/hostname.sh:0755"
  "scripts/sysinfo.sh:0755"
  "scripts/autopush.sh:0755"
)

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

default_install_dir() {
  if is_root; then
    printf '/opt/boot-scripts\n'
  else
    printf '%s/.local/share/boot-scripts\n' "$HOME"
  fi
}

download_to() {
  local url="$1"
  local dest="$2"

  if has_cmd curl; then
    curl -fsSL "$url" -o "$dest"
    return 0
  fi

  if has_cmd wget; then
    wget -qO "$dest" "$url"
    return 0
  fi

  echo "error: curl or wget is required" >&2
  return 1
}

attach_tty() {
  [[ -r /dev/tty ]]
}

download_repo_file() {
  local rel_path="$1"
  local mode="$2"
  local dest="${INSTALL_DIR}/${rel_path}"
  local url="https://raw.githubusercontent.com/${REPO_SLUG}/${REF}/${rel_path}"

  mkdir -p "$(dirname "$dest")"
  echo "downloading ${rel_path}..."
  download_to "$url" "$dest"
  chmod "$mode" "$dest"
}

install_repo_layout() {
  local entry rel_path mode

  for entry in "${BOOT_FILES[@]}"; do
    rel_path="${entry%%:*}"
    mode="${entry##*:}"
    download_repo_file "$rel_path" "$mode"
  done
}

main() {
  INSTALL_DIR="${1:-${BOOT_SCRIPTS_INSTALL_DIR:-$(default_install_dir)}}"
  local boot_sh="${INSTALL_DIR}/bin/boot.sh"
  local scripts_dir="${INSTALL_DIR}/scripts"

  mkdir -p "$INSTALL_DIR"

  echo "install dir: $INSTALL_DIR"
  echo "source ref:  $REF"

  install_repo_layout

  printf '%s\n' "$REF" > "${INSTALL_DIR}/.boot-scripts-ref"
  printf '%s\n' "$scripts_dir" > "${INSTALL_DIR}/bin/.boot-scripts-dir"

  echo "enabling autopush..."
  "$scripts_dir/autopush.sh" --enable

  echo "starting menu..."
  if attach_tty; then
    BOOT_SCRIPTS_DIR="$scripts_dir" "$boot_sh" --menu </dev/tty >/dev/tty 2>/dev/tty
  else
    echo "warning: no interactive tty detected, skipping menu" >&2
    echo "run this manually to open the menu:"
    echo "  BOOT_SCRIPTS_DIR=$scripts_dir $boot_sh --menu"
  fi
}

main "$@"
