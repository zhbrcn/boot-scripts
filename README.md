# boot-scripts - Personal boot scripts

????????????????????????? `.sh`?????????????????????

**????**
1) ??????????
   - ??: `/etc/ssh/sshman.conf`
   - ??:
```bash
# ????????? SUDO_USER/USER?
TARGET_USER="root"
# TARGET_HOME="/root"

# ????????????
AUTO_INJECT_DEFAULT_PUBKEY="1"
DEFAULT_PUBKEY="ssh-ed25519 AAAA... your_key_comment"

# YubiKey???????????
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="base64_secret"

# ???????????
# AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
```
2) ?????????
```bash
sudo AUTO_INJECT_DEFAULT_PUBKEY=1   DEFAULT_PUBKEY="ssh-ed25519 AAAA..."   ./scripts/sshman.sh
```
3) ????????
- ???? `/etc/ssh/sshd_config.d/`?????? `/etc/ssh/sshd_config.d/99-sshman.conf`?????? `/etc/ssh/sshd_config`?

**?????Windows?**
- ?? Windows ???????????? UTF-8 ????????? `chcp 65001`?

**Directory Structure**
- `bin/boot.sh` ??????? `--list` / `--run` / `--all`
- `scripts/*.sh` ???????????
- `systemd/boot-scripts.service` ?? systemd ????

**Naming Convention**
- ?????? + ????kebab-case???? `fix-time.sh`
- ??????????????????`00-xxx.sh`, `10-xxx.sh`

**Usage**
```bash
# List available scripts
./bin/boot.sh --list

# Run one script (pass args after --)
./bin/boot.sh --run fix-time -- --install-service

# Run all scripts (lexicographic order)
./bin/boot.sh --all
```

**Run A Single Script**
```bash
chmod +x ./scripts/*.sh
./scripts/sshman.sh
./scripts/fix-time.sh --install-service
```

**Systemd Autostart (example)**
```bash
sudo cp systemd/boot-scripts.service /etc/systemd/system/
sudo sed -i 's|/opt/sshman|/path/to/sshman|g' /etc/systemd/system/boot-scripts.service
sudo systemctl daemon-reload
sudo systemctl enable --now boot-scripts.service
```

**Direct Download (raw)**
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/sshman.sh -o sshman.sh   && chmod +x sshman.sh   && sudo ./sshman.sh
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash -s -- --install-service
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh -o /tmp/fix-time.sh   && sed -n '1,200p' /tmp/fix-time.sh   && sudo bash /tmp/fix-time.sh --install-service
```
