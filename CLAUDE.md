# CLAUDE.md

Guidelines for any AI assistant (Claude Code, etc.) working on this repository.
Read this file first. It defines what this project is, how it is wired together,
and — most importantly — what you are **not** allowed to touch without being asked.

---

## 1. Project purpose

`boot-scripts` is the owner's personal toolbox for bootstrapping and repairing
Debian/Ubuntu VPS hosts. It is **not** a general-purpose distribution.

Design assumptions:

- Target: Debian/Ubuntu-style systems, invoked as root on a fresh host.
- Interface: plain POSIX-ish bash + a small TUI in `lib/ui.sh`.
- No heavy dependencies. No Python, no Node. Just bash + standard coreutils.
- Idempotent by default — running a script twice should not break the host.

If a change would pull in a new runtime, a new package manager, or a new
abstraction layer, **stop and ask** before writing it.

---

## 2. Repository layout

```
boot-scripts/
├── bin/
│   └── boot.sh              # unified entry point + interactive menu
├── lib/
│   ├── common.sh            # logging, has_cmd, is_root, backup_file, etc.
│   └── ui.sh                # colors, section, menu, read_choice, pause
├── scripts/
│   ├── first-boot.sh        # guided first-run flow
│   ├── base-packages.sh     # package groups install
│   ├── network.sh           # DNS / timezone / connectivity
│   ├── sshman.sh            # SSH modes + keys + YubiKey HOTP
│   ├── fix-time.sh          # NTP first, HTTP fallback
│   ├── hostname.sh          # hostname + /etc/hosts
│   ├── sysinfo.sh           # summary / health checks
│   └── autopush.sh          # git autopush alias toggle
├── config/
│   └── sshman.conf.example  # optional user overrides for sshman
├── systemd/
│   └── boot-scripts.service # optional first-boot unit
├── install.sh               # one-line remote installer
├── Makefile                 # install / uninstall / lint
└── README.md                # user-facing documentation
```

Every new **user-facing feature** should be a single file in `scripts/`.
Shared helpers go in `lib/`. Anything in `bin/` is wiring only.

---

## 3. How the menu is wired

1. `bin/boot.sh` is the only entry point end users run.
2. `boot.sh --menu` sources `lib/common.sh` and `lib/ui.sh`, then builds an
   items array and calls `menu "boot-scripts" "${items[@]}"`.
3. Each menu item is a string of the form `"label|action"`.
   - A label whose action is `:` is a section header (non-selectable).
   - Otherwise `action` is evaluated via `eval` — usually `run_script ...`
     or a helper function defined in `boot.sh` (e.g. `toggle_autopush`).
4. `run_script` executes a script in a **fresh `bash` subprocess**, so
   `set -e` / `set -u` in the parent do not leak into the child.
5. `menu()` clears the screen at the top of every loop. Short-lived scripts
   MUST either produce enough output to be noticed OR be wrapped in a helper
   that calls `pause` / `read -rp` before returning (see `toggle_autopush`).

If a new script is quick and silent, add a `pause` step in its menu wrapper.
Do **not** remove `clear_screen` from `menu()` just to fix one script.

---

## 4. Adding a new feature — the standard flow

1. Put the script in `scripts/<name>.sh`. Make it executable.
2. Give it a `usage()` function and a flag-driven `main()`. Mirror the style
   of `autopush.sh` or `hostname.sh` — don't invent a new convention.
3. Source nothing implicitly. If you need helpers, source `lib/common.sh`
   and/or `lib/ui.sh` explicitly at the top of the script.
4. Register the script in three places (and only these three):
   - `BOOTSTRAP_SCRIPTS` array in `bin/boot.sh` (so remote install pulls it).
   - The `items` array in `interactive_menu` in `bin/boot.sh`.
   - The `Included scripts` table in `README.md`.
5. If it installs files or edits system config, use `backup_file` from
   `lib/common.sh` before overwriting, and make it idempotent.
6. Shellcheck-clean: `make test` must pass.

---

## 5. Hard boundaries — do not touch without explicit request

When the user asks you to add / fix / change **feature X**, you may only
modify files that belong to X plus the minimal wiring above. Treat the rest
of the repo as frozen.

Concretely:

- **Do not** refactor `lib/common.sh` or `lib/ui.sh` as a side effect of a
  feature change. Shared lib edits need their own dedicated request.
- **Do not** rename, reorder, or restructure existing scripts in `scripts/`
  unless the task is literally "refactor".
- **Do not** touch `install.sh`, `Makefile`, or `systemd/` unless the feature
  directly requires it. If it does, say so first.
- **Do not** change SSH, PAM, firewall, or YubiKey behavior in `sshman.sh`
  unless explicitly asked. These have caused lockouts before.
- **Do not** introduce new top-level directories, new languages, or new
  dependencies.
- **Do not** rewrite the menu system, the TUI helpers, or the color scheme
  on the way to fixing something else.

If a fix legitimately requires crossing one of these boundaries, **stop and
explain the reason** before making the change. A surprised user is worse
than a delayed fix.

---

## 6. Style rules

- Bash with `set -euo pipefail` (or `set -uo pipefail` where `-e` is unsafe,
  e.g. when you rely on non-zero returns like `is_enabled`).
- Two-space indentation. Lowercase function names with underscores.
- Error messages to stderr via `log_error` / `>&2`. Normal output to stdout.
- Prefer `printf` over `echo -e` inside functions that might be sourced.
- No emojis in script output. No ANSI escapes outside `lib/ui.sh` — use the
  `ok` / `fail` / `info` / `warn` helpers instead.
- Comments: explain *why*, not *what*. If the code is self-evident, no comment.
- Keep each script self-contained enough that `bash scripts/<name>.sh --help`
  explains it without needing the menu.

---

## 7. Testing expectations

- `make test` runs shellcheck on every script. It should stay clean.
- For changes to the menu or interactive flows, manually verify that:
  - the menu renders,
  - each menu item runs its script,
  - short-lived actions leave visible output (use a `pause`),
  - `q` / `Q` / empty input exits the menu,
  - nested menus (e.g. `sshman --interactive`) return cleanly to the parent.
- Never claim a UI change is done without running it. Type-checks do not
  verify TUI behavior.

---

## 8. When in doubt

Ask a clarifying question instead of guessing. This repo is opinionated and
tailored to one person's workflow — assumptions imported from other projects
will usually be wrong here.
