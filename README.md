# boot-scripts

Personal Linux bootstrap scripts for my own VPS and fresh system setup.

This repository is primarily for self-use.
It is not designed as a general-purpose distribution, and it may not fit every machine, distro, SSH policy, PAM layout, or network environment.
If you use it, assume you are responsible for reviewing what it changes before running it on an important host.

## Scope

This project is aimed at a small set of practical first-day tasks on Debian/Ubuntu-style systems:

- guided first boot setup
- SSH mode switching, YubiKey HOTP-only login, and optional SSH fail2ban guard
- hostname and `/etc/hosts` management
- time repair
- DNS / timezone / connectivity checks
- installation of a few common base package sets
- SSH login auto-attach to a persistent tmux workspace
- quick machine summary and health checks

## Included scripts

| Script | Purpose |
|--------|---------|
| `first-boot` | Guided first-run flow for hostname, network, time, SSH, and packages |
| `sysinfo` | Machine summary plus SSH, YubiKey, hostname, time, and DNS checks |
| `sshman` | Manage SSH modes, root policy, authorized keys, and YubiKey HOTP |
| `network` | Review and adjust DNS, timezone, and connectivity |
| `fix-time` | Repair system time with NTP first and HTTP fallback second |
| `hostname` | Set hostname and keep `/etc/hosts` aligned |
| `base-packages` | Install common package groups for a fresh host |
| `tmux-workspace` | Configure SSH login auto-attach to a fixed tmux session |

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/install.sh | bash
```

Default install path:

- `root`: `/opt/boot-scripts`
- normal user: `~/.local/share/boot-scripts`

To pin a specific revision:

```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/install.sh | BOOT_SCRIPTS_REF=<commit> bash
```

## Manual entry

After installation:

```bash
/opt/boot-scripts/bin/boot.sh --menu
```

Or, if installed as a normal user:

```bash
~/.local/share/boot-scripts/bin/boot.sh --menu
```

## Notes

- Expected target: Debian or Ubuntu style systems
- Most useful actions require `root`
- SSH and PAM changes can lock you out if your environment differs from mine
- YubiKey behavior in this repo is intentionally opinionated and tailored to my own usage
- The built-in YubiKey mode is meant to enforce HOTP-only SSH for my own servers
- The package selections are convenience defaults, not a universal standard

## Layout

```text
boot-scripts/
|-- bin/
|   `-- boot.sh
|-- lib/
|   |-- common.sh
|   `-- ui.sh
|-- scripts/
|   |-- base-packages.sh
|   |-- first-boot.sh
|   |-- fix-time.sh
|   |-- hostname.sh
|   |-- tmux-workspace.sh
|   |-- network.sh
|   |-- sshman.sh
|   `-- sysinfo.sh
|-- install.sh
`-- README.md
```

## Safety

If you plan to use this on a real server:

- read the scripts first
- keep an existing root session open while changing SSH
- test on a VM before using it on a remote host you care about
