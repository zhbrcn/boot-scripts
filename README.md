# boot-scripts - Personal boot scripts

此仓库用于个人开机启动脚本集合。每个功能独立为一个 `.sh`，统一入口脚本用于批量执行，也可单独运行。

**一键运行（推荐先看脚本内容）**
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/bin/boot.sh -o /tmp/boot.sh \
  && chmod +x /tmp/boot.sh \
  && /tmp/boot.sh --bootstrap --dir /tmp/scripts \
  && sudo /tmp/boot.sh --all
```

**配置教程**
1) 创建配置文件（推荐）
   - 文件: `/etc/ssh/sshman.conf`
   - 示例:
```bash
# 目标用户（默认使用 SUDO_USER/USER）
TARGET_USER="root"
# TARGET_HOME="/root"

# 默认公钥注入（默认关闭）
AUTO_INJECT_DEFAULT_PUBKEY="1"
DEFAULT_PUBKEY="ssh-ed25519 AAAA... your_key_comment"

# YubiKey（可选，仅启用时需要）
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="base64_secret"

# 如需自定义授权公钥路径
# AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
```
2) 临时用环境变量覆盖
```bash
sudo AUTO_INJECT_DEFAULT_PUBKEY=1 \
  DEFAULT_PUBKEY="ssh-ed25519 AAAA..." \
  ./scripts/sshman.sh
```
3) 配置写入位置说明
- 如果存在 `/etc/ssh/sshd_config.d/`，脚本会写入 `/etc/ssh/sshd_config.d/99-sshman.conf`；否则回退到 `/etc/ssh/sshd_config`。

**编码提示（Windows）**
- 若在 Windows 上出现乱码，请确保文件以 UTF-8 打开，或在终端执行 `chcp 65001`。

**Directory Structure**
- `bin/boot.sh` 统一入口，支持 `--list` / `--run` / `--all`
- `scripts/*.sh` 功能脚本（可单独执行）
- `systemd/boot-scripts.service` 示例 systemd 服务文件

**Naming Convention**
- 统一使用小写 + 中划线（kebab-case），例如 `fix-time.sh`
- 需要固定执行顺序时，用数字前缀控制：`00-xxx.sh`, `10-xxx.sh`

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
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/sshman.sh -o sshman.sh \
  && chmod +x sshman.sh \
  && sudo ./sshman.sh
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash -s -- --install-service
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh -o /tmp/fix-time.sh \
  && sed -n '1,200p' /tmp/fix-time.sh \
  && sudo bash /tmp/fix-time.sh --install-service
```
