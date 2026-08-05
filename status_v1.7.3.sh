#!/usr/bin/env bash
#=================================================
#  Description: ServerStatus-Rust 管理脚本
#  Script Version: v1.7.3
#  Updater: Yooona-Lim
#
#  v1.7.0:
#    1. 重构安装、配置、升级、备份和恢复流程
#    2. 支持 http/https/grpc/grpcs，默认端口自动省略
#    3. 支持域名、IPv4、IPv6 与 HTTP(S) 自定义上报路径
#    4. 用户名和密码中的特殊字符无需手动转换 %40 等编码
#    5. systemd 参数自动转义，避免空格、$、%、引号等字符破坏服务
#    6. 下载失败检测、ZIP 完整性检查、原子替换、失败自动回滚
#    7. 不额外创建 client.env/config.conf，当前配置保存在 service 注释中
#=================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_VERSION="v1.7.0"
REPO="zdz/ServerStatus-Rust"
WORKING_DIR="/opt/ServerStatus"
CLIENT_DIR="${WORKING_DIR}/client"
SERVER_DIR="${WORKING_DIR}/server"
CLIENT_FILE="${CLIENT_DIR}/stat_client"
SERVER_FILE="${SERVER_DIR}/stat_server"
SERVER_TOML="${SERVER_DIR}/config.toml"
CLIENT_SERVICE="stat_client.service"
SERVER_SERVICE="stat_server.service"
CLIENT_UNIT="/etc/systemd/system/${CLIENT_SERVICE}"
SERVER_UNIT="/etc/systemd/system/${SERVER_SERVICE}"
BACKUP_ROOT="/usr/local/ServerStatus/bak"
LOCK_FILE="/run/lock/serverstatus-rust-manager.lock"

INFO='\033[32m[信息]\033[0m'
ERROR='\033[31m[错误]\033[0m'
WARNING='\033[33m[警告]\033[0m'
TIP='\033[36m[提示]\033[0m'
SUCCESS='\033[32m[成功]\033[0m'

TMP_DIR=""
LOCK_DIR=""
RELEASE_VERSION="unknown"
ARCH=""
PKG_FAMILY=""

CLIENT_PROTOCOL=""
CLIENT_HOST=""
CLIENT_PORT=""
CLIENT_PATH=""
CLIENT_USER=""
CLIENT_PASSWORD=""

log_info()    { echo -e "${INFO} $*"; }
log_warn()    { echo -e "${WARNING} $*" >&2; }
log_error()   { echo -e "${ERROR} $*" >&2; }
log_success() { echo -e "${SUCCESS} $*"; }
die()         { log_error "$*"; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT ERR
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
    return "$rc"
}

setup_traps() {
    trap cleanup EXIT
    trap 'log_error "脚本在第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd，当前系统暂不支持本脚本。"
    [[ -d /run/systemd/system ]] || die "systemd 当前未运行。"
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        flock -n 9 || die "已有另一个 status.sh 进程正在运行。"
    else
        LOCK_DIR="${LOCK_FILE}.d"
        mkdir "$LOCK_DIR" 2>/dev/null || die "已有另一个 status.sh 进程正在运行。"
    fi
}

init_tmp() {
    TMP_DIR=$(mktemp -d /tmp/serverstatus-rust.XXXXXX)
    chmod 700 "$TMP_DIR"
}

progress() {
    local current=$1 total=$2 message=$3
    printf '\n[%s/%s] %s\n' "$current" "$total" "$message"
}

check_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ARCH="x86_64" ;;
        aarch64|arm64|aarch64_be|armv8b|armv8l) ARCH="aarch64" ;;
        armv7l|armv7) ARCH="armv7" ;;
        *) die "暂不支持当前架构：$(uname -m)" ;;
    esac
}

detect_package_family() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_FAMILY="deb"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_FAMILY="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_FAMILY="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_FAMILY="arch"
    elif command -v apk >/dev/null 2>&1; then
        PKG_FAMILY="alpine"
    else
        die "无法识别当前系统的软件包管理器。"
    fi
}

install_dependencies() {
    local need=()
    command -v unzip >/dev/null 2>&1 || need+=(unzip)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        need+=(curl)
    fi
    command -v base64 >/dev/null 2>&1 || need+=(coreutils)
    ((${#need[@]} == 0)) && return 0

    log_info "安装依赖：${need[*]}"
    case "$PKG_FAMILY" in
        deb)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${need[@]}"
            ;;
        dnf) dnf install -y ca-certificates "${need[@]}" ;;
        yum) yum install -y ca-certificates "${need[@]}" ;;
        arch)
            local arch_need=()
            for item in "${need[@]}"; do
                [[ "$item" == "coreutils" ]] || arch_need+=("$item")
            done
            ((${#arch_need[@]})) && pacman -Sy --noconfirm "${arch_need[@]}"
            ;;
        alpine)
            apk add --no-cache ca-certificates "${need[@]}"
            ;;
    esac
}

preflight() {
    require_root
    require_systemd
    acquire_lock
    check_arch
    detect_package_family
    install_dependencies
    init_tmp
}

fetch_text() {
    local url=$1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 "$url"
    else
        wget -qO- --timeout=30 --tries=3 "$url"
    fi
}

download_file() {
    local url=$1 destination=$2 effective_url
    effective_url="${MIRROR:-}${url}"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 \
            --progress-bar -o "$destination" "$effective_url"
    else
        wget --timeout=30 --tries=3 --show-progress -O "$destination" "$effective_url"
    fi

    [[ -s "$destination" ]] || die "下载文件为空：$url"
}

get_latest_version() {
    local api="https://api.github.com/repos/${REPO}/releases/latest" result
    result=$(fetch_text "$api" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)
    [[ -n "$result" ]] && printf '%s' "$result" || printf 'unknown'
}

asset_arch() {
    case "$ARCH" in
        x86_64) printf 'x86_64-unknown-linux-musl' ;;
        aarch64) printf 'aarch64-unknown-linux-musl' ;;
        armv7) printf 'armv7-unknown-linux-musleabihf' ;;
    esac
}

verify_elf() {
    local file=$1 magic
    magic=$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')
    [[ "$magic" == "7f454c46" ]] || die "下载内容不是有效的 Linux ELF 二进制文件：$file"
}

download_component() {
    local component=$1 target zip extract_dir binary asset url found
    target=$(asset_arch)
    asset="${component}-${target}.zip"
    url="https://github.com/${REPO}/releases/latest/download/${asset}"
    zip="${TMP_DIR}/${asset}"
    extract_dir="${TMP_DIR}/${component}"

    mkdir -p "$extract_dir"
    log_info "下载 ${component}（${target}）"
    download_file "$url" "$zip"
    unzip -tq "$zip" >/dev/null || die "ZIP 文件完整性检查失败：$asset"
    unzip -oq "$zip" -d "$extract_dir"

    binary="stat_${component}"
    found=$(find "$extract_dir" -type f -name "$binary" -print -quit)
    [[ -n "$found" ]] || die "压缩包中未找到 $binary"
    chmod 0755 "$found"
    verify_elf "$found"

    DOWNLOADED_BINARY="$found"
    DOWNLOADED_CONFIG=""
    if [[ "$component" == "server" ]]; then
        DOWNLOADED_CONFIG=$(find "$extract_dir" -type f -name 'config.toml' -print -quit || true)
    fi
}

validate_no_control_chars() {
    local label=$1 value=$2
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || \
        die "${label} 不能包含换行符、回车符或制表符。"
}

url_decode() {
    local input=$1 output="" ch hex
    while [[ -n "$input" ]]; do
        ch=${input:0:1}
        if [[ "$ch" == '%' && ${#input} -ge 3 && ${input:1:2} =~ ^[0-9A-Fa-f]{2}$ ]]; then
            hex=${input:1:2}
            [[ "$hex" != "00" && "$hex" != "0A" && "$hex" != "0a" && "$hex" != "0D" && "$hex" != "0d" && "$hex" != "09" ]] || \
                die "URL 中不能包含编码后的控制字符。"
            printf -v ch '%b' "\\x${hex}"
            output+="$ch"
            input=${input:3}
        else
            output+="$ch"
            input=${input:1}
        fi
    done
    printf '%s' "$output"
}

b64_encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

b64_decode() {
    local value=$1
    [[ -n "$value" ]] || return 0
    printf '%s' "$value" | base64 -d 2>/dev/null || true
}

default_port_for_protocol() {
    case "$1" in
        http|grpc) printf '80' ;;
        https|grpcs) printf '443' ;;
        *) return 1 ;;
    esac
}

normalize_protocol() {
    CLIENT_PROTOCOL=${CLIENT_PROTOCOL,,}
    case "$CLIENT_PROTOCOL" in
        http|https|grpc|grpcs) ;;
        *) die "不支持的协议：${CLIENT_PROTOCOL}" ;;
    esac
}

normalize_host() {
    CLIENT_HOST=${CLIENT_HOST#[}
    CLIENT_HOST=${CLIENT_HOST%]}
}

validate_client_config() {
    normalize_protocol
    normalize_host

    [[ -n "$CLIENT_USER" ]] || die "用户名不能为空。"
    [[ -n "$CLIENT_PASSWORD" ]] || die "密码不能为空。"
    [[ -n "$CLIENT_HOST" ]] || die "服务器地址不能为空。"

    validate_no_control_chars "用户名" "$CLIENT_USER"
    validate_no_control_chars "密码" "$CLIENT_PASSWORD"
    validate_no_control_chars "服务器地址" "$CLIENT_HOST"
    validate_no_control_chars "上报路径" "$CLIENT_PATH"

    [[ "$CLIENT_HOST" != *'/'* && "$CLIENT_HOST" != *' '* ]] || die "服务器地址格式错误。"

    if [[ -n "$CLIENT_PORT" ]]; then
        [[ "$CLIENT_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
        ((CLIENT_PORT >= 1 && CLIENT_PORT <= 65535)) || die "端口范围必须为 1-65535。"
        if [[ "$CLIENT_PORT" == "$(default_port_for_protocol "$CLIENT_PROTOCOL")" ]]; then
            CLIENT_PORT=""
        fi
    fi

    case "$CLIENT_PROTOCOL" in
        http|https)
            [[ -n "$CLIENT_PATH" ]] || CLIENT_PATH="/report"
            [[ "$CLIENT_PATH" == /* ]] || CLIENT_PATH="/${CLIENT_PATH}"
            [[ "$CLIENT_PATH" != *' '* ]] || die "HTTP(S) 上报路径不能包含空格。"
            ;;
        grpc|grpcs)
            [[ -z "$CLIENT_PATH" || "$CLIENT_PATH" == "/" ]] || die "gRPC 地址不能包含 HTTP 路径。"
            CLIENT_PATH=""
            ;;
    esac
}

format_client_host() {
    if [[ "$CLIENT_HOST" == *:* ]]; then
        printf '[%s]' "$CLIENT_HOST"
    else
        printf '%s' "$CLIENT_HOST"
    fi
}

build_endpoint() {
    local host endpoint
    host=$(format_client_host)
    endpoint="${CLIENT_PROTOCOL}://${host}"
    [[ -n "$CLIENT_PORT" ]] && endpoint+=":${CLIENT_PORT}"
    [[ -n "$CLIENT_PATH" ]] && endpoint+="${CLIENT_PATH}"
    printf '%s' "$endpoint"
}

parse_quick_uri() {
    local uri=$1 rest auth target user_raw pass_raw authority path="" host="" port=""
    [[ "$uri" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || die "配置格式错误，缺少协议，例如：https://user:password@example.com"

    CLIENT_PROTOCOL=${uri%%://*}
    rest=${uri#*://}
    [[ "$rest" == *@* ]] || die "配置格式错误，缺少 user:password@ 部分。"

    # 使用最后一个 @ 分隔服务端，因此密码中可以直接包含 @。
    auth=${rest%@*}
    target=${rest##*@}
    [[ "$auth" == *:* ]] || die "配置格式错误，用户名和密码之间必须使用冒号分隔。"

    user_raw=${auth%%:*}
    pass_raw=${auth#*:}
    # 默认保留原始内容，避免把密码中真实存在的 %40 误改成 @。
    # 兼容旧版 URL 编码时，可使用 DECODE_URI=true。
    if [[ "${DECODE_URI:-false}" == "true" ]]; then
        CLIENT_USER=$(url_decode "$user_raw")
        CLIENT_PASSWORD=$(url_decode "$pass_raw")
    else
        CLIENT_USER=$user_raw
        CLIENT_PASSWORD=$pass_raw
    fi

    if [[ "$target" == \[* ]]; then
        if [[ "$target" =~ ^\[([^]]+)\](:([0-9]+))?(.*)$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[3]}
            path=${BASH_REMATCH[4]}
        else
            die "IPv6 地址格式错误，请使用 [2001:db8::1]。"
        fi
    else
        if [[ "$target" == */* ]]; then
            authority=${target%%/*}
            path="/${target#*/}"
        else
            authority=$target
        fi

        if [[ "$authority" == *:* ]]; then
            [[ "$authority" != *:*:* ]] || die "IPv6 地址必须使用方括号，例如：[2001:db8::1]。"
            host=${authority%:*}
            port=${authority##*:}
        else
            host=$authority
        fi
    fi

    CLIENT_HOST=$host
    CLIENT_PORT=$port
    CLIENT_PATH=$path
    validate_client_config
}

prompt_nonempty() {
    local prompt=$1 default=${2:-} value
    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "${prompt} [${default}]: " value
            value=${value:-$default}
        else
            read -r -p "${prompt}: " value
        fi
        [[ -n "$value" ]] && { printf -v "$3" '%s' "$value"; return; }
        log_warn "该项不能为空。"
    done
}

interactive_client_config() {
    local current_protocol=${CLIENT_PROTOCOL:-https}
    local choice input default_port confirm

    echo
    echo "================================================"
    echo "        ServerStatus-Rust Client 配置向导"
    echo "================================================"
    echo "准备信息：协议、服务器地址、用户名和密码。"
    echo "示例仅使用 example.com，不包含真实域名。"
    echo "用户名和密码中的 @、:、/、#、空格等字符可直接输入。"
    echo
    echo "协议说明："
    echo "  1) HTTP   默认端口 80，无需填写"
    echo "  2) HTTPS  默认端口 443，无需填写"
    echo "  3) gRPC   默认端口 80，无需填写"
    echo "  4) gRPC TLS（grpcs）默认端口 443，无需填写"
    echo

    case "$current_protocol" in
        http) choice=1 ;;
        https) choice=2 ;;
        grpc) choice=3 ;;
        grpcs) choice=4 ;;
        *) choice=2 ;;
    esac

    while true; do
        read -r -p "请选择协议 [1-4，默认 ${choice}]: " input
        input=${input:-$choice}
        case "$input" in
            1) CLIENT_PROTOCOL="http"; break ;;
            2) CLIENT_PROTOCOL="https"; break ;;
            3) CLIENT_PROTOCOL="grpc"; break ;;
            4) CLIENT_PROTOCOL="grpcs"; break ;;
            *) log_warn "请输入 1-4。" ;;
        esac
    done

    prompt_nonempty "请输入服务器地址（域名、IPv4 或 IPv6）" "${CLIENT_HOST:-example.com}" CLIENT_HOST
    default_port=$(default_port_for_protocol "$CLIENT_PROTOCOL")
    read -r -p "请输入端口（直接回车使用默认端口 ${default_port}，service 中将省略）: " CLIENT_PORT

    if [[ "$CLIENT_PROTOCOL" == "http" || "$CLIENT_PROTOCOL" == "https" ]]; then
        read -r -p "请输入上报路径 [${CLIENT_PATH:-/report}]: " input
        CLIENT_PATH=${input:-${CLIENT_PATH:-/report}}
    else
        CLIENT_PATH=""
    fi

    prompt_nonempty "请输入用户名" "${CLIENT_USER:-}" CLIENT_USER
    while true; do
        read -r -s -p "请输入密码（不会显示，特殊字符可直接输入）: " CLIENT_PASSWORD
        echo
        [[ -n "$CLIENT_PASSWORD" ]] && break
        log_warn "密码不能为空。"
    done

    validate_client_config

    echo
    echo "================ 配置确认 ================"
    echo "协议：${CLIENT_PROTOCOL}"
    echo "地址：$(build_endpoint)"
    echo "用户：${CLIENT_USER}"
    echo "密码：********"
    echo "默认端口已自动省略，特殊字符将自动转义。"
    echo "=========================================="
    read -r -p "确认继续？[Y/n]: " confirm
    [[ ! "$confirm" =~ ^[Nn]$ ]] || die "用户取消操作。"
}

systemd_quote_arg() {
    local value=$1
    validate_no_control_chars "systemd 参数" "$value"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\$/\$\$}
    value=${value//%/%%}
    printf '"%s"' "$value"
}

read_unit_metadata() {
    [[ -f "$CLIENT_UNIT" ]] || return 1
    local line value

    value=$(sed -n 's/^# STATUS_PROTOCOL=//p' "$CLIENT_UNIT" | head -n1)
    [[ -n "$value" ]] || return 1
    CLIENT_PROTOCOL=$value
    CLIENT_PORT=$(sed -n 's/^# STATUS_PORT=//p' "$CLIENT_UNIT" | head -n1)

    line=$(sed -n 's/^# STATUS_HOST_B64=//p' "$CLIENT_UNIT" | head -n1)
    CLIENT_HOST=$(b64_decode "$line")
    line=$(sed -n 's/^# STATUS_PATH_B64=//p' "$CLIENT_UNIT" | head -n1)
    CLIENT_PATH=$(b64_decode "$line")
    line=$(sed -n 's/^# STATUS_USER_B64=//p' "$CLIENT_UNIT" | head -n1)
    CLIENT_USER=$(b64_decode "$line")
    return 0
}

get_unit_release_version() {
    local unit=$1
    [[ -f "$unit" ]] || { printf 'unknown'; return; }
    sed -n 's/^# ReleaseVersion=//p' "$unit" | head -n1
}

verify_unit_file() {
    local unit=$1
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze verify "$unit" >/dev/null 2>"${TMP_DIR}/systemd-verify.log"; then
            cat "${TMP_DIR}/systemd-verify.log" >&2
            return 1
        fi
    fi
    return 0
}

write_client_unit_to() {
    local destination=$1 release=${2:-unknown}
    local endpoint exec_binary exec_endpoint exec_user exec_password
    endpoint=$(build_endpoint)
    exec_binary=$(systemd_quote_arg "$CLIENT_FILE")
    exec_endpoint=$(systemd_quote_arg "$endpoint")
    exec_user=$(systemd_quote_arg "$CLIENT_USER")
    exec_password=$(systemd_quote_arg "$CLIENT_PASSWORD")

    cat >"$destination" <<EOF
# ScriptVersion=${SCRIPT_VERSION}
# ReleaseVersion=${release}
# STATUS_PROTOCOL=${CLIENT_PROTOCOL}
# STATUS_PORT=${CLIENT_PORT}
# STATUS_HOST_B64=$(b64_encode "$CLIENT_HOST")
# STATUS_PATH_B64=$(b64_encode "$CLIENT_PATH")
# STATUS_USER_B64=$(b64_encode "$CLIENT_USER")
[Unit]
Description=ServerStatus-Rust Client
Documentation=https://github.com/${REPO}
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60s
StartLimitBurst=5

[Service]
Type=simple
User=root
Group=root
Environment="RUST_BACKTRACE=1"
WorkingDirectory=${CLIENT_DIR}
ExecStart=${exec_binary} -a ${exec_endpoint} -u ${exec_user} -p ${exec_password}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$destination"
}

write_server_unit_to() {
    local destination=$1 release=${2:-unknown}
    cat >"$destination" <<EOF
# ScriptVersion=${SCRIPT_VERSION}
# ReleaseVersion=${release}
[Unit]
Description=ServerStatus-Rust Server
Documentation=https://github.com/${REPO}
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60s
StartLimitBurst=5

[Service]
Type=simple
Environment="RUST_BACKTRACE=1"
WorkingDirectory=${SERVER_DIR}
ExecStart=${SERVER_FILE} -c ${SERVER_TOML}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$destination"
}

show_service_failure() {
    local service=$1
    log_error "${service} 启动失败，最近日志如下："
    systemctl --no-pager --full status "$service" || true
    journalctl -u "$service" -n 50 --no-pager || true
}

start_and_check() {
    local service=$1
    systemctl daemon-reload
    systemctl enable "$service" >/dev/null
    systemctl restart "$service"
    sleep 2
    systemctl is-active --quiet "$service" || { show_service_failure "$service"; return 1; }
}

atomic_install_unit() {
    local generated="$1"
    local target="$2"
    local service="$3"
    local backup

    backup="${TMP_DIR}/$(basename "$target").previous"

    [[ -f "$target" ]] && cp -a "$target" "$backup"
    install -m 0644 "$generated" "$target"

    if ! start_and_check "$service"; then
        log_warn "新配置启动失败，正在回滚 systemd 配置。"
        if [[ -f "$backup" ]]; then
            install -m 0644 "$backup" "$target"
        else
            rm -f "$target"
        fi
        systemctl daemon-reload
        systemctl restart "$service" 2>/dev/null || true
        return 1
    fi
}

install_binary_with_rollback() {
    local source=$1 target=$2 service=${3:-} backup="${TMP_DIR}/$(basename "$target").previous"
    mkdir -p "$(dirname "$target")"
    [[ -f "$target" ]] && cp -a "$target" "$backup"
    install -m 0755 "$source" "$target"

    if [[ -n "$service" ]] && systemctl list-unit-files "$service" >/dev/null 2>&1; then
        if ! start_and_check "$service"; then
            log_warn "新二进制启动失败，正在回滚。"
            [[ -f "$backup" ]] && install -m 0755 "$backup" "$target"
            systemctl restart "$service" 2>/dev/null || true
            return 1
        fi
    fi
}

install_client() {
    local quick_uri=${1:-} generated binary_backup="${TMP_DIR}/stat_client.previous" had_binary=false
    progress 1 6 "检查系统环境"
    [[ -n "$quick_uri" ]] && parse_quick_uri "$quick_uri" || interactive_client_config

    progress 2 6 "获取最新发布版本"
    RELEASE_VERSION=$(get_latest_version)
    log_info "目标版本：${RELEASE_VERSION}"

    progress 3 6 "下载并校验 Client"
    download_component client

    progress 4 6 "安装 Client 二进制"
    mkdir -p "$CLIENT_DIR"
    if [[ -f "$CLIENT_FILE" ]]; then
        cp -a "$CLIENT_FILE" "$binary_backup"
        had_binary=true
    fi
    install -m 0755 "$DOWNLOADED_BINARY" "$CLIENT_FILE"

    progress 5 6 "生成并校验 systemd 服务"
    generated="${TMP_DIR}/${CLIENT_SERVICE}"
    write_client_unit_to "$generated" "$RELEASE_VERSION"
    if ! verify_unit_file "$generated"; then
        $had_binary && install -m 0755 "$binary_backup" "$CLIENT_FILE" || rm -f "$CLIENT_FILE"
        die "systemd unit 校验失败，Client 二进制已回滚。"
    fi

    progress 6 6 "启动 Client 并检查状态"
    if ! atomic_install_unit "$generated" "$CLIENT_UNIT" "$CLIENT_SERVICE"; then
        $had_binary && install -m 0755 "$binary_backup" "$CLIENT_FILE" || rm -f "$CLIENT_FILE"
        systemctl restart "$CLIENT_SERVICE" 2>/dev/null || true
        die "Client 安装失败，原二进制和配置已回滚。"
    fi

    log_success "ServerStatus Client 安装完成。"
    echo "上报地址：$(build_endpoint)"
    echo "查看状态：systemctl status ${CLIENT_SERVICE}"
    echo "查看日志：journalctl -u ${CLIENT_SERVICE} -f"
}

install_server() {
    local generated binary_backup="${TMP_DIR}/stat_server.previous" had_binary=false config_created=false
    progress 1 5 "检查系统环境"
    progress 2 5 "获取最新发布版本"
    RELEASE_VERSION=$(get_latest_version)
    log_info "目标版本：${RELEASE_VERSION}"

    progress 3 5 "下载并校验 Server"
    download_component server

    progress 4 5 "安装 Server 文件"
    mkdir -p "$SERVER_DIR"
    if [[ -f "$SERVER_FILE" ]]; then
        cp -a "$SERVER_FILE" "$binary_backup"
        had_binary=true
    fi
    install -m 0755 "$DOWNLOADED_BINARY" "$SERVER_FILE"
    if [[ ! -f "$SERVER_TOML" ]]; then
        [[ -n "$DOWNLOADED_CONFIG" && -f "$DOWNLOADED_CONFIG" ]] || {
            $had_binary && install -m 0755 "$binary_backup" "$SERVER_FILE" || rm -f "$SERVER_FILE"
            die "发布包中未找到 config.toml。"
        }
        install -m 0600 "$DOWNLOADED_CONFIG" "$SERVER_TOML"
        config_created=true
    else
        log_info "保留现有配置：${SERVER_TOML}"
    fi

    progress 5 5 "生成服务并启动 Server"
    generated="${TMP_DIR}/${SERVER_SERVICE}"
    write_server_unit_to "$generated" "$RELEASE_VERSION"
    if ! verify_unit_file "$generated"; then
        $had_binary && install -m 0755 "$binary_backup" "$SERVER_FILE" || rm -f "$SERVER_FILE"
        $config_created && rm -f "$SERVER_TOML"
        die "systemd unit 校验失败，Server 文件已回滚。"
    fi
    if ! atomic_install_unit "$generated" "$SERVER_UNIT" "$SERVER_SERVICE"; then
        $had_binary && install -m 0755 "$binary_backup" "$SERVER_FILE" || rm -f "$SERVER_FILE"
        $config_created && rm -f "$SERVER_TOML"
        systemctl restart "$SERVER_SERVICE" 2>/dev/null || true
        die "Server 安装失败，原文件和配置已回滚。"
    fi

    log_success "ServerStatus Server 安装完成。"
}

reconfigure_client() {
    local quick_uri=${1:-} generated release
    [[ -x "$CLIENT_FILE" ]] || die "尚未安装 Client：${CLIENT_FILE}"

    if [[ -n "$quick_uri" ]]; then
        parse_quick_uri "$quick_uri"
    else
        if read_unit_metadata; then
            log_info "已读取当前配置。密码不会显示，请重新输入密码。"
        else
            log_warn "无法读取旧版 service 元数据，将进入完整配置。"
            CLIENT_PROTOCOL="https"
            CLIENT_HOST="example.com"
            CLIENT_PATH="/report"
            CLIENT_PORT=""
            CLIENT_USER=""
        fi
        interactive_client_config
    fi

    release=$(get_unit_release_version "$CLIENT_UNIT")
    [[ -n "$release" ]] || release="unknown"
    generated="${TMP_DIR}/${CLIENT_SERVICE}"
    write_client_unit_to "$generated" "$release"
    verify_unit_file "$generated"
    atomic_install_unit "$generated" "$CLIENT_UNIT" "$CLIENT_SERVICE" || die "重新配置失败，原配置已回滚。"
    log_success "Client 配置已更新。"
}

upgrade_component() {
    local component=$1 binary unit service current latest backup
    case "$component" in
        client)
            binary=$CLIENT_FILE; unit=$CLIENT_UNIT; service=$CLIENT_SERVICE ;;
        server)
            binary=$SERVER_FILE; unit=$SERVER_UNIT; service=$SERVER_SERVICE ;;
        *) die "未知组件：$component" ;;
    esac

    [[ -x "$binary" ]] || die "尚未安装 ${component}。"
    current=$(get_unit_release_version "$unit")
    latest=$(get_latest_version)
    [[ "$latest" != "unknown" ]] || die "无法获取最新版本号。"

    log_info "当前版本：${current:-unknown}；最新版本：${latest}"
    if [[ "$current" == "$latest" && "${FORCE:-false}" != "true" ]]; then
        log_success "已是最新版本。设置 FORCE=true 可强制重装。"
        return
    fi

    download_component "$component"
    backup="${TMP_DIR}/${component}.previous"
    cp -a "$binary" "$backup"
    systemctl stop "$service" 2>/dev/null || true
    install -m 0755 "$DOWNLOADED_BINARY" "$binary"

    if [[ "$component" == "client" ]]; then
        [[ -f "$unit" ]] && sed -i "s/^# ReleaseVersion=.*/# ReleaseVersion=${latest}/" "$unit"
    else
        [[ -f "$unit" ]] && sed -i "s/^# ReleaseVersion=.*/# ReleaseVersion=${latest}/" "$unit"
    fi

    if ! start_and_check "$service"; then
        log_warn "升级后启动失败，正在恢复旧二进制。"
        install -m 0755 "$backup" "$binary"
        [[ -f "$unit" ]] && sed -i "s/^# ReleaseVersion=.*/# ReleaseVersion=${current:-unknown}/" "$unit"
        systemctl daemon-reload
        systemctl restart "$service" 2>/dev/null || true
        die "升级失败，已尝试回滚。"
    fi
    log_success "${component} 已升级至 ${latest}。"
}

backup_component() {
    local component=$1 stamp destination
    stamp=$(date '+%Y%m%d-%H%M%S')
    destination="${BACKUP_ROOT}/${stamp}/${component}"
    mkdir -p "$destination"
    chmod 700 "${BACKUP_ROOT}/${stamp}"

    case "$component" in
        client)
            [[ -f "$CLIENT_FILE" ]] && cp -a "$CLIENT_FILE" "$destination/"
            [[ -f "$CLIENT_UNIT" ]] && cp -a "$CLIENT_UNIT" "$destination/"
            ;;
        server)
            [[ -f "$SERVER_FILE" ]] && cp -a "$SERVER_FILE" "$destination/"
            [[ -f "$SERVER_TOML" ]] && cp -a "$SERVER_TOML" "$destination/"
            [[ -f "$SERVER_UNIT" ]] && cp -a "$SERVER_UNIT" "$destination/"
            ;;
    esac
    log_success "${component} 已备份至：${destination}"
}

latest_backup_dir() {
    local component=$1
    find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$component" 2>/dev/null | sort | tail -n1
}

restore_component() {
    local component=$1 source service rollback="${TMP_DIR}/restore-${component}" had_binary=false had_unit=false had_config=false
    source=$(latest_backup_dir "$component")
    [[ -n "$source" && -d "$source" ]] || die "未找到 ${component} 备份。"
    confirm_destructive "确认使用最近备份恢复 ${component} 吗？"
    log_info "使用备份：${source}"
    mkdir -p "$rollback"

    case "$component" in
        client)
            [[ -f "$source/stat_client" && -f "$source/${CLIENT_SERVICE}" ]] || die "Client 备份不完整。"
            [[ -f "$CLIENT_FILE" ]] && { cp -a "$CLIENT_FILE" "$rollback/"; had_binary=true; }
            [[ -f "$CLIENT_UNIT" ]] && { cp -a "$CLIENT_UNIT" "$rollback/"; had_unit=true; }
            mkdir -p "$CLIENT_DIR"
            install -m 0755 "$source/stat_client" "$CLIENT_FILE"
            install -m 0644 "$source/${CLIENT_SERVICE}" "$CLIENT_UNIT"
            service=$CLIENT_SERVICE
            ;;
        server)
            [[ -f "$source/stat_server" && -f "$source/${SERVER_SERVICE}" ]] || die "Server 备份不完整。"
            [[ -f "$SERVER_FILE" ]] && { cp -a "$SERVER_FILE" "$rollback/"; had_binary=true; }
            [[ -f "$SERVER_UNIT" ]] && { cp -a "$SERVER_UNIT" "$rollback/"; had_unit=true; }
            [[ -f "$SERVER_TOML" ]] && { cp -a "$SERVER_TOML" "$rollback/"; had_config=true; }
            mkdir -p "$SERVER_DIR"
            install -m 0755 "$source/stat_server" "$SERVER_FILE"
            [[ -f "$source/config.toml" ]] && install -m 0600 "$source/config.toml" "$SERVER_TOML"
            install -m 0644 "$source/${SERVER_SERVICE}" "$SERVER_UNIT"
            service=$SERVER_SERVICE
            ;;
    esac

    if ! start_and_check "$service"; then
        log_warn "备份恢复后服务启动失败，正在恢复操作前状态。"
        case "$component" in
            client)
                $had_binary && install -m 0755 "$rollback/stat_client" "$CLIENT_FILE" || rm -f "$CLIENT_FILE"
                $had_unit && install -m 0644 "$rollback/${CLIENT_SERVICE}" "$CLIENT_UNIT" || rm -f "$CLIENT_UNIT"
                ;;
            server)
                $had_binary && install -m 0755 "$rollback/stat_server" "$SERVER_FILE" || rm -f "$SERVER_FILE"
                $had_unit && install -m 0644 "$rollback/${SERVER_SERVICE}" "$SERVER_UNIT" || rm -f "$SERVER_UNIT"
                $had_config && install -m 0600 "$rollback/config.toml" "$SERVER_TOML" || true
                ;;
        esac
        systemctl daemon-reload
        systemctl restart "$service" 2>/dev/null || true
        die "恢复失败，已尝试回滚。"
    fi
    log_success "${component} 已恢复。"
}


confirm_destructive() {
    local message=$1 answer
    [[ "${YES:-false}" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        die "非交互环境执行破坏性操作时，请显式设置 YES=true。"
    fi
    read -r -p "${message} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "用户取消操作。"
}

uninstall_component() {
    local component=$1 service unit dir
    confirm_destructive "确认卸载 ${component} 并删除其安装目录吗？"
    case "$component" in
        client) service=$CLIENT_SERVICE; unit=$CLIENT_UNIT; dir=$CLIENT_DIR ;;
        server) service=$SERVER_SERVICE; unit=$SERVER_UNIT; dir=$SERVER_DIR ;;
    esac
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    rm -f -- "$unit"
    rm -rf -- "$dir"
    systemctl daemon-reload
    systemctl reset-failed "$service" 2>/dev/null || true
    log_success "${component} 已卸载。"
}

manage_service() {
    local component=$1 action=$2 service
    [[ "$component" == "client" ]] && service=$CLIENT_SERVICE || service=$SERVER_SERVICE
    case "$action" in
        status) systemctl --no-pager --full status "$service" ;;
        start|stop|restart) systemctl "$action" "$service" ;;
        logs) journalctl -u "$service" -n 100 --no-pager ;;
        follow) journalctl -u "$service" -f ;;
        *) die "未知操作：$action（支持 status/start/stop/restart/logs/follow）" ;;
    esac
}

show_client_config() {
    if read_unit_metadata; then
        echo "协议：${CLIENT_PROTOCOL}"
        echo "地址：${CLIENT_HOST}"
        echo "端口：${CLIENT_PORT:-默认端口（service 中省略）}"
        echo "路径：${CLIENT_PATH:-无}"
        echo "用户：${CLIENT_USER}"
        echo "完整上报地址：$(build_endpoint)"
        echo "密码：********"
    else
        die "无法从 ${CLIENT_UNIT} 读取配置。"
    fi
}

doctor() {
    echo "================ ServerStatus 诊断 ================"
    echo "脚本版本：${SCRIPT_VERSION}"
    echo "系统架构：$(uname -m)"
    echo "systemd：$(systemctl --version | head -n1)"
    echo
    for component in client server; do
        local service binary unit
        if [[ "$component" == client ]]; then
            service=$CLIENT_SERVICE; binary=$CLIENT_FILE; unit=$CLIENT_UNIT
        else
            service=$SERVER_SERVICE; binary=$SERVER_FILE; unit=$SERVER_UNIT
        fi
        echo "[${component}]"
        [[ -x "$binary" ]] && echo "  二进制：正常（${binary}）" || echo "  二进制：缺失"
        [[ -f "$unit" ]] && echo "  unit：正常（${unit}）" || echo "  unit：缺失"
        if systemctl is-active --quiet "$service"; then
            echo "  状态：运行中"
        else
            echo "  状态：未运行"
        fi
    done
    echo "===================================================="
}

show_help() {
    cat <<'EOF'
ServerStatus-Rust 管理脚本 v1.7.0

用法：
  bash status.sh -i -c                     交互安装 Client
  bash status.sh -i -c 'URI'               一键安装 Client
  bash status.sh -i -s                     安装 Server

  bash status.sh -rc                       交互修改 Client 配置
  bash status.sh -rc 'URI'                 一键修改 Client 配置

  bash status.sh -up -c|-s|-a              升级 Client/Server/全部
  bash status.sh -un -c|-s|-a              卸载 Client/Server/全部
  bash status.sh -b  -c|-s|-a              备份 Client/Server/全部
  bash status.sh -rs -c|-s|-a              恢复最近一次备份

  bash status.sh -c status|start|stop|restart|logs|follow
  bash status.sh -s status|start|stop|restart|logs|follow
  bash status.sh --show-config              显示 Client 配置（隐藏密码）
  bash status.sh --doctor                   运行诊断

一键配置格式：
  协议://用户名:密码@服务器[:端口][/路径]

匿名示例：
  bash status.sh -i -c 'https://user:p@ss@example.com'
  bash status.sh -i -c 'grpcs://user:p:a@s@s@[2001:db8::1]'
  bash status.sh -rc  'http://user:password@example.com:8080/report'

说明：
  1. 支持 http、https、grpc、grpcs。
  2. HTTP 默认 80、HTTPS 默认 443；默认端口会从 service 地址中省略。
  3. HTTP(S) 未指定路径时自动使用 /report。
  4. 密码中的 @ 和 : 可直接输入，不需要手动写成 %40、%3A。
  5. 命令行中包含 $、空格、&、;、! 等 Shell 特殊字符时，请用单引号包住完整 URI。
  6. 交互模式不会回显密码，是最稳妥的配置方式。
  7. 兼容旧版 %40 编码输入时可设置 DECODE_URI=true；默认不会擅自改写真实的 % 字符。
  8. 非交互执行卸载或恢复时，需要显式设置 YES=true。

中国大陆下载代理：
  CN=true bash status.sh -i -c
  或自定义：MIRROR='https://example-proxy/' bash status.sh ...
EOF
}

setup_mirror() {
    if [[ "${CN:-false}" == "true" && -z "${MIRROR:-}" ]]; then
        MIRROR="https://gh-proxy.com/"
    fi
}

main() {
    local command=${1:-help} sub=${2:-} arg=${3:-}
    setup_traps
    setup_mirror

    case "$command" in
        -h|--help|help) show_help; return ;;
    esac

    preflight

    case "$command" in
        -i|--install)
            case "$sub" in
                -c|--client) install_client "$arg" ;;
                -s|--server) install_server ;;
                *) die "安装参数错误，请使用 -i -c 或 -i -s。" ;;
            esac
            ;;
        -rc|--reconfig)
            reconfigure_client "$sub"
            ;;
        -up|--upgrade)
            case "$sub" in
                -c|--client) upgrade_component client ;;
                -s|--server) upgrade_component server ;;
                -a|--all) upgrade_component server; upgrade_component client ;;
                *) die "升级参数错误，请使用 -up -c、-up -s 或 -up -a。" ;;
            esac
            ;;
        -un|--uninstall)
            case "$sub" in
                -c|--client) uninstall_component client ;;
                -s|--server) uninstall_component server ;;
                -a|--all) uninstall_component client; uninstall_component server ;;
                *) die "卸载参数错误。" ;;
            esac
            ;;
        -b|--backup|--bakup)
            case "$sub" in
                -c|--client) backup_component client ;;
                -s|--server) backup_component server ;;
                -a|--all) backup_component server; backup_component client ;;
                *) die "备份参数错误。" ;;
            esac
            ;;
        -rs|--restore)
            case "$sub" in
                -c|--client) restore_component client ;;
                -s|--server) restore_component server ;;
                -a|--all) restore_component server; restore_component client ;;
                *) die "恢复参数错误。" ;;
            esac
            ;;
        -c|--client)
            manage_service client "${sub:-status}"
            ;;
        -s|--server)
            manage_service server "${sub:-status}"
            ;;
        --show-config)
            show_client_config
            ;;
        --doctor)
            doctor
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
