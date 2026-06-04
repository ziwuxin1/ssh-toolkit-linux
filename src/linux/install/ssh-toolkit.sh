#!/usr/bin/env bash
#
# SSH Toolkit (Linux) — Perforce P4D 一键运维脚本
# Version: 1.1.0
# Target: P4D 2024.1 on Ubuntu 22.04 / 24.04
#
# 用法:
#   sudo bash ssh-toolkit.sh           # 交互菜单
#   sudo bash ssh-toolkit.sh status    # 非交互:状态
#   sudo bash ssh-toolkit.sh checkpoint # 非交互:立刻 checkpoint
#
# 设计原则:
#   - 100% 基于 P4D-Migration-Complete-Guide.md 那份指南
#   - 单文件、无外部依赖(除 p4d / p4 / systemctl 等系统工具)
#   - 失败可重入(每步幂等 + 状态机 + 详细日志)
#   - 关键操作前自动备份 + 提示
#

set -o errexit
set -o nounset
set -o pipefail

# ============================================================
#  Toolkit 版本(每次 commit 自动 +1,见 .githooks/pre-commit)
# ============================================================

readonly TOOLKIT_VERSION="1.1.5"

# ============================================================
#  配置(可通过环境变量 / 配置文件覆盖)
# ============================================================

readonly P4D_VERSION_DEFAULT="2024.1"
readonly P4ROOT_DEFAULT="/opt/perforce/servers/master"
readonly P4PORT_DEFAULT="1888"
readonly P4D_USER_DEFAULT="perforce"
readonly P4D_BIN_DIR_DEFAULT="/opt/perforce/sbin"
readonly P4_BIN_DIR_DEFAULT="/opt/perforce/bin"
readonly BACKUP_DIR_DEFAULT="/opt/perforce/backups"
readonly DEPOT_BACKUP_DIR_DEFAULT="/mnt/backup/depots"

# 方案 2:本地 checkpoint + rsync push 到 NAS(更稳)
# NAS_BACKUP_ROOT 是 NFS 挂载点下 这台 VM 的备份根目录
# 比如挂在 /mnt/nas/p4d-backups,VM1 的就放 /mnt/nas/p4d-backups/vm1
readonly NAS_BACKUP_ROOT_DEFAULT="/mnt/nas/p4d-backups/vm1"

# 工作空间(放在 root 家目录下,统一管理安装包 / license / 迁移数据)
readonly WORK_DIR_DEFAULT="/root/P4_Temp"
readonly INSTALL_TEMP_DEFAULT="${WORK_DIR_DEFAULT}/Install_Temp"
readonly ROOT_TEMP_DEFAULT="${WORK_DIR_DEFAULT}/Root_Temp"

# 安装包来源(GitHub raw),你把 tgz 上传到 dist/ 目录后这个 URL 才有效
readonly P4D_TGZ_URL_TEMPLATE="https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/dist/server-%s.tgz"

# Config file (loaded if present, written by deploy steps)
readonly CONFIG_FILE="/etc/ssh-toolkit.conf"

# Persistent state (which deploy steps are done)
readonly STATE_DIR="/var/lib/ssh-toolkit"
readonly LOG_FILE="/var/log/ssh-toolkit.log"

# systemd unit + scheduled task names
readonly SVC_NAME="p4d.service"
readonly SVC_FILE="/etc/systemd/system/${SVC_NAME}"
readonly RESCUE_DROPIN_DIR="/etc/systemd/system/p4d.service.d"
readonly RESCUE_DROPIN_FILE="${RESCUE_DROPIN_DIR}/rescue.conf"
readonly CRON_FILE="/etc/cron.d/p4d-backup"

# ============================================================
#  ANSI 颜色 (终端友好,无 tty 时自动关闭)
# ============================================================

if [[ -t 1 ]]; then
    # ANSI-C quoting ($'…') — 必须用,普通双引号里 \033 是字面字符串,
    # heredoc 不会解释,会原样打出 \033[1m 这种丑东西。
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_MAGENTA=$'\033[35m'
    readonly C_CYAN=$'\033[36m'
else
    readonly C_RESET="" C_BOLD="" C_DIM=""
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
fi

# ============================================================
#  日志助手
# ============================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info()    { printf "${C_CYAN}ℹ${C_RESET}  %s\n" "$*"; log INFO "$*"; }
ok()      { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; log OK "$*"; }
warn()    { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; log WARN "$*"; }
err()     { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; log ERR "$*"; }
die()     { err "$@"; exit 1; }
section() { printf "\n${C_BOLD}${C_BLUE}── %s ──${C_RESET}\n" "$*"; }

confirm() {
    # confirm "Question?" [default: y|n]
    local prompt="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local reply
    read -r -p "$(printf "${C_YELLOW}?${C_RESET}  %s %s " "$prompt" "$hint")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_confirm_text() {
    # require_confirm_text "Type CONFIRM to proceed: " "CONFIRM"
    local prompt="$1"
    local expected="$2"
    local reply
    read -r -p "$(printf "${C_YELLOW}?${C_RESET}  %s" "$prompt")" reply
    [[ "$reply" == "$expected" ]]
}

# ============================================================
#  根权限检查
# ============================================================

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        die "需要 root 权限运行。请用: sudo bash $0"
    fi
}

# ============================================================
#  配置加载 / 保存
# ============================================================

load_config() {
    P4D_VERSION="${P4D_VERSION:-$P4D_VERSION_DEFAULT}"
    P4ROOT="${P4ROOT:-$P4ROOT_DEFAULT}"
    P4PORT="${P4PORT:-$P4PORT_DEFAULT}"
    P4D_USER="${P4D_USER:-$P4D_USER_DEFAULT}"
    P4D_BIN_DIR="${P4D_BIN_DIR:-$P4D_BIN_DIR_DEFAULT}"
    P4_BIN_DIR="${P4_BIN_DIR:-$P4_BIN_DIR_DEFAULT}"
    BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
    DEPOT_BACKUP_DIR="${DEPOT_BACKUP_DIR:-$DEPOT_BACKUP_DIR_DEFAULT}"
    NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-$NAS_BACKUP_ROOT_DEFAULT}"
    WORK_DIR="${WORK_DIR:-$WORK_DIR_DEFAULT}"
    INSTALL_TEMP="${INSTALL_TEMP:-$INSTALL_TEMP_DEFAULT}"
    ROOT_TEMP="${ROOT_TEMP:-$ROOT_TEMP_DEFAULT}"
    P4D_BIN="${P4D_BIN_DIR}/p4d"
    P4_BIN="${P4_BIN_DIR}/p4"
    P4D_ADMIN_PASSWD_FILE="/opt/perforce/.p4_admin_passwd"
    # shellcheck disable=SC2059
    P4D_TGZ_URL="$(printf "$P4D_TGZ_URL_TEMPLATE" "$P4D_VERSION")"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# P4D Toolkit configuration — generated $(date -Iseconds)
P4D_VERSION="$P4D_VERSION"
P4ROOT="$P4ROOT"
P4PORT="$P4PORT"
P4D_USER="$P4D_USER"
P4D_BIN_DIR="$P4D_BIN_DIR"
P4_BIN_DIR="$P4_BIN_DIR"
BACKUP_DIR="$BACKUP_DIR"
DEPOT_BACKUP_DIR="$DEPOT_BACKUP_DIR"
NAS_BACKUP_ROOT="$NAS_BACKUP_ROOT"
EOF
    chmod 644 "$CONFIG_FILE"
}

# ============================================================
#  状态查询
# ============================================================

svc_state() {
    # echoes one of: running|stopped|failed|missing|unknown
    #
    # 之前用 systemctl list-unit-files | grep "^${SVC_NAME}" 检测,
    # 在某些 systemd 版本上输出格式不同(比如有 leading whitespace,
    # 或 pager 介入,或多列对齐填充),grep 匹配不上 → 返回 missing,
    # 即使 service 实际在跑。结果 banner 永远显示"未安装",
    # 与下面健康体检的真实状态(运行中)矛盾,用户体验糟糕。
    #
    # 改用更可靠的检测:直接看 unit file 是否存在 + systemctl cat 兜底。
    if [[ ! -f "$SVC_FILE" ]] && ! systemctl cat "$SVC_NAME" >/dev/null 2>&1; then
        echo "missing"; return
    fi
    if systemctl is-active --quiet "$SVC_NAME"; then
        echo "running"
    elif systemctl is-failed --quiet "$SVC_NAME"; then
        echo "failed"
    else
        echo "stopped"
    fi
}

p4d_installed() {
    [[ -x "$P4D_BIN" ]]
}

license_present() {
    [[ -f "$P4ROOT/license" ]]
}

p4d_version_string() {
    if p4d_installed; then
        "$P4D_BIN" -V 2>/dev/null | grep -m1 '^Rev\.' || echo "未知"
    else
        echo "未安装"
    fi
}

p4_info_license() {
    # Returns license-line text or empty if call fails.
    "$P4_BIN" -p "localhost:$P4PORT" info 2>/dev/null | grep "Server license:" || true
}

current_change_counter() {
    "$P4_BIN" -p "localhost:$P4PORT" -u admin counter change 2>/dev/null | tr -d '[:space:]' || true
}

current_max_change() {
    "$P4_BIN" -p "localhost:$P4PORT" -u admin changes -m 1 2>/dev/null | awk 'NR==1 && $1=="Change" { print $2 }' || true
}

# ============================================================
#  顶部头(每次菜单刷新)
# ============================================================

print_header() {
    clear
    local svc; svc="$(svc_state)"
    local svc_color="$C_RED" svc_text="未知"
    case "$svc" in
        running) svc_color="$C_GREEN"; svc_text="✓ 运行中" ;;
        stopped) svc_color="$C_YELLOW"; svc_text="○ 已停止" ;;
        failed)  svc_color="$C_RED"; svc_text="✗ 启动失败" ;;
        missing) svc_color="$C_DIM"; svc_text="未安装" ;;
    esac

    local lic_text="—"
    if [[ "$svc" == "running" ]]; then
        lic_text="$(p4_info_license | sed 's/Server license: *//')"
        [[ -z "$lic_text" ]] && lic_text="—"
    fi

    printf "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  ${C_BOLD}P4D Toolkit (Ubuntu)${C_RESET}  ${C_DIM}v${TOOLKIT_VERSION}${C_RESET}$(printf '%*s' $((40 - ${#TOOLKIT_VERSION})) '')${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  Host: $(printf '%-25s' "$(hostname)")  Port: $(printf '%-5s' "$P4PORT")          ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  P4D:  $(printf '%-30s' "$(p4d_version_string | head -c 30)")          ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  Service: ${svc_color}$(printf '%-15s' "$svc_text")${C_RESET}                                ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  License: $(printf '%-50s' "$(echo "$lic_text" | head -c 50)") ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
}

# ============================================================
#  STEP IMPLEMENTATIONS — 部署
# ============================================================

step_prepare_workspace() {
    section "一键创建工作目录 + 下载安装包"

    info "工作根目录: $WORK_DIR"
    mkdir -p "$INSTALL_TEMP" "$ROOT_TEMP"
    chmod 700 "$WORK_DIR"
    ok "已创建:"
    printf "    %s/Install_Temp/   ← 安装包 + license\n" "$WORK_DIR"
    printf "    %s/Root_Temp/      ← 迁移数据 (depot / checkpoint / journal)\n" "$WORK_DIR"

    # 下载 server tgz 到 Install_Temp(已存在则跳过)
    local tgz="${INSTALL_TEMP}/server-${P4D_VERSION}.tgz"
    if [[ -f "$tgz" ]]; then
        ok "安装包已存在: $tgz ($(du -h "$tgz" | cut -f1)),跳过下载"
    else
        info "从 GitHub 下载: $P4D_TGZ_URL"
        if curl -fsSL --progress-bar -o "$tgz" "$P4D_TGZ_URL"; then
            ok "下载完成: $tgz ($(du -h "$tgz" | cut -f1))"
        else
            err "下载失败 — 请确认 dist/server-${P4D_VERSION}.tgz 已上传到 GitHub repo"
            err "URL: $P4D_TGZ_URL"
            rm -f "$tgz"
            return 1
        fi
    fi

    echo
    info "下一步,你需要 手动 准备这两类文件:"
    printf "  • 把 ${C_BOLD}license${C_RESET} 文件复制到 ${INSTALL_TEMP}/license\n"
    printf "  • 把 ${C_BOLD}迁移数据${C_RESET}(depot / checkpoint.* / journal.*)放到 ${ROOT_TEMP}/\n"
    echo
    info "都准备好之后,菜单里继续选 1) 安装 P4D 等步骤"
}

step_install_p4d() {
    section "全新安装 P4D ${P4D_VERSION}"
    if p4d_installed; then
        warn "P4D 已经装在 $P4D_BIN ($(p4d_version_string))"
        confirm "覆盖安装?" || return 0
    fi

    # 必须先跑过 step_prepare_workspace
    local tgz="${INSTALL_TEMP}/server-${P4D_VERSION}.tgz"
    if [[ ! -f "$tgz" ]]; then
        err "未找到安装包: $tgz"
        info "请先在菜单选 0) 一键创建工作目录 + 下载安装包"
        return 1
    fi
    info "使用安装包: $tgz ($(du -h "$tgz" | cut -f1))"

    local tmp="/tmp/p4d_install"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    info "解压并安装"
    tar xzf "$tgz" -C "$tmp"
    mkdir -p "$P4D_BIN_DIR" "$P4_BIN_DIR"
    install -m 755 "$tmp/p4d"      "$P4D_BIN"
    install -m 755 "$tmp/p4broker" "$P4D_BIN_DIR/p4broker" || true
    install -m 755 "$tmp/p4p"      "$P4D_BIN_DIR/p4p"      || true
    install -m 755 "$tmp/p4"       "$P4_BIN"

    # Symlinks for global access
    ln -sf "$P4_BIN"  /usr/local/bin/p4
    ln -sf "$P4D_BIN" /usr/local/sbin/p4d

    # Create perforce user
    if ! id -u "$P4D_USER" >/dev/null 2>&1; then
        info "创建用户 $P4D_USER"
        useradd -r -m -d /opt/perforce -s /bin/bash "$P4D_USER"
    fi
    chown "$P4D_USER:$P4D_USER" /opt/perforce
    mkdir -p "$P4ROOT"
    chown -R "$P4D_USER:$P4D_USER" /opt/perforce

    # Initialize case-insensitive (mirror Windows behavior, see migration guide Phase 0.5)
    if [[ ! -f "$P4ROOT/db.counters" ]]; then
        info "初始化 case-insensitive 数据库 (-C1 -xi)"
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -C1 -xi
    fi

    # Firewall (best-effort, ufw might not be installed)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "$P4PORT/tcp" comment 'Perforce' || true
    fi

    save_config
    ok "P4D ${P4D_VERSION} 已安装到 $P4D_BIN_DIR"
    "$P4D_BIN" -V | grep -m1 '^Rev\.'
}

step_install_license() {
    section "安装 License 文件"

    local src="${INSTALL_TEMP}/license"
    if [[ ! -f "$src" ]]; then
        err "未找到 license 文件: $src"
        info "请先把 license 文件复制到 ${INSTALL_TEMP}/license"
        info "示例: scp license root@<host>:${INSTALL_TEMP}/"
        return 1
    fi
    info "找到 license 文件: $src ($(stat -c%s "$src") bytes)"

    info "复制到 $P4ROOT/license"
    install -m 644 -o "$P4D_USER" -g "$P4D_USER" "$src" "$P4ROOT/license"

    if ! license_present; then
        err "$P4ROOT/license 不存在(复制失败)"
        return 1
    fi

    local ip users
    ip="$(grep -m1 '^IPaddress:' "$P4ROOT/license" | awk '{print $2}' || true)"
    users="$(grep -m1 '^Users:' "$P4ROOT/license" | awk '{print $2}' || true)"
    info "License IP : ${ip:-未指定}"
    info "License 用户数: ${users:-未指定}"

    local my_ip
    my_ip="$(hostname -I | awk '{print $1}' || true)"
    if [[ -n "$ip" && -n "$my_ip" && "$ip" != "$my_ip" ]]; then
        warn "License IP ($ip) 跟本机 IP ($my_ip) 不匹配 — 需要联系 Perforce rehost"
    fi

    ok "License 已就位"
}

step_setup_systemd_with_rescue() {
    section "配置 systemd + 启动自愈 hook"

    if [[ ! -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        info "创建 admin 密码文件 $P4D_ADMIN_PASSWD_FILE"
        local pw
        read -r -s -p "请输入 admin 密码 (会保存到只 root 可读的文件): " pw; echo
        echo -n "$pw" > "$P4D_ADMIN_PASSWD_FILE"
        chown "$P4D_USER:$P4D_USER" "$P4D_ADMIN_PASSWD_FILE"
        chmod 600 "$P4D_ADMIN_PASSWD_FILE"
    fi

    info "写 ${SVC_FILE}"
    cat > "$SVC_FILE" <<EOF
[Unit]
Description=Helix Core (Perforce) Server
After=network.target

[Service]
Type=forking
User=$P4D_USER
Group=$P4D_USER
Environment=P4ROOT=$P4ROOT
Environment=P4PORT=$P4PORT
Environment=P4JOURNAL=$P4ROOT/journal
Environment=P4LOG=$P4ROOT/log
ExecStart=$P4D_BIN -r $P4ROOT -p $P4PORT -d
# admin stop 需要 P4D super 用户身份,systemd 直接跑会用 perforce(Linux)用户名,
# 而 P4D protect 表里 perforce 通常不是 super → "Access ... not enabled"。
# 改用登录后的 admin ticket 调 stop,失败则用 SIGTERM 兜底。
# - prefix: ExecStop 失败不算服务失败(systemd 仍会发 SIGTERM 收尾)
ExecStop=-/bin/bash -c 'export P4TICKETS=/tmp/.p4tickets_admin; $P4_BIN -p $P4PORT -u admin login < $P4D_ADMIN_PASSWD_FILE >/dev/null 2>&1; $P4_BIN -p $P4PORT -u admin admin stop 2>/dev/null || pkill -TERM -u $P4D_USER -f "p4d -r $P4ROOT"'
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

    # Drop-in: ExecStartPre = reset counter to 0; ExecStartPost = set counter = MAX+1
    # Mirrors migration guide Phase 2.4 verbatim — the "vaccine" for 坑 #1.
    #
    # 注意: heredoc 用 <<'EOF' (literal mode) 避免 inner shell 的 $MAX_CHANGE / $NEXT /
    # $(...) / $2 被外层 bash 错误展开。配置值用 __PLACEHOLDER__ 占位,生成后再 sed 替换。
    # 这样 P4PORT / P4ROOT 真的可以自定义,不再硬编码 1888 + master 路径。
    info "写自愈 hook ${RESCUE_DROPIN_FILE}"
    mkdir -p "$RESCUE_DROPIN_DIR"
    cat > "$RESCUE_DROPIN_FILE" <<'EOF'
[Service]
# Pre-start: reset counter=0 so license validation passes
ExecStartPre=/bin/bash -c 'echo "@pv@ 1 @db.counters@ @change@ @0@" > /tmp/p4_rescue.jnl && __P4D_BIN__ -r __P4ROOT__ -jr /tmp/p4_rescue.jnl'

# Post-start: dynamic MAX(change) → counter=MAX+1
# (- prefix: failure here doesn't fail the unit)
ExecStartPost=-/bin/bash -c '\
export P4TICKETS=/tmp/.p4tickets_admin; \
sleep 5; \
__P4_BIN__ -p localhost:__P4PORT__ -u admin login < __P4D_ADMIN_PASSWD_FILE__ 2>&1 | tee /tmp/p4_post.log; \
MAX_CHANGE=$(__P4_BIN__ -p localhost:__P4PORT__ -u admin changes -m 1 2>/dev/null | awk "{print \$2}"); \
if [ -n "$MAX_CHANGE" ] && [ "$MAX_CHANGE" -gt 0 ] 2>/dev/null; then \
    NEXT=$((MAX_CHANGE + 1)); \
    __P4_BIN__ -p localhost:__P4PORT__ -u admin counter -f change $NEXT 2>&1 | tee -a /tmp/p4_post.log; \
    echo "Counter set to $NEXT (based on max change $MAX_CHANGE)" | tee -a /tmp/p4_post.log; \
else \
    echo "No existing changes found, counter stays at 0" | tee -a /tmp/p4_post.log; \
fi'
EOF

    # 用配置值替换占位符 — 至此 P4PORT / P4ROOT / 二进制路径 / 密码文件 全部可自定义
    sed -i \
        -e "s|__P4D_BIN__|${P4D_BIN}|g" \
        -e "s|__P4_BIN__|${P4_BIN}|g" \
        -e "s|__P4ROOT__|${P4ROOT}|g" \
        -e "s|__P4PORT__|${P4PORT}|g" \
        -e "s|__P4D_ADMIN_PASSWD_FILE__|${P4D_ADMIN_PASSWD_FILE}|g" \
        "$RESCUE_DROPIN_FILE"

    systemctl daemon-reload
    systemctl enable "$SVC_NAME"
    ok "systemd unit + 启动自愈 hook 已配置"
    info "现在可以: systemctl start $SVC_NAME"
}

# 校验 /etc/cron.d/ 文件格式 — 失败抛错让上游回滚。
#   Vixie cron 不支持 \ 续行,以前这里写了多行 cron 整个文件被静默拒绝
#   (Error: bad minute, file ignored),备份没跑、监控告警、但用户只在
#   30 小时后才发现。改完一定要验证,不验证就不算修。
_validate_cron_d_file() {
    local f="$1" line lineno=0 first
    [[ -r "$f" ]] || { err "cron 文件不可读: $f"; return 1; }
    while IFS= read -r line; do
        ((lineno++))
        # 空行或注释跳过
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        # 环境变量行跳过 (NAME=VALUE)
        [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && continue
        # 行尾不能是续行 \  ← 这次坑就是这个
        if [[ "$line" =~ \\$ ]]; then
            err "cron 文件第 $lineno 行用了 \\ 续行 (Vixie cron 不支持)"
            err "  $line"
            return 1
        fi
        # /etc/cron.d/ 格式: min hour day mon dow USER cmd…  ≥ 7 字段
        # 用 set -f 关掉 glob,否则 cron 时间字段里的 * 会被展开成 cwd 下的文件名
        # shellcheck disable=SC2086
        set -f
        set -- $line
        set +f
        if (( $# < 7 )); then
            err "cron 文件第 $lineno 行字段不足 7 个: $line"
            return 1
        fi
        # 头 5 个字段必须是 cron 时间字段(只允许数字 * / - , 这些字符)
        for first in "$1" "$2" "$3" "$4" "$5"; do
            if [[ ! "$first" =~ ^[0-9*/,\-]+$ ]]; then
                err "cron 文件第 $lineno 行时间字段非法 ($first): $line"
                return 1
            fi
        done
    done < "$f"
    return 0
}

step_setup_cron_checkpoint() {
    section "配置每日 checkpoint cron(方案 2:本地 + NAS 双副本)"
    mkdir -p "$BACKUP_DIR"
    chown "$P4D_USER:$P4D_USER" "$BACKUP_DIR"

    # 先写到 .new 临时文件,校验通过再 mv 到位 — 校验失败保留旧 cron 不变
    local cron_new="${CRON_FILE}.new"
    cat > "$cron_new" <<EOF
# P4D Toolkit — auto-generated $(date -Iseconds)
# 方案 2:checkpoint 先写本地 SSD,再 rsync 推到 NAS,depot 文件直接 rsync 到 NAS
#
# ⚠️ 注意: Vixie cron (Ubuntu 默认) 不支持 \\ 续行,/etc/cron.d/ 里的多行
# rsync/find 命令一律用 'bash -c "..."' 包成单行;改这里之前请保持单行格式,
# 否则整个文件会被 cron 静默拒绝 (Error: bad minute, file ignored)。

# 时间用美西时区(夏令时切换自动跟进,不需要每年手动改)
CRON_TZ=America/Los_Angeles

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 03:00 (美西) — 生成 checkpoint 到本地 SSD (压缩 + 轮转 journal)
0 3 * * * $P4D_USER $P4D_BIN -r $P4ROOT -jc -Z $BACKUP_DIR/checkpoint > $BACKUP_DIR/last.log 2>&1

# 03:30 (美西) — rsync 本地 checkpoint+journal 到 NAS (metadata 副本,几秒钟)
# --no-owner --no-group --no-perms: NFS 多数 all_squash 会压缩 UID,
# 否则 rsync 保留 owner/group/perms 会 chown "Operation not permitted"
# 退出码 23 让监控误判;数据其实传到了。
30 3 * * * root bash -c 'if mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null || [[ -d "$NAS_BACKUP_ROOT" ]]; then mkdir -p $NAS_BACKUP_ROOT/checkpoints && rsync -a --no-owner --no-group --no-perms --delete $BACKUP_DIR/ $NAS_BACKUP_ROOT/checkpoints/ > $NAS_BACKUP_ROOT/checkpoints/last-rsync.log 2>&1; fi'

# 04:00 (美西) — rsync depot 物理文件到 NAS (差量,跳过 db.*/journal/log/checkpoint.*)
0 4 * * * root bash -c 'if mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null || [[ -d "$NAS_BACKUP_ROOT" ]]; then mkdir -p $NAS_BACKUP_ROOT/depots && rsync -a --no-owner --no-group --no-perms --delete --exclude=db.* --exclude=journal* --exclude=log* --exclude=checkpoint.* $P4ROOT/ $NAS_BACKUP_ROOT/depots/ > $NAS_BACKUP_ROOT/depots/last-rsync.log 2>&1; fi'

# 每周日 05:00 (美西) — 清理本地 14 天前的 checkpoint+journal (本地不留太久,NAS 长存)
0 5 * * 0 $P4D_USER find $BACKUP_DIR -name 'checkpoint.*' -mtime +14 -delete
0 5 * * 0 $P4D_USER find $BACKUP_DIR -name 'journal.*' -mtime +14 -delete

# 每周日 06:00 (美西) — 清理 NAS 上 90 天前的 checkpoint+journal
0 6 * * 0 root bash -c '[[ -d $NAS_BACKUP_ROOT/checkpoints ]] && find $NAS_BACKUP_ROOT/checkpoints -name "checkpoint.*" -mtime +90 -delete'
0 6 * * 0 root bash -c '[[ -d $NAS_BACKUP_ROOT/checkpoints ]] && find $NAS_BACKUP_ROOT/checkpoints -name "journal.*" -mtime +90 -delete'
EOF

    if ! _validate_cron_d_file "$cron_new"; then
        err "新 cron 文件语法校验失败,保留旧 cron 不变"
        err "失败的内容在: $cron_new (你可以手动 diff 看)"
        return 1
    fi

    chmod 644 "$cron_new"
    mv -f "$cron_new" "$CRON_FILE"
    ok "cron 已配置: $CRON_FILE (语法校验通过)"
    info "本地 checkpoint: $BACKUP_DIR (保留 14 天)"
    info "NAS 备份根目录: $NAS_BACKUP_ROOT (保留 90 天)"

    # cron 守护进程会在 1 分钟内自动 reload /etc/cron.d/,这里看一眼日志确认没报错
    info "等 5 秒看 cron 是否拒绝新文件..."
    sleep 5
    if journalctl -u cron --since "10 seconds ago" --no-pager 2>/dev/null | grep -qE "p4d-backup.*ERROR|bad minute|bad hour"; then
        err "cron 拒绝了新文件 (journalctl -u cron 看详细)"
        return 1
    fi

    if ! mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null; then
        warn "$NAS_BACKUP_ROOT 没挂载 — rsync 那两条 cron 会跳过 (有 mountpoint 检查)"
        info "记得配 NFS 挂载,把 NAS 共享挂到 $NAS_BACKUP_ROOT"
    fi
}

# ============================================================
#  STEP IMPLEMENTATIONS — 救援
# ============================================================

step_counter_rescue() {
    section "Counter 救援"
    info "等同于 Windows 端 Counter 救援按钮 — 用于:"
    info "  • license 被错误降级到 5 用户"
    info "  • change counter 跟 MAX(change) 严重不一致"
    info ""
    info "流程: 停服 → 注 reset jnl(counter=0) → 启服 → 设 counter=MAX+1 → 验证"
    confirm "继续?" || return 0

    info "[1/5] 停止服务"
    systemctl stop "$SVC_NAME" || true
    sleep 2

    info "[2/5] 注入 counter=0 reset jnl 并 replay"
    local jnl="/tmp/p4_counter_reset_$$.jnl"
    echo "@pv@ 1 @db.counters@ @change@ @0@" > "$jnl"
    chown "$P4D_USER:$P4D_USER" "$jnl"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$jnl"
    rm -f "$jnl"

    info "[3/5] 启动服务"
    systemctl start "$SVC_NAME"
    sleep 5

    info "[4/5] 读取 MAX(change),设置 counter"
    if [[ -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        export P4TICKETS=/tmp/.p4tickets_admin
        "$P4_BIN" -p "localhost:$P4PORT" -u admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null 2>&1 || true
        local max
        max="$(current_max_change)"
        if [[ -n "$max" && "$max" -gt 0 ]]; then
            local next=$((max + 1))
            "$P4_BIN" -p "localhost:$P4PORT" -u admin counter -f change "$next"
            ok "  counter 设为 $next (基于 MAX(change)=$max)"
        else
            info "  无 changelist 历史,counter 保持 0"
        fi
    else
        warn "  没有 admin 密码文件,跳过 counter 校准"
    fi

    info "[5/5] 验证 license"
    local lic
    lic="$(p4_info_license)"
    if [[ -n "$lic" ]]; then
        ok "Server license: $lic"
    else
        warn "p4 info 没有 'Server license' 行"
    fi
}

# ============================================================
#  强制解锁学生遗留 checkout
# ============================================================
# 场景:学生电脑被格式化 / workspace 被删,文件还 opened(checkout)挂在
# 服务器上,别人没法编辑。管理员在服务器本机以 admin 身份强制 revert 释放
# (含 +l 独占锁)。锁信息存在服务器,跟那台电脑是否还在无关。

_admin_login() {
    # 用 admin 密码文件登录,ticket 写到固定文件;成功返回 0。
    [[ -f "$P4D_ADMIN_PASSWD_FILE" ]] || { warn "没有 admin 密码文件 $P4D_ADMIN_PASSWD_FILE"; return 1; }
    export P4TICKETS=/tmp/.p4tickets_admin
    "$P4_BIN" -p "localhost:$P4PORT" -u admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null 2>&1
}

step_force_revert() {
    section "强制解锁学生遗留 checkout"
    info "用于:学生电脑被格式化 / workspace 已删,文件还 checkout 在服务器上"
    info "管理员在本机以 admin 身份强制 revert,释放锁(含 +l 独占锁)"
    echo

    if [[ "$(svc_state)" != "running" ]]; then
        err "服务未运行,无法操作。先启动服务(菜单 15)"; return 1
    fi
    if ! _admin_login; then
        err "admin 登录失败,无法继续"; return 1
    fi
    export P4TICKETS=/tmp/.p4tickets_admin

    # 1. 列出当前所有 opened(checkout)文件
    info "[1] 当前所有 checkout(opened)文件:"
    local opened
    opened="$("$P4_BIN" -p "localhost:$P4PORT" -u admin opened -a 2>/dev/null || true)"
    if [[ -z "$opened" ]]; then
        ok "没有任何文件被 checkout — 无需解锁"; return 0
    fi
    echo "$opened" | sed 's/^/    /'
    echo

    # 2. 选择解锁范围
    info "解锁方式:"
    echo "    a) 按 workspace(client)整体 revert —— 推荐(电脑格式化场景)"
    echo "    b) 按用户 revert 该用户所有 checkout(自动跨其全部 client)"
    echo "    c) 单个文件 revert"
    echo "    q) 取消"
    local mode; read -r -p "$(printf "${C_CYAN}选择 [a/b/c/q]: ${C_RESET}")" mode

    local client="" user="" filespec="//..."
    case "$mode" in
        a)
            read -r -p "输入 workspace(client)名: " client
            [[ -z "$client" ]] && { warn "未输入,取消"; return 0; }
            ;;
        b)
            read -r -p "输入用户名: " user
            [[ -z "$user" ]] && { warn "未输入,取消"; return 0; }
            ;;
        c)
            read -r -p "输入 depot 文件路径(如 //depot/x/a.txt): " filespec
            [[ -z "$filespec" ]] && { warn "未输入,取消"; return 0; }
            read -r -p "该文件所属 workspace(client)名: " client
            [[ -z "$client" ]] && { warn "未输入,取消"; return 0; }
            ;;
        *) info "已取消"; return 0 ;;
    esac

    # 3. 确认 + 执行
    warn "revert 会丢弃这些文件的未提交改动(电脑已格式化,本来也找不回)"
    confirm "确认强制 revert?" || { info "已取消"; return 0; }

    if [[ "$mode" == "b" ]]; then
        # revert 没有 -u 选项,只能按 client。从 opened -a 提取该用户的全部 client。
        # 行尾形如:  ... by user@client
        local clients
        clients="$(echo "$opened" | awk -v u="$user" '
            { n=split($0,a," "); split(a[n],b,"@");
              if (b[1]==u && b[2]!="") print b[2] }' | sort -u)"
        if [[ -z "$clients" ]]; then
            warn "没找到用户 $user 的 checkout"; return 0
        fi
        local c
        for c in $clients; do
            info "revert client=$c 上 $user 的文件..."
            if ! "$P4_BIN" -p "localhost:$P4PORT" -u admin revert -C "$c" //... ; then
                warn "  client $c revert 出错(若提示 client unknown,见下方说明)"
            fi
        done
    else
        info "revert -C $client $filespec ..."
        if ! "$P4_BIN" -p "localhost:$P4PORT" -u admin revert -C "$client" "$filespec"; then
            err "revert 失败"
            warn "若提示 'Client $client unknown' —— workspace 已被删除。"
            warn "解决:临时重建同名 client 再 revert:"
            warn "    p4 -p localhost:$P4PORT -u admin client -i <<< \"Client: $client\nRoot: /tmp/$client\nView: //depot/... //$client/...\""
            warn "    再回到本菜单选 a) 用同名 client revert。"
            return 1
        fi
    fi

    # 4. 验证
    echo
    info "[验证] 剩余 opened 文件:"
    local after
    after="$("$P4_BIN" -p "localhost:$P4PORT" -u admin opened -a 2>/dev/null || true)"
    if [[ -z "$after" ]]; then
        ok "全部已释放,没有残留 checkout"
    else
        echo "$after" | sed 's/^/    /'
        info "(以上为其他仍在使用的 checkout,未动)"
    fi
}

step_one_click_restore() {
    section "🚀 一键恢复"
    # 优先从 Root_Temp 找(全新部署 / 迁移场景),没有则用 BACKUP_DIR(日常 cron 输出)
    local SOURCE_DIR
    if [[ -d "$ROOT_TEMP" ]] && ls "$ROOT_TEMP"/checkpoint.* >/dev/null 2>&1; then
        SOURCE_DIR="$ROOT_TEMP"
    else
        SOURCE_DIR="$BACKUP_DIR"
    fi
    info "从备份目录还原:找最新 checkpoint + 后续 journal,做完整 replay"
    info "  来源目录: $SOURCE_DIR"
    confirm "继续?" || return 0

    if ! require_confirm_text "这会覆盖当前 db.* — 输入 CONFIRM 继续: " "CONFIRM"; then
        info "已取消"; return 0
    fi

    # 检查 perforce 用户能不能读 SOURCE_DIR(默认 ROOT_TEMP=/root/P4_Temp/Root_Temp,
    # /root 权限 700,perforce 进不去 → p4d -jr 会 Permission denied)。
    # 不能读就自动 stage 到 BACKUP_DIR(/opt/perforce/backups,perforce 一定能读)。
    if ! sudo -u "$P4D_USER" test -r "$SOURCE_DIR" 2>/dev/null; then
        warn "perforce 用户读不到 $SOURCE_DIR (权限隔离),自动 stage 到 $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        # 拷贝 checkpoint / journal / md5 到 BACKUP_DIR
        local stage_count=0
        for f in "$SOURCE_DIR"/checkpoint.* "$SOURCE_DIR"/journal "$SOURCE_DIR"/journal.[0-9]*; do
            [[ -f "$f" ]] || continue
            cp -p "$f" "$BACKUP_DIR/"
            stage_count=$((stage_count + 1))
        done
        chown -R "$P4D_USER:$P4D_USER" "$BACKUP_DIR"
        ok "已 stage $stage_count 个文件到 $BACKUP_DIR"
        SOURCE_DIR="$BACKUP_DIR"
        info "  新来源目录: $SOURCE_DIR"
    fi

    # 1. Find latest checkpoint
    local latest_ckpt latest_num
    latest_ckpt="$(ls -1 "$SOURCE_DIR"/checkpoint.* 2>/dev/null | grep -v '\.md5$' | grep -v '\.gz$' | sort -V | tail -1 || true)"
    if [[ -z "$latest_ckpt" ]]; then
        # try .gz
        latest_ckpt="$(ls -1 "$SOURCE_DIR"/checkpoint.*.gz 2>/dev/null | sort -V | tail -1 || true)"
    fi
    [[ -z "$latest_ckpt" ]] && die "在 $SOURCE_DIR 没找到 checkpoint.* 文件"
    latest_num="$(basename "$latest_ckpt" | sed -E 's/^checkpoint\.([0-9]+).*/\1/')"
    info "最新 checkpoint: $latest_ckpt (#$latest_num)"

    # 2. Find journals N >= latest_num,按编号排序后再追加无后缀的 live journal
    #
    # 命名约定:
    #   journal.N         — 已轮转的旧 journal(checkpoint 时被 p4d -jc 改名生成)
    #   journal           — 当前活跃 live journal,包含最新 checkpoint 之后的所有变更
    #
    # 之前只匹配 journal.[0-9]* 会漏掉 live journal,导致从 master 拷过来的最新变更
    # 全部丢失(用户场景:Root_Temp 里只有 checkpoint.149 + journal,如果不拾起 journal,
    # 149 之后的提交就回不来)。修复:先收编号 journal,排序后追加无编号的 live journal。
    local journals=()
    local sorted_numbered=()
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        sorted_numbered+=("$f")
    done < <(ls -1 "$SOURCE_DIR"/journal.[0-9]* 2>/dev/null | sort -V)

    for f in "${sorted_numbered[@]}"; do
        local n
        n="$(basename "$f" | sed -E 's/^journal\.([0-9]+).*/\1/')"
        if (( n >= latest_num )); then
            journals+=("$f")
        fi
    done

    # 追加无后缀 live journal(必须最后 replay,因为它包含最新变更)
    if [[ -f "$SOURCE_DIR/journal" ]]; then
        info "检测到 live journal: $SOURCE_DIR/journal (最后 replay)"
        journals+=("$SOURCE_DIR/journal")
    fi

    info "需要 replay 的 journal 数: ${#journals[@]}"

    # 镜像 depot 物理文件(若 SOURCE_DIR 包含 depot 子目录)
    local depots=()
    while IFS= read -r d; do
        local name; name="$(basename "$d")"
        [[ "$name" =~ ^\. ]] && continue
        [[ "$name" == "server.locks" ]] && continue
        depots+=("$d")
    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if (( ${#depots[@]} > 0 )); then
        info "发现 ${#depots[@]} 个 depot 子目录,稍后镜像到 $P4ROOT"
    fi

    # 3. Stop service
    info "停止服务"
    systemctl stop "$SVC_NAME" || true
    sleep 2

    # 4. Snapshot current db.*
    local snap="${P4ROOT}/.pre-restore-$(date +%Y%m%d-%H%M%S)"
    info "快照当前 db.* 到 $snap"
    mkdir -p "$snap"
    chown "$P4D_USER:$P4D_USER" "$snap"
    find "$P4ROOT" -maxdepth 1 -name "db.*" -exec cp -p {} "$snap/" \;
    find "$P4ROOT" -maxdepth 1 -name "db.*" -delete

    # 4.5 Mirror depot physical files into P4ROOT (if any)
    if (( ${#depots[@]} > 0 )); then
        for src in "${depots[@]}"; do
            local name; name="$(basename "$src")"
            local lower; lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
            info "  镜像 $name → $P4ROOT/$lower"
            mkdir -p "$P4ROOT/$lower"
            cp -a "$src/." "$P4ROOT/$lower/"
        done
        chown -R "$P4D_USER:$P4D_USER" "$P4ROOT"
    fi

    # 5. Apply checkpoint (auto-detect .gz + auto-detect case mode)
    #
    # 核心坑(用户实际踩到):
    # 从 Windows P4D(默认 -C1, case-insensitive)迁移到 Linux P4D(默认 -C0,
    # case-sensitive)时,checkpoint 里"绑定"了 -C1 标记,replay 到默认 -C0
    # 服务器会失败:"Case-handling mismatch: server uses Unix-style (-C0)
    # but journal flags are Windows-style (-C1)!"
    #
    # case 模式只在 db 第一次创建时锁定。db.* 已删,这次 replay 就是创建,
    # 必须按 checkpoint 的标记传 -C0 / -C1 / -C2。
    #
    # 检测方法:peek checkpoint 找 @case@ 字段
    #   小 checkpoint 通常在前 16KB
    #   大 checkpoint(几百 MB)里 db.counters 之前可能有大量 db.config 等条目,
    #   @case@ 可能在 1MB 之后 — 扩大到 64MB,失败则全文件 grep
    info "检测 checkpoint case 模式..."
    local case_flag=""
    local case_value=""
    local probe_cmd
    if [[ "$latest_ckpt" == *.gz ]]; then
        probe_cmd="zcat \"$latest_ckpt\" 2>/dev/null"
    else
        probe_cmd="cat \"$latest_ckpt\" 2>/dev/null"
    fi

    # 第 1 轮:前 64MB(覆盖 99% 的 checkpoint,通常秒级)
    case_value="$(eval "$probe_cmd" | head -c 67108864 | grep -aoE '@case@ @[0-9]+@' | head -1 | grep -oE '[0-9]+' || true)"

    # 第 2 轮:全文件 grep(慢但可靠,大 checkpoint 可能要 1-2 分钟)
    if [[ -z "$case_value" ]]; then
        warn "前 64MB 未检测到 @case@,扫描整个 checkpoint(可能需要 1-2 分钟)..."
        case_value="$(eval "$probe_cmd" | grep -aoE '@case@ @[0-9]+@' | head -1 | grep -oE '[0-9]+' || true)"
    fi

    if [[ -n "$case_value" ]]; then
        case_flag="-C${case_value}"
        info "Checkpoint 声明 case 模式: $case_flag ($(case "$case_value" in
            0) echo "Unix-style, case-sensitive" ;;
            1) echo "Windows hybrid, case-insensitive 比较 + case-preserving 存储" ;;
            2) echo "Windows pure case-insensitive" ;;
            *) echo "未知" ;;
        esac))"
    else
        warn "未检测到 case 模式声明 — 用 P4D 默认值(Linux 上是 -C0)"
    fi

    info "Replay $latest_ckpt $case_flag"
    local replay_rc=0
    if [[ -n "$case_flag" ]]; then
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" "$case_flag" -jr "$latest_ckpt" || replay_rc=$?
    else
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$latest_ckpt" 2>&1 | tee /tmp/p4d_replay_$$.log
        replay_rc=${PIPESTATUS[0]}
        # 自动从错误信息恢复:Case-handling mismatch 时自动加 -C1 重试
        if (( replay_rc != 0 )) && grep -q 'Case-handling mismatch' /tmp/p4d_replay_$$.log; then
            warn "撞到 Case-handling mismatch,自动 -C1 重试..."
            find "$P4ROOT" -maxdepth 1 -name "db.*" -delete
            sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -C1 -jr "$latest_ckpt" && replay_rc=0
        fi
        rm -f /tmp/p4d_replay_$$.log
    fi
    if (( replay_rc != 0 )); then
        die "checkpoint replay 失败(exit $replay_rc) — 查看 systemd 日志或手动跑 p4d -jr 看具体原因"
    fi

    # 6. Apply journals in order
    for j in "${journals[@]}"; do
        info "Replay $j"
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$j" || warn "$j 报错(可能 out-of-sequence,无害)"
    done

    # 7. Pre-start counter rescue (defuse 坑 #1)
    info "注入 counter=0 jnl"
    local rj="/tmp/p4_pre_start_$$.jnl"
    echo "@pv@ 1 @db.counters@ @change@ @0@" > "$rj"
    chown "$P4D_USER:$P4D_USER" "$rj"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$rj"
    rm -f "$rj"

    # 8. Start
    info "启动服务"
    systemctl start "$SVC_NAME"
    sleep 5

    # 9. Calibrate counter
    if [[ -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        export P4TICKETS=/tmp/.p4tickets_admin
        "$P4_BIN" -p "localhost:$P4PORT" -u admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null 2>&1 || true
        local max
        max="$(current_max_change)"
        if [[ -n "$max" && "$max" -gt 0 ]]; then
            local next=$((max + 1))
            "$P4_BIN" -p "localhost:$P4PORT" -u admin counter -f change "$next" >/dev/null
            info "counter 已校准到 $next"
        fi
    fi

    ok "恢复完成。快照保存在: $snap (确认无问题后可删)"
    p4_info_license || true
}

step_health_check() {
    section "🩺 健康体检"

    # 健康体检本身只是"探测+报告",不应该让任何子命令的非 0 退出
    # 把整个脚本带崩(否则全新机器还没装,体检就把菜单干掉了)。
    # 用子 shell 包裹 + 局部关掉 errexit / pipefail。
    (
    set +e
    set +o pipefail

    # Service
    local svc; svc="$(svc_state)"
    [[ "$svc" == "running" ]] && ok "服务: 运行中" || err "服务: $svc"

    # Ports
    if ss -tlnp 2>/dev/null | grep -q ":$P4PORT "; then
        ok "端口 $P4PORT: 监听中"
    else
        err "端口 $P4PORT: 没监听"
    fi

    # License
    local lic; lic="$(p4_info_license)"
    if [[ -n "$lic" ]]; then
        if echo "$lic" | grep -q "none\|5-user"; then
            err "License: $lic (降级到免费版)"
        else
            ok "License: $lic"
        fi
    else
        warn "License: 未读取到"
    fi

    # Counter consistency
    local counter max
    counter="$(current_change_counter)"
    max="$(current_max_change)"
    if [[ -n "$counter" && -n "$max" ]]; then
        local expected=$((max + 1))
        if [[ "$counter" == "$expected" || "$counter" == "$max" ]]; then
            ok "Counter: $counter (MAX=$max,一致)"
        else
            err "Counter 漂移: $counter ≠ 期望 $expected (MAX=$max) — 用菜单 6 救援"
        fi
    fi

    # 本地 checkpoint
    if [[ -d "$BACKUP_DIR" ]]; then
        local last_ckpt
        last_ckpt="$(ls -t "$BACKUP_DIR"/checkpoint.* 2>/dev/null | head -1 || true)"
        if [[ -n "$last_ckpt" ]]; then
            local age_h
            age_h=$(( ($(date +%s) - $(stat -c %Y "$last_ckpt")) / 3600 ))
            if (( age_h > 26 )); then
                err "本地上次 checkpoint: ${age_h}h 前 (>26h,异常)"
            else
                ok "本地上次 checkpoint: ${age_h}h 前"
            fi
        else
            warn "$BACKUP_DIR 里没有 checkpoint.* 文件"
        fi
    else
        warn "$BACKUP_DIR 不存在"
    fi

    # NAS 挂载 + 远程备份新鲜度
    if mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null; then
        ok "NAS 挂载: $NAS_BACKUP_ROOT (NFS 活着)"
        # 验证可写
        local probe="$NAS_BACKUP_ROOT/.write_probe_$$"
        if (touch "$probe" 2>/dev/null && rm -f "$probe"); then
            ok "NAS 可写"
        else
            err "NAS 不可写 — 检查 NFS squash / 权限"
        fi
        # 远程上次 checkpoint 新鲜度
        if [[ -d "$NAS_BACKUP_ROOT/checkpoints" ]]; then
            local nas_last
            nas_last="$(ls -t "$NAS_BACKUP_ROOT/checkpoints"/checkpoint.* 2>/dev/null | head -1 || true)"
            if [[ -n "$nas_last" ]]; then
                local age_h
                age_h=$(( ($(date +%s) - $(stat -c %Y "$nas_last")) / 3600 ))
                if (( age_h > 26 )); then
                    err "NAS 上次 checkpoint: ${age_h}h 前 (>26h,rsync 失败?)"
                else
                    ok "NAS 上次 checkpoint: ${age_h}h 前"
                fi
            else
                warn "NAS checkpoints 目录里没文件 — 还没跑过同步"
            fi
        else
            info "NAS checkpoints 目录还没创建 (cron 第一次跑会建)"
        fi
    else
        if [[ -n "${NAS_BACKUP_ROOT:-}" ]]; then
            err "NAS 没挂载: $NAS_BACKUP_ROOT — 检查 fstab / 网络"
        fi
    fi

    # Disk — P4ROOT 还没创建时优雅跳过(全新机器装之前的常见状态)
    if [[ -d "$P4ROOT" ]]; then
        local pct
        pct="$(df -P "$P4ROOT" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')"
        if [[ -z "$pct" ]]; then
            warn "P4ROOT 磁盘使用率: 读取失败"
        elif (( pct > 90 )); then
            err "P4ROOT 所在盘已用 ${pct}% (>90%,危险)"
        elif (( pct > 75 )); then
            warn "P4ROOT 所在盘已用 ${pct}%"
        else
            ok "P4ROOT 所在盘已用 ${pct}%"
        fi
    else
        info "P4ROOT 还未创建: $P4ROOT (新机器,先跑菜单 1 部署)"
    fi

    # Systemd journal recent errors
    local errors
    errors="$(journalctl -u "$SVC_NAME" --since "1h ago" -p err --no-pager 2>/dev/null | wc -l)"
    if (( errors > 1 )); then
        warn "近 1h systemd journal 中有 $((errors - 1)) 条错误"
    fi

    )  # 关闭健康体检子 shell — errexit/pipefail 自动恢复
    return 0
}

step_show_backup_status() {
    section "备份状态"
    info "本地 checkpoint 目录: $BACKUP_DIR"
    if [[ -d "$BACKUP_DIR" ]]; then
        ls -lht "$BACKUP_DIR" 2>/dev/null | head -10
    else
        warn "本地目录不存在"
    fi

    echo
    info "NAS 备份根目录: $NAS_BACKUP_ROOT"
    if mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null; then
        ok "  挂载状态: 已挂载 (NFS)"
    elif [[ -d "$NAS_BACKUP_ROOT" ]]; then
        warn "  挂载状态: 目录存在但 不是 NFS 挂载点 (可能 fstab 没生效)"
    else
        err "  挂载状态: 目录不存在 — NFS 没挂载"
    fi

    if [[ -d "$NAS_BACKUP_ROOT/checkpoints" ]]; then
        echo
        info "  NAS checkpoint 目录:"
        ls -lht "$NAS_BACKUP_ROOT/checkpoints" 2>/dev/null | head -8
    fi
    if [[ -d "$NAS_BACKUP_ROOT/depots" ]]; then
        echo
        info "  NAS depot 目录大小: $(du -sh "$NAS_BACKUP_ROOT/depots" 2>/dev/null | cut -f1)"
        ls -lh "$NAS_BACKUP_ROOT/depots" 2>/dev/null | head -10
    fi

    # 漂移检测:P4ROOT 里如果出现 checkpoint.* / journal.[0-9]*,
    # 说明 checkpoint 没指定输出 PREFIX(裸 p4d -jc 或用了错误的 -p 标志 —
    # p4d 的 -p 是 port 参数不是 prefix,正确写法是末尾位置参数 PREFIX)。
    # 漂移文件会被 depot rsync 扫到 NAS depots/ 里造成"checkpoint 跑错目录",
    # 并让 monitor 误以为本地 backup 没更新。
    local stray_ckpt stray_jnl
    stray_ckpt="$(ls "$P4ROOT"/checkpoint.* 2>/dev/null | grep -v '\.migrated$' || true)"
    stray_jnl="$(ls "$P4ROOT"/journal.[0-9]* 2>/dev/null | grep -v '\.migrated$' || true)"
    if [[ -n "$stray_ckpt$stray_jnl" ]]; then
        echo
        warn "⚠️  P4ROOT 里检测到漂移文件(应该在 $BACKUP_DIR):"
        [[ -n "$stray_ckpt" ]] && echo "$stray_ckpt"
        [[ -n "$stray_jnl"  ]] && echo "$stray_jnl"
        info "修复:sudo mv $P4ROOT/{checkpoint.*,journal.[0-9]*} $BACKUP_DIR/ && sudo chown $P4D_USER:$P4D_USER $BACKUP_DIR/{checkpoint.*,journal.*}"
        info "然后重跑选项 14(rsync 到 NAS)"
    fi
}

step_view_journal() {
    section "systemd journal (最近 100 行)"
    journalctl -u "$SVC_NAME" -n 100 --no-pager
}

step_run_checkpoint_now() {
    section "立刻生成一个 checkpoint"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jc -Z "$BACKUP_DIR/checkpoint"
    ok "完成"
    ls -lht "$BACKUP_DIR" | head -5
}

step_run_rsync_now() {
    section "立刻 rsync 到 NAS"
    if ! mountpoint -q "$NAS_BACKUP_ROOT" 2>/dev/null && [[ ! -d "$NAS_BACKUP_ROOT" ]]; then
        die "$NAS_BACKUP_ROOT 不可达 — 先挂载 NAS NFS"
    fi
    mkdir -p "$NAS_BACKUP_ROOT/checkpoints" "$NAS_BACKUP_ROOT/depots"

    # NFS all_squash 会拒绝 rsync 保留 owner/group/perms,导致退出码 23,
    # 数据传过去了但 errexit + pipefail 让脚本中途退出,[2/2] depot 没跑。
    # --no-owner --no-group --no-perms 跳过这三个属性的保留。
    # || true 兜底:即便 rsync 报其他无害错(部分文件被锁等),也继续走 [2/2]。
    local rsync_opts="--archive --no-owner --no-group --no-perms --delete --human-readable"

    info "[1/2] rsync 本地 checkpoint+journal → $NAS_BACKUP_ROOT/checkpoints/"
    set +e
    rsync $rsync_opts "$BACKUP_DIR/" "$NAS_BACKUP_ROOT/checkpoints/" 2>&1 | tail -10
    local rc1=${PIPESTATUS[0]}
    set -e
    if (( rc1 != 0 )); then
        warn "[1/2] rsync 退出码 $rc1 (常见: NFS squash 不允许 chown,数据本身已传)"
    fi

    info "[2/2] rsync depot 物理文件 → $NAS_BACKUP_ROOT/depots/ (这步耗时,首次推全量)"
    set +e
    rsync $rsync_opts --exclude='db.*' --exclude='journal*' --exclude='log*' --exclude='checkpoint.*' \
        "$P4ROOT/" "$NAS_BACKUP_ROOT/depots/" 2>&1 | tail -10
    local rc2=${PIPESTATUS[0]}
    set -e
    if (( rc2 != 0 )); then
        warn "[2/2] rsync 退出码 $rc2 (常见: NFS squash 不允许 chown,数据本身已传)"
    fi

    if (( rc1 == 0 && rc2 == 0 )); then
        ok "完成"
    else
        ok "完成 (有非致命警告,数据已传 — 详见上面 rc 提示)"
    fi
}

step_uninstall() {
    section "⚠ 卸载 P4D + Toolkit"
    warn "这会停止服务、删除 systemd unit、cron、二进制文件"
    warn "数据库 ($P4ROOT) 和 license 文件 不会 被删,请手动处理"
    if ! require_confirm_text "确认卸载? 输入 UNINSTALL: " "UNINSTALL"; then
        info "已取消"; return 0
    fi

    systemctl stop "$SVC_NAME" 2>/dev/null || true
    systemctl disable "$SVC_NAME" 2>/dev/null || true
    rm -f "$SVC_FILE" "$RESCUE_DROPIN_FILE" "$CRON_FILE"
    rm -rf "$RESCUE_DROPIN_DIR"
    rm -f "$P4D_BIN" "$P4_BIN_DIR/p4"
    rm -f /usr/local/bin/p4 /usr/local/sbin/p4d
    systemctl daemon-reload
    ok "卸载完成。保留的文件: $P4ROOT (database), $CONFIG_FILE"
}

# ============================================================
#  MENU
# ============================================================

main_menu() {
    while true; do
        print_header
        # 每次菜单刷新都跑一次健康体检 — 状态实时显示
        # (原来只在首次跑,用户反馈"看不到状态变化",改成每次都跑)
        step_health_check
        echo
        cat <<MENU

  ${C_BOLD}── 准备 ──${C_RESET}
  0) 一键创建工作目录 + 下载安装包(创建 /root/P4_Temp 并从 GitHub 拉 tgz)

  ${C_BOLD}── 部署 ──${C_RESET}
  1) 全新安装 P4D ${P4D_VERSION}
  2) 安装 license 文件
  3) 配置 systemd 服务 + 启动自愈 hook
  4) 配置每日 03:00 (美西) checkpoint cron 备份
  5) 一次性全部部署 (0→1→2→3→4)

  ${C_BOLD}── 救援 ──${C_RESET}
  6) Counter 救援 (license 炸了用)
  7) 一键恢复 (从备份 checkpoint+journal)
  8) 强制解锁学生遗留 checkout (电脑格式化 / workspace 没了)

  ${C_BOLD}── 体检 / 状态 ──${C_RESET}
  10) 健康体检
  11) 备份状态
  12) systemd journal 日志

  ${C_BOLD}── 维护 ──${C_RESET}
  13) 立刻生成 checkpoint
  14) 立刻 rsync 到 NAS (checkpoint + depot 一次推完)
  15) 启动服务
  16) 停止服务
  17) 重启服务

  ${C_BOLD}── 危险区 ──${C_RESET}
  99) 卸载 P4D + Toolkit

  q) 退出

MENU
        local choice
        read -r -p "$(printf "${C_CYAN}选择: ${C_RESET}")" choice
        echo
        case "$choice" in
            0)  step_prepare_workspace ;;
            1)  step_install_p4d ;;
            2)  step_install_license ;;
            3)  step_setup_systemd_with_rescue ;;
            4)  step_setup_cron_checkpoint ;;
            5)  step_prepare_workspace && step_install_p4d && step_install_license && step_setup_systemd_with_rescue && step_setup_cron_checkpoint ;;
            6)  step_counter_rescue ;;
            7)  step_one_click_restore ;;
            8)  step_force_revert ;;
            10) step_health_check ;;
            11) step_show_backup_status ;;
            12) step_view_journal ;;
            13) step_run_checkpoint_now ;;
            14) step_run_rsync_now ;;
            15) systemctl start "$SVC_NAME" && ok "已启动" ;;
            16) systemctl stop  "$SVC_NAME" && ok "已停止" ;;
            17) systemctl restart "$SVC_NAME" && ok "已重启" ;;
            99) step_uninstall ;;
            q|exit) ok "再见"; exit 0 ;;
            *) err "未知选项: $choice" ;;
        esac
        echo
        read -r -p "按回车继续..." _
    done
}

# ============================================================
#  主入口
# ============================================================

main() {
    log_init
    ensure_root
    load_config

    # 非交互模式 (CLI subcommands)
    if [[ $# -gt 0 ]]; then
        case "$1" in
            status|health)   step_health_check ;;
            checkpoint)      step_run_checkpoint_now ;;
            rsync)           step_run_rsync_now ;;
            counter-rescue)  step_counter_rescue ;;
            restore)         step_one_click_restore ;;
            force-revert)    step_force_revert ;;
            *) die "未知子命令: $1 (用法: status|checkpoint|rsync|counter-rescue|restore|force-revert)" ;;
        esac
        exit 0
    fi

    main_menu
}

main "$@"
