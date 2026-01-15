#!/bin/bash
# ==============================================================================
# sshman - SSH 登录配置管理工具 (个人专用版)
# 版本: v1.0.8
# 作者: 代码助手
# 说明: 本脚本仅供个人服务器管理使用，请勿在未授权的生产环境中分发。
# 更新: 支持配置文件/环境变量覆盖默认设置。
# ==============================================================================

set -e

# --- [ ?????? ] ---
VERSION="v1.0.8"
SSH_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_CONF_FILE="$SSH_CONFIG"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
SSHMAN_CONFIG="/etc/ssh/sshman.conf"

if [[ -f "$SSHMAN_CONFIG" ]]; then
    # shellcheck source=/dev/null
    . "$SSHMAN_CONFIG"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER:-root}}}"
TARGET_HOME="${TARGET_HOME:-}"
if [[ -z "$TARGET_HOME" ]]; then
    if command -v getent >/dev/null 2>&1; then
        TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
    fi
    if [[ -z "$TARGET_HOME" ]]; then
        [[ "$TARGET_USER" == "root" ]] && TARGET_HOME="/root" || TARGET_HOME="/home/$TARGET_USER"
    fi
fi

if [[ -d "$SSHD_DROPIN_DIR" ]]; then
    SSHD_CONF_FILE="${SSHD_DROPIN_DIR}/99-sshman.conf"
fi

AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-$TARGET_HOME/.ssh/authorized_keys}"
AUTHORIZED_YUBIKEYS="${AUTHORIZED_YUBIKEYS:-/etc/ssh/authorized_yubikeys}"
AUTO_INJECT_DEFAULT_PUBKEY="${AUTO_INJECT_DEFAULT_PUBKEY:-0}"
DEFAULT_PUBKEY="${DEFAULT_PUBKEY:-}"

# YubiKey ???? (???????? /etc/ssh/sshman.conf ??)
HARDENED_YUBIKEYS="${HARDENED_YUBIKEYS:-}"
YUBI_CLIENT_ID="${YUBI_CLIENT_ID:-}"
YUBI_SECRET_KEY="${YUBI_SECRET_KEY:-}"
# 颜色代码
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [ 环境自检 ] ---
[[ $EUID -ne 0 ]] && { echo -e "${RED}[错误] 请使用 sudo 运行此脚本。${RESET}"; exit 1; }
mkdir -p "$BACKUP_DIR"
# 自动探测 SSH 服务名
systemctl list-unit-files | grep -q "^ssh.service" && SSH_SERVICE="ssh" || SSH_SERVICE="sshd"
# 自动探测 sshd 二进制路径
SSHD_BIN=$(which sshd 2>/dev/null || echo "/usr/sbin/sshd")

# --- [ 核心工具函数 ] ---

_flash_msg() { sleep 1.2; }

_backup_file() {
    local file=$1
    [[ -f "$file" ]] && cp "$file" "$BACKUP_DIR/$(basename "$file").bak.$(date +%F-%H%M%S)"
}

_fix_ownership() {
    local path=$1
    local user=$2
    local group
    group="$(id -gn "$user" 2>/dev/null || echo "$user")"
    chown "$user":"$group" "$path" 2>/dev/null || true
}

# [自动注入] 启动时静默写入默认公钥，失败不报错
_auto_inject_pubkey() {
    [[ "$AUTO_INJECT_DEFAULT_PUBKEY" == "1" ]] || return 0
    [[ -n "$DEFAULT_PUBKEY" ]] || return 0

    # 确保目录存在，失败则静默返回
    if ! mkdir -p "$TARGET_HOME/.ssh" 2>/dev/null; then return 0; fi
    if ! chmod 700 "$TARGET_HOME/.ssh" 2>/dev/null; then return 0; fi
    _fix_ownership "$TARGET_HOME/.ssh" "$TARGET_USER"

    # 检查是否已存在
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        # 使用 grep -F 确保精确匹配字符串，避免正则转义问题
        if ! grep -qF "$DEFAULT_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
            echo "$DEFAULT_PUBKEY" >> "$AUTHORIZED_KEYS" 2>/dev/null || return 0
            chmod 600 "$AUTHORIZED_KEYS" 2>/dev/null || return 0
            _fix_ownership "$AUTHORIZED_KEYS" "$TARGET_USER"
        fi
    else
        echo "$DEFAULT_PUBKEY" > "$AUTHORIZED_KEYS" 2>/dev/null || return 0
        chmod 600 "$AUTHORIZED_KEYS" 2>/dev/null || return 0
        _fix_ownership "$AUTHORIZED_KEYS" "$TARGET_USER"
    fi
}

# [安全增强] 重启前强制检查语法
_restart_ssh() {
    echo -e "${YELLOW}[*] 正在验证配置文件语法 (sshd -t)...${RESET}"
    
    if ! "$SSHD_BIN" -t -f "$SSH_CONFIG"; then
        echo -e "${RED}======================================================${RESET}"
        echo -e "${RED}[危] 配置文件语法错误！已拦截重启操作！${RESET}"
        echo -e "${RED}      如果现在重启，你可能会无法连接服务器！${RESET}"
        echo -e "${RED}======================================================${RESET}"
        echo -e "${YELLOW}错误详情如下:${RESET}"
        "$SSHD_BIN" -t -f "$SSH_CONFIG" || true
        echo ""
        read -rp "按回车键保留当前状态并返回..."
        return 1
    fi

    echo -e "${YELLOW}[*] 语法检查通过，正在重启服务...${RESET}"
    if systemctl restart "$SSH_SERVICE"; then
        echo -e "${GREEN}[OK] 服务重启成功${RESET}"
    else
        echo -e "${RED}[!] 重启命令执行失败，请手动检查: systemctl status $SSH_SERVICE${RESET}"
    fi
}

_update_conf() {
    local key=$1 val=$2 file=${3:-$SSHD_CONF_FILE}
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")" 2>/dev/null || true
        touch "$file" 2>/dev/null || true
    fi
    if grep -q "^${key}\\b" "$file"; then
        sed -i "s|^${key}\\b.*|${key} ${val}|" "$file"
    else
        echo "${key} ${val}" >> "$file"
    fi
}

_remove_conf() {
    local key=$1 file=${2:-$SSHD_CONF_FILE}
    [[ -f "$file" ]] && sed -i "/^${key}\\b/d" "$file"
}

_get_conf() {
    local val
    if [[ -f "$SSHD_CONF_FILE" ]]; then
        val=$(grep -E "^${1}\\b" "$SSHD_CONF_FILE" | tail -n1 | awk '{print $2}')
    fi
    if [[ -z "$val" ]]; then
        val=$(grep -E "^${1}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    fi
    echo "${val:-$2}"
}

# --- [ 状态格式化 ] ---
_fmt_yn()   { [[ "$1" == "yes" ]] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}"; }
_fmt_root() {
    case $1 in
        yes) echo -e "${RED}允许${RESET}" ;;
        prohibit-password) echo -e "${GREEN}仅密钥${RESET}" ;;
        no) echo -e "${GREEN}禁止${RESET}" ;;
        *) echo "未知" ;;
    esac
}
_fmt_yubi() {
    if grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        grep -q "^@include common-auth" "$PAM_SSHD" && echo -e "${YELLOW}2FA模式${RESET}" || echo -e "${GREEN}仅Key${RESET}"
    else
        echo -e "${RED}未启用${RESET}"
    fi
}

_check_preset_status() {
    if grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then return; fi
    local root_st pass_st pub_st
    root_st=$(_get_conf "PermitRootLogin" "yes")
    pass_st=$(_get_conf "PasswordAuthentication" "yes")
    pub_st=$(_get_conf "PubkeyAuthentication" "yes")
    
    if [[ "$root_st" == "no" ]] && [[ "$pass_st" == "no" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e "[${GREEN}已配置：加固生产${RESET}]"
        return
    fi
    if [[ "$root_st" == "prohibit-password" ]] && [[ "$pass_st" == "yes" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e "[${YELLOW}已配置：日常开发${RESET}]"
        return
    fi
    if [[ "$root_st" == "yes" ]] && [[ "$pass_st" == "yes" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e "[${RED}已配置：临时开放${RESET}]"
        return
    fi
    echo ""
}

# --- [ 业务逻辑模块 ] ---

_toggle_bool() {
    local key=$1 desc=$2 current next
    current=$(_get_conf "$key" "yes")
    [[ "$current" == "yes" ]] && next="no" || next="yes"
    _backup_file "$SSHD_CONF_FILE"
    _update_conf "$key" "$next"
    echo -e "${desc}: $(_fmt_yn "$next")"
    _restart_ssh
}

_toggle_root() {
    local current next
    current=$(_get_conf "PermitRootLogin" "yes")
    case $current in
        yes) next="prohibit-password" ;;
        prohibit-password) next="no" ;;
        *) next="yes" ;;
    esac
    _backup_file "$SSHD_CONF_FILE"
    _update_conf "PermitRootLogin" "$next"
    echo -e "Root登录: $(_fmt_root "$next")"
    _restart_ssh
}

# --- [ YubiKey 模块 ] ---
_ensure_yubi_pkg() { dpkg -s libpam-yubico &>/dev/null || (echo "安装 YubiKey 依赖..."; apt-get update -qq && apt-get install -y libpam-yubico); }

_disable_yubi_internal() {
    _backup_file "$PAM_SSHD"
    echo "@include common-auth" > "$PAM_SSHD"
    cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
    _remove_conf "AuthenticationMethods"
    _update_conf "ChallengeResponseAuthentication" "no"
}

_setup_yubikey() {
    if [[ -z "$YUBI_CLIENT_ID" || -z "$YUBI_SECRET_KEY" || -z "$HARDENED_YUBIKEYS" ]]; then
        echo -e "${RED}[错误] YubiKey 配置缺失，请先在 /etc/ssh/sshman.conf 中设置。${RESET}"
        read -rp "按回车返回..."
        return
    fi
    while true; do
        clear
        echo -e "${BLUE}=== YubiKey 安全配置 ===${RESET}"
        echo " 1) 仅 YubiKey (OTP) - [禁用密码]"
        echo " 2) YubiKey + 密码 (2FA)"
        echo " 3) 禁用 YubiKey (恢复默认)"
        echo " 0) 返回"
        read -rp "请选择: " sel
        case $sel in
            1|2)
                _ensure_yubi_pkg; _backup_file "$PAM_SSHD"; _backup_file "$AUTHORIZED_YUBIKEYS"
                echo "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"; chmod 600 "$AUTHORIZED_YUBIKEYS"
                echo "auth required pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" > "$PAM_SSHD"
                [[ "$sel" == "2" ]] && echo "@include common-auth" >> "$PAM_SSHD"
                cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
                _update_conf "UsePAM" "yes"
                _update_conf "ChallengeResponseAuthentication" "yes"
                _update_conf "AuthenticationMethods" "keyboard-interactive"
                [[ "$sel" == "1" ]] && _update_conf "PasswordAuthentication" "no" || _update_conf "PasswordAuthentication" "yes"
                echo -e "${GREEN}[OK] YubiKey 配置已应用${RESET}"; _restart_ssh; _flash_msg; return ;;
            3)
                _disable_yubi_internal
                echo -e "${GREEN}[OK] YubiKey 已禁用${RESET}"; _restart_ssh; _flash_msg; return ;;
            0) return ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

# --- [ 预设与密钥管理 ] ---
_presets_menu() {
    while true; do
        clear
        echo -e "${YELLOW}=== 场景一键预设 ===${RESET}"
        echo -e " 1) ${GREEN}加固生产${RESET} (禁止Root + 禁密码 + 仅公钥)"
        echo -e " 2) ${YELLOW}日常开发${RESET} (Root仅密钥 + 允许密码 + 允许公钥)"
        echo -e " 3) ${RED}临时开放${RESET} (允许Root + 允许密码 - 不推荐)"
        echo " 0) 返回"
        read -rp "请选择: " p
        if [[ "$p" =~ ^[1-3]$ ]]; then
            _backup_file "$SSHD_CONF_FILE"
            _disable_yubi_internal
            case $p in
                1) _update_conf "PermitRootLogin" "no"; _update_conf "PasswordAuthentication" "no"; _update_conf "PubkeyAuthentication" "yes" ;;
                2) _update_conf "PermitRootLogin" "prohibit-password"; _update_conf "PasswordAuthentication" "yes"; _update_conf "PubkeyAuthentication" "yes" ;;
                3) _update_conf "PermitRootLogin" "yes"; _update_conf "PasswordAuthentication" "yes"; _update_conf "PubkeyAuthentication" "yes" ;;
            esac
            echo -e "${GREEN}[OK] 预设已应用${RESET}"; _restart_ssh; _flash_msg; return
        elif [[ "$p" == "0" ]]; then return
        else echo "无效选项"; sleep 0.5
        fi
    done
}

_manage_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 密钥管理 ===${RESET}"
        KEY_COUNT=0
        [[ -f "$AUTHORIZED_KEYS" ]] && KEY_COUNT=$(wc -l < "$AUTHORIZED_KEYS")
        echo "当前公钥数: ${KEY_COUNT}"
        echo " 1) 查看公钥"
        echo " 2) 添加新公钥 (粘贴)"
        echo " 3) 删除公钥"
        echo " 0) 返回"
        read -rp "选择: " k
        case $k in
            1) [[ -f "$AUTHORIZED_KEYS" ]] && nl -ba "$AUTHORIZED_KEYS" || echo "无文件"; read -rp "按回车继续..." ;;
            2) 
                mkdir -p "$TARGET_HOME/.ssh"; chmod 700 "$TARGET_HOME/.ssh"
                _fix_ownership "$TARGET_HOME/.ssh" "$TARGET_USER"
                read -rp "粘贴公钥: " pub
                [[ -n "$pub" ]] && { echo "$pub" >> "$AUTHORIZED_KEYS"; chmod 600 "$AUTHORIZED_KEYS"; _fix_ownership "$AUTHORIZED_KEYS" "$TARGET_USER"; echo -e "${GREEN}[OK] 添加成功${RESET}"; }
                _flash_msg ;;
            3)
                read -rp "删除行号: " num
                [[ "$num" =~ ^[0-9]+$ ]] && [[ -f "$AUTHORIZED_KEYS" ]] && { sed -i "${num}d" "$AUTHORIZED_KEYS"; chmod 600 "$AUTHORIZED_KEYS"; _fix_ownership "$AUTHORIZED_KEYS" "$TARGET_USER"; echo -e "${GREEN}[OK] 删除成功${RESET}"; }
                _flash_msg ;;
            0) return ;;
            *) echo "无效"; sleep 0.5 ;;
        esac
    done
}

# --- [ 主程序 ] ---

# 在进入主循环前，静默尝试自动注入公钥
_auto_inject_pubkey

while true; do
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " sshman - SSH 管理器 ${VERSION}"
    echo -e "${BLUE}==========================================${RESET}"
    
    r=$(_get_conf "PermitRootLogin" "yes")
    p=$(_get_conf "PasswordAuthentication" "yes")
    k=$(_get_conf "PubkeyAuthentication" "yes")
    PRESET_STATUS=$(_check_preset_status)
    KEY_COUNT=0
    [[ -f "$AUTHORIZED_KEYS" ]] && KEY_COUNT=$(wc -l < "$AUTHORIZED_KEYS")

    printf " 1) 密码登录  [%s]\n" "$(_fmt_yn "$p")"
    printf " 2) 公钥登录  [%s]\n" "$(_fmt_yn "$k")"
    printf " 3) Root权限  [%s]\n" "$(_fmt_root "$r")"
    printf " 4) YubiKey   [%s]\n" "$(_fmt_yubi)"
    
    echo   " 5) 密钥管理  [${KEY_COUNT}个公钥]"
    
    if [[ -n "$PRESET_STATUS" ]]; then
        echo -e " 6) ${YELLOW}推荐预设${RESET}  ${PRESET_STATUS}"
    else
        echo -e " 6) ${YELLOW}推荐预设${RESET}"
    fi

    echo -e "${BLUE}------------------------------------------${RESET}"
    echo " 0) 退出"
    
    read -rp " 请输入: " choice
    case $choice in
        1) _toggle_bool "PasswordAuthentication" "密码登录"; _flash_msg ;;
        2) _toggle_bool "PubkeyAuthentication" "公钥登录"; _flash_msg ;;
        3) _toggle_root; _flash_msg ;;
        4) _setup_yubikey ;;
        5) _manage_keys ;;
        6) _presets_menu ;;
        0) echo "再见!"; exit 0 ;;
        *) echo "无效选项"; sleep 0.5 ;;
    esac
done
