# boot-scripts

Personal server bootstrap scripts — run on boot to configure a fresh VPS or recovered snapshot to your preferred state.

Each script is **standalone** and **idempotent**: safe to run repeatedly, and works whether or not it's the first time.

---

## What it does

| Script | What it handles |
|--------|----------------|
| `sshman` | SSH hardening, authorized keys, YubiKey 2FA, one-click presets |
| `fix-time` | NTP sync with HTTP Date header fallback (for VPS snapshots with wrong time) |
| `sysinfo` | System information display |

The unified entry point `bin/boot.sh` can run all scripts in sequence or launch an interactive menu.

---

## Quick start

### One-liner bootstrap

Download everything and run the interactive menu:

```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/bin/boot.sh -o /tmp/boot.sh \
  && chmod +x /tmp/boot.sh \
  && /tmp/boot.sh --bootstrap --dir /tmp/scripts \
  && /tmp/boot.sh --menu
```

### Run all scripts automatically

```bash
sudo /tmp/boot.sh --all
```

---

## Interactive TUI

```bash
./bin/boot.sh --menu
```

Opens a color-coded menu with:
- System info dashboard
- SSH configuration (interactive, toggle settings, manage keys)
- Time fix
- Run all scripts

---

## Per-script usage

### sshman

```bash
sudo ./scripts/sshman.sh                  # interactive TUI
sudo ./scripts/sshman.sh --status         # show current SSH config
sudo ./scripts/sshman.sh --apply hardened-prod   # apply preset + exit
sudo ./scripts/sshman.sh --apply daily-dev      # daily dev preset
```

**Presets:**

| Preset | RootLogin | PasswordAuth | PubkeyAuth |
|--------|-----------|--------------|------------|
| `hardened-prod` | denied | off | on |
| `daily-dev` | key-only | on | on |
| `temp-open` | allowed | on | on |

**Configuration file** (`/etc/boot-scripts/sshman.conf` or `~/.config/boot-scripts/sshman.conf`):

```bash
AUTO_INJECT_DEFAULT_PUBKEY="1"
DEFAULT_PUBKEY="ssh-ed25519 AAAA... your@email"
TARGET_USER="root"
```

### fix-time

```bash
sudo ./scripts/fix-time.sh                # run once
sudo ./scripts/fix-time.sh --status        # show time status only
sudo ./scripts/fix-time.sh --install       # install as systemd oneshot at boot
```

Logic: NTP via `systemd-timesyncd` → HTTP Date header fallback → write to RTC.

### sysinfo

```bash
./scripts/sysinfo.sh
```

Shows: OS, CPU, RAM, disk, IP addresses, Docker version, SSH/NTP service status.

---

## Systemd service (auto-run on boot)

```bash
# Install
sudo make install

# Or manually
sudo cp systemd/boot-scripts.service /etc/systemd/system/
sudo sed -i 's|%SCRIPT_DIR%|/opt/boot-scripts|g' /etc/systemd/system/boot-scripts.service
sudo systemctl daemon-reload
sudo systemctl enable --now boot-scripts.service

# Test without rebooting
sudo systemctl start boot-scripts
```

The service runs `boot.sh --all` as a oneshot on every boot.

---

## Directory layout

```
boot-scripts/
├── bin/
│   └── boot.sh              # Unified entry point
├── lib/
│   ├── common.sh            # Shared utilities (root check, backup, logging, SSH helpers)
│   └── ui.sh                # Shared TUI components (colors, boxes, menus, spinner)
├── scripts/
│   ├── sshman.sh            # SSH configuration manager
│   ├── fix-time.sh          # Time sync with fallback
│   └── sysinfo.sh           # System information display
├── config/
│   └── sshman.conf.example  # Config template
├── systemd/
│   └── boot-scripts.service # Systemd oneshot service
├── Makefile
├── .shellcheckrc
└── README.md
```

---

## Requirements

- Debian/Ubuntu (uses `apt-get`, `systemd-timesyncd`, `systemctl`)
- Bash ≥ 4.0
- Root privileges (for SSH config and service management)
- Internet (for NTP and time bootstrap)

---

## Direct download (individual scripts)

```bash
# sshman
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/sshman.sh -o sshman.sh \
  && chmod +x sshman.sh && sudo ./sshman.sh

# fix-time
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash
```

---

## Install as a repo on a new VPS

```bash
git clone https://github.com/zhbrcn/boot-scripts.git /opt/boot-scripts
cd /opt/boot-scripts
sudo make install
```

Or without git:

```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/bin/boot.sh -o boot.sh \
  && chmod +x boot.sh \
  && ./boot.sh --bootstrap \
  && sudo ./boot.sh --all
```
