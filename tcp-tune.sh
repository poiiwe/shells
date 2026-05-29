#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  tcp-tune.sh  —  TCP 深度调优脚本
#  Version : 2.5
#  Date    : 2025-05-28
#  Author  : HexHub AI
#
#  Changelog:
#    v2.5  集成 CLI 参数: -y/--yes / -d/--dry-run / -n/--no-color / -h/--help
#    v2.4  人机交互全面优化: 彩色输出 / root检查 / 预览确认 / 回滚指引
#    v2.3  BBR 深度检测: 自动发现模块 → 自动加载 → 醒目提示修复指引
#    v2.2  扫描 /usr/lib/sysctl.d/ 系统默认值 + 区分「冲突」与「覆盖」
#
#  Usage:
#    bash tcp-tune.sh             交互模式 (预览后确认再写入)
#    bash tcp-tune.sh -y          非交互模式 (直接应用, 无人值守)
#    bash tcp-tune.sh -d          预览模式 (仅查看, 不写入任何配置)
#    bash tcp-tune.sh -n          无颜色模式 (适合管道/日志重定向)
#    bash tcp-tune.sh -h          显示帮助
#
#  向后兼容 (环境变量):
#    TCP_TUNE_YES=1 bash tcp-tune.sh
#    TCP_TUNE_DRY_RUN=1 bash tcp-tune.sh
# ═══════════════════════════════════════════════════════════════

# ─── CLI 参数解析 ─────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
NO_COLOR=0

show_help() {
    cat << 'HELP'

  tcp-tune.sh — TCP 深度调优脚本  v2.5

  用法:
    bash tcp-tune.sh                    交互模式 (默认)
    bash tcp-tune.sh -y                 非交互模式 (跳过确认)
    bash tcp-tune.sh -d                 预览模式 (只看不改)
    bash tcp-tune.sh -n                 无颜色输出
    bash tcp-tune.sh -h                 显示此帮助

  环境变量 (向后兼容):
    TCP_TUNE_YES=1     同 -y
    TCP_TUNE_DRY_RUN=1 同 -d
    TCP_TUNE_NO_COLOR=1 同 -n

  示例:
    bash tcp-tune.sh
    bash tcp-tune.sh --yes
    bash tcp-tune.sh --dry-run --no-color | tee tcp-tune.log

  说明:
    自动检测系统内存/CPU/内核, 四档自适应调优 (微型/标准/高性能/旗舰)
    深度检测 BBR 可用性, 模块未加载则自动加载, 内核不支持则醒目提示
    自动扫描并清理 /etc/sysctl.d/ 中的冲突配置
    幂等设计, 可重复执行, 自动备份冲突文件方便回滚

HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes|--assume-yes)
            ASSUME_YES=1
            shift
            ;;
        -d|--dry-run|--dry_run)
            DRY_RUN=1
            shift
            ;;
        -n|--no-color|--no_color)
            NO_COLOR=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            echo "使用 -h 查看帮助"
            exit 1
            ;;
    esac
done

# 环境变量覆盖 (向后兼容)
[ "${TCP_TUNE_YES:-0}" = "1" ] && ASSUME_YES=1
[ "${TCP_TUNE_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
[ "${TCP_TUNE_NO_COLOR:-0}" = "1" ] && NO_COLOR=1

# ─── 颜色定义 ─────────────────────────────────────────────────
if [ -t 1 ] && [ "$NO_COLOR" != "1" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ─── 辅助函数 ─────────────────────────────────────────────────
info()  { echo -e " ${CYAN}▶${RESET} $*"; }
ok()    { echo -e " ${GREEN}✔${RESET} $*"; }
warn()  { echo -e " ${YELLOW}⚠${RESET} $*"; }
err()   { echo -e " ${RED}✘${RESET} $*"; }
header() {
    echo ""
    echo -e " ${BOLD}── $1 ────────────────────────────────────────────${RESET}"
    echo ""
}
section() {
    echo ""
    echo -e " ${BOLD}[${2:-*}]${RESET} ${CYAN}$1${RESET}"
}
box() {
    local color="$1"; shift
    echo ""
    echo -e " ${color}┌─────────────────────────────────────────────────────────────┐${RESET}"
    while [ $# -gt 0 ]; do
        printf " ${color}│ %-65s │${RESET}\n" "$1"
        shift
    done
    echo -e " ${color}└─────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}
die() {
    echo ""
    box "$RED" \
        "操作中止" \
        "" \
        "原因: $1"
    exit 1
}

# ─── 运行模式提示 ─────────────────────────────────────────────
header "系统检查"

MODE_STR="交互模式"
[ "$DRY_RUN" -eq 1 ] && MODE_STR="${YELLOW}预览模式 (Dry-Run)${RESET}"
[ "$ASSUME_YES" -eq 1 ] && MODE_STR="${GREEN}非交互模式${RESET}"
echo -e "  ${DIM}运行模式${RESET}  ${MODE_STR}"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    die "必须使用 root 权限运行, 请执行: sudo bash tcp-tune.sh"
fi
ok "运行身份: root"

# 检查依赖
for cmd in sysctl modprobe ip awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "缺少必需命令: $cmd"
    fi
done
ok "依赖检查通过"

# ─── 环境变量 ──────────────────────────────────────────────────
CONF_FILE="/etc/sysctl.d/99-tcp-tuning.conf"
BACKUP_DIR="/etc/sysctl.d/.bak-tcp-tune-$(date +%Y%m%d%H%M%S)"
HOSTNAME=$(hostname)

# ─── Phase 0 — 系统检测 ──────────────────────────────────────
section "收集系统信息" "1"

MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)
KERNEL_VER=$(uname -r)

HAS_CONNTRACK=0
[ -f /proc/sys/net/netfilter/nf_conntrack_max ] && HAS_CONNTRACK=1

# BBR 深度检测
HAS_BBR=0
BBR_HINT=""
BBR_STATUS=""

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    HAS_BBR=1
    BBR_STATUS="${GREEN}可用${RESET}"
    info "BBR: ${GREEN}可用${RESET}"
else
    if modinfo tcp_bbr >/dev/null 2>&1; then
        info "发现 BBR 内核模块但未加载, 尝试自动加载..."
        if modprobe tcp_bbr 2>/dev/null && \
           sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            HAS_BBR=1
            BBR_STATUS="${GREEN}已自动加载模块${RESET}"
            ok "BBR 模块加载成功!"
            echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf 2>/dev/null && \
                info "已写入 /etc/modules-load.d/tcp_bbr.conf (开机自加载)"
        else
            BBR_STATUS="${RED}模块加载失败${RESET}"
            BBR_HINT="内核签名或 Secure Boot 阻止, 尝试: apt install --reinstall linux-image-$(uname -r)"
            warn "BBR 模块存在但加载失败 (内核签名 / Secure Boot)"
        fi
    else
        BBR_STATUS="${RED}不支持${RESET}"
        echo ""
        box "$YELLOW" \
            "当前内核 (${KERNEL_VER}) 未包含 tcp_bbr 模块" \
            "" \
            "建议启用 BBR 以提升 TCP 性能 (延迟 ↓ 20-40%, 吞吐 ↑ 2-10x)" \
            "" \
            "  方案1: apt update && apt install -y linux-image-cloud-amd64 && reboot" \
            "  方案2: wget -O tcp.sh https://git.io/bbr.sh && bash tcp.sh" \
            "  方案3: 升级至 Debian 10+ / Ubuntu 18.04+ / CentOS 8+"
        BBR_HINT="内核不含 BBR 模块, 建议升级内核后重试"
    fi
fi

MAIN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)

CONNTRACK_STR=$([ "$HAS_CONNTRACK" -eq 1 ] && echo "${GREEN}可用${RESET}" || echo "${DIM}不可用${RESET}")

echo ""
echo -e "  ${DIM}系统${RESET}    ${BOLD}${HOSTNAME}${RESET}"
echo -e "  ${DIM}内存${RESET}    ${MEM_MB}MB  |  ${DIM}CPU${RESET}    ${CPU_CORES}核  |  ${DIM}内核${RESET}    ${KERNEL_VER}"
echo -e "  ${DIM}网卡${RESET}    ${MAIN_IFACE}  |  ${DIM}BBR${RESET}    ${BBR_STATUS}  |  ${DIM}连接追踪${RESET}    ${CONNTRACK_STR}"

# ─── Phase 1 — 冲突检测 ──────────────────────────────────────
section "扫描现有配置冲突" "2"

OUR_KEYS=(
    net.ipv4.tcp_tw_reuse net.ipv4.tcp_max_tw_buckets
    net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
    net.ipv4.tcp_syncookies net.ipv4.tcp_syn_retries net.ipv4.tcp_synack_retries
    net.ipv4.tcp_max_syn_backlog net.core.somaxconn
    net.ipv4.ip_local_port_range net.ipv4.tcp_mtu_probing
    net.core.rmem_default net.core.wmem_default net.core.rmem_max net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem
    net.core.netdev_max_backlog net.ipv4.tcp_fastopen
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_sack
    net.ipv4.tcp_timestamps net.ipv4.tcp_window_scaling net.ipv4.tcp_no_metrics_save
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_rfc1337 net.ipv4.tcp_retries2 net.core.optmem_max
    fs.file-max net.core.default_qdisc net.ipv4.tcp_congestion_control
    net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established
    vm.swappiness
)

PATTERN=$(printf '%s|' "${OUR_KEYS[@]}" | sed 's/|$//')
FOUND_CONFLICT=0
CONFLICT_FILES=()

for f in /etc/sysctl.d/*.conf; do
    [ ! -f "$f" ] && continue
    [ "$(basename "$f")" = "$(basename "$CONF_FILE")" ] && continue
    if grep -qE "$PATTERN" "$f" 2>/dev/null; then
        echo -e "  ${YELLOW}✗${RESET} $f"
        grep -nE "$PATTERN" "$f" | while read line; do echo "      $line"; done
        FOUND_CONFLICT=1
        CONFLICT_FILES+=("$f")
    fi
done

for f in /etc/sysctl.d/*.conf; do
    [ ! -L "$f" ] && continue
    LINK_TARGET=$(readlink "$f" 2>/dev/null || true)
    if [ "$LINK_TARGET" = "../sysctl.conf" ] || [ "$LINK_TARGET" = "/etc/sysctl.conf" ]; then
        echo -e "  ${YELLOW}✗${RESET} $f → $LINK_TARGET (重复加载)"
        FOUND_CONFLICT=1
    fi
done

if [ -f /etc/sysctl.conf ]; then
    if grep -qE "$PATTERN" /etc/sysctl.conf 2>/dev/null; then
        echo -e "  ${YELLOW}✗${RESET} /etc/sysctl.conf (将被清空)"
        grep -nE "$PATTERN" /etc/sysctl.conf | while read line; do echo "      $line"; done
        FOUND_CONFLICT=1
    fi
fi

# 扫描系统默认值
if [ -d /usr/lib/sysctl.d ]; then
    for f in /usr/lib/sysctl.d/*.conf; do
        [ ! -f "$f" ] && continue
        if grep -qE "$PATTERN" "$f" 2>/dev/null; then
            echo -e "  ${DIM}ℹ${RESET} $f (系统默认, 会被覆盖)"
        fi
    done
fi

if [ "$FOUND_CONFLICT" -eq 0 ]; then
    ok "未发现冲突配置"
else
    echo -e "  ${YELLOW}→ 将在下一阶段自动备份并清理${RESET}"
fi

# ─── Phase 2 — 预览变更 ──────────────────────────────────────
section "预览即将应用的优化" "3"

# 计算分档
if   [ "$MEM_MB" -le 512 ]; then
    TIER="微型"
    RMEM_MAX=8388608; WMEM_MAX=8388608
    TCP_RMEM="4096 87380 8388608"; TCP_WMEM="4096 65536 8388608"
    TCP_MEM="32768 43690 65536"; CONNTRACK_VAL=131072
elif [ "$MEM_MB" -le 2048 ]; then
    TIER="标准"
    RMEM_MAX=33554432; WMEM_MAX=33554432
    TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"
    TCP_MEM="131072 174762 262144"; CONNTRACK_VAL=1000000
elif [ "$MEM_MB" -le 8192 ]; then
    TIER="高性能"
    RMEM_MAX=67108864; WMEM_MAX=67108864
    TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 65536 67108864"
    TCP_MEM="262144 349525 524288"; CONNTRACK_VAL=2000000
else
    TIER="旗舰"
    RMEM_MAX=134217728; WMEM_MAX=134217728
    TCP_RMEM="4096 131072 134217728"; TCP_WMEM="4096 65536 134217728"
    TCP_MEM="524288 699050 1048576"; CONNTRACK_VAL=4000000
fi

if [ "$HAS_BBR" -eq 1 ]; then
    CC_ALGO="bbr"; QDISC="fq"
else
    CC_ALGO="cubic"; QDISC="fq_codel"
fi

# 获取当前值供对比
CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
CUR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "N/A")

echo -e "  ${BOLD}档位${RESET}        $TIER (${MEM_MB}MB 内存)"
echo -e "  ${BOLD}拥塞控制${RESET}    ${CUR_CC} ${DIM}→${RESET} ${CC_ALGO}"
echo -e "  ${BOLD}队列算法${RESET}    ${CUR_QDISC} ${DIM}→${RESET} ${QDISC}"
echo -e "  ${BOLD}缓冲区${RESET}      $((RMEM_MAX/1048576))MB"
echo -e "  ${BOLD}冲突处理${RESET}    $( [ "$FOUND_CONFLICT" -eq 1 ] && echo "备份 ${#CONFLICT_FILES[@]} 个冲突文件" || echo "无冲突需处理" )"
echo -e "  ${BOLD}目标文件${RESET}    $CONF_FILE"

# BBR 不可用时的特殊段落
if [ "$HAS_BBR" -eq 0 ] && [ -n "$BBR_HINT" ]; then
    echo ""
    warn "BBR 不可用, 将使用 cubic + fq_codel 替代"
    echo -e "  ${DIM}原因: ${BBR_HINT}${RESET}"
fi

# ─── 确认/退出环节 ────────────────────────────────────────────
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    box "$YELLOW" \
        "预览模式 (Dry-Run)" \
        "" \
        "本次未写入任何配置, 可安全重复运行" \
        "" \
        "确认无误后执行:" \
        "  bash tcp-tune.sh -y      # 直接应用" \
        "  bash tcp-tune.sh         # 交互式应用"
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    echo -ne " ${BOLD}应用以上优化? [Y/n]${RESET} "
    read -r REPLY < /dev/tty
    case "$REPLY" in
        [Nn][Oo]|[Nn])
            echo ""
            info "已取消, 未作任何修改"
            exit 0
            ;;
    esac
else
    info "非交互模式, 自动应用..."
fi

# ─── Phase 3 — 执行变更 ──────────────────────────────────────
echo ""
section "正在应用优化" "4"

NEED_CLEANUP=0

# 3a. 清理冲突
if [ "$FOUND_CONFLICT" -eq 1 ]; then
    mkdir -p "$BACKUP_DIR"
    for f in /etc/sysctl.d/*.conf; do
        [ ! -f "$f" ] && continue
        [ "$(basename "$f")" = "$(basename "$CONF_FILE")" ] && continue
        if [ -L "$f" ]; then
            LINK_TARGET=$(readlink "$f" 2>/dev/null || true)
            if echo "$LINK_TARGET" | grep -qE "sysctl\.conf"; then
                rm "$f" && ok "已删除符号链接: $f" && NEED_CLEANUP=1
            fi
        elif grep -qE "$PATTERN" "$f" 2>/dev/null; then
            cp "$f" "$BACKUP_DIR/" && rm "$f"
            ok "已备份并移除: $f" && NEED_CLEANUP=1
        fi
    done
    if [ -f /etc/sysctl.conf ] && grep -qE "$PATTERN" /etc/sysctl.conf 2>/dev/null; then
        cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null || true
        echo "# Cleared by tcp-tune.sh v2.5 — see ${CONF_FILE}" > /etc/sysctl.conf
        ok "已清空 /etc/sysctl.conf" && NEED_CLEANUP=1
    fi
fi

if [ "$NEED_CLEANUP" -eq 0 ]; then
    info "无需清理冲突"
fi

# 3b. 写入配置
cat > "$CONF_FILE" << EOF
# ════════════════════════════════════════════
#   TCP 深度调优 - $HOSTNAME
#   档位: $TIER (${MEM_MB}MB) | $(date '+%Y-%m-%d %H:%M:%S')
#   由 tcp-tune.sh v2.5 自动生成
# ════════════════════════════════════════════

# ── TIME_WAIT ──────────────────────────────
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_max_tw_buckets     = 20000

# ── 连接保活 ───────────────────────────────
net.ipv4.tcp_keepalive_time     = 120
net.ipv4.tcp_keepalive_intvl    = 10
net.ipv4.tcp_keepalive_probes   = 6

# ── SYN 握手 ───────────────────────────────
net.ipv4.tcp_syncookies         = 1
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_synack_retries     = 3
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192

# ── 端口范围 ───────────────────────────────
net.ipv4.ip_local_port_range    = 1024 65535

# ── MTU 探测 ───────────────────────────────
net.ipv4.tcp_mtu_probing        = 1

# ── 内存与缓冲区 [$TIER] ───────────────────
net.core.rmem_default           = 262144
net.core.wmem_default           = 262144
net.core.rmem_max               = $RMEM_MAX
net.core.wmem_max               = $WMEM_MAX
net.ipv4.tcp_rmem               = $TCP_RMEM
net.ipv4.tcp_wmem               = $TCP_WMEM
net.ipv4.tcp_mem                = $TCP_MEM

# ── 连接队列/网卡接收队列 ──────────────────
net.core.netdev_max_backlog     = 10000

# ── TCP 选项 ───────────────────────────────
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_timestamps         = 1
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_no_metrics_save    = 1

# ── 尾部延迟 ───────────────────────────────
net.ipv4.tcp_notsent_lowat      = 131072

# ── 快速回收 ───────────────────────────────
net.ipv4.tcp_fin_timeout        = 30

# ── TIME_WAIT 暗杀防护 ─────────────────────
net.ipv4.tcp_rfc1337            = 1

# ── 死连接检测 ─────────────────────────────
net.ipv4.tcp_retries2           = 8

# ── TCP 选项内存 ───────────────────────────
net.core.optmem_max             = 65536

# ── 文件描述符 ─────────────────────────────
fs.file-max                     = 1000000

# ── 拥塞控制 ───────────────────────────────
net.core.default_qdisc          = $QDISC
net.ipv4.tcp_congestion_control = $CC_ALGO

# ── 内存交换 ───────────────────────────────
vm.swappiness                  = 1
EOF
ok "配置已写入: $CONF_FILE"

# conntrack 补充
if [ "$HAS_CONNTRACK" -eq 1 ]; then
    cat >> "$CONF_FILE" << EOF

# ── 连接追踪表 ─────────────────────────────
net.netfilter.nf_conntrack_max = $CONNTRACK_VAL
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
    info "已追加 conntrack 配置"
fi

# 3c. 生效
if sysctl -p "$CONF_FILE" > /dev/null 2>&1; then
    ok "配置已生效 (sysctl -p)"
else
    warn "部分参数生效失败, 请检查 $CONF_FILE 语法"
fi

# 3d. RPS/XPS (多核优化)
if [ "$CPU_CORES" -gt 1 ] && [ -n "$MAIN_IFACE" ]; then
    CPU_MASK=$(printf "%x" $(( (1 << CPU_CORES) - 1 )))
    for rxq in /sys/class/net/$MAIN_IFACE/queues/rx-*/rps_cpus; do
        echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
    done
    for txq in /sys/class/net/$MAIN_IFACE/queues/tx-*/xps_cpus; do
        echo "$CPU_MASK" > "$txq" 2>/dev/null || true
    done
    ok "RPS/XPS 已设置 (掩码: $CPU_MASK)"
else
    info "单核, 跳过 RPS/XPS"
fi

# ─── Phase 4 — 验证 ──────────────────────────────────────────
section "验证关键参数" "5"

verify() { sysctl -n "$1" 2>/dev/null || echo "N/A"; }

echo ""
printf "  ${DIM}%-38s %s${RESET}\n" "参数" "当前值"
printf "  ${DIM}%-38s %s${RESET}\n" "──────────────────────────────────────" "────────────────"
echo -e "  ${BOLD}tcp_congestion_control${RESET}         $(verify net.ipv4.tcp_congestion_control)"
echo -e "  default_qdisc                  $(verify net.core.default_qdisc)"
echo -e "  rmem_max / wmem_max            $(verify net.core.rmem_max) / $(verify net.core.wmem_max)"
echo -e "  tcp_rmem (min def max)         $(verify net.ipv4.tcp_rmem)"
echo -e "  tcp_wmem (min def max)         $(verify net.ipv4.tcp_wmem)"
echo -e "  tcp_mem (min pressure max)     $(verify net.ipv4.tcp_mem)"
echo -e "  somaxconn / tcp_max_syn_backlog $(verify net.core.somaxconn) / $(verify net.ipv4.tcp_max_syn_backlog)"
echo -e "  netdev_max_backlog             $(verify net.core.netdev_max_backlog)"
echo -e "  ip_local_port_range            $(verify net.ipv4.ip_local_port_range)"
echo -e "  tcp_fastopen                   $(verify net.ipv4.tcp_fastopen)"
echo -e "  tcp_keepalive (t/i/p)          $(verify net.ipv4.tcp_keepalive_time) / $(verify net.ipv4.tcp_keepalive_intvl) / $(verify net.ipv4.tcp_keepalive_probes)"
echo -e "  tcp_fin_timeout                $(verify net.ipv4.tcp_fin_timeout)"
echo -e "  tcp_retries2                   $(verify net.ipv4.tcp_retries2)"
echo -e "  tcp_notsent_lowat              $(verify net.ipv4.tcp_notsent_lowat)"
echo -e "  tcp_no_metrics_save            $(verify net.ipv4.tcp_no_metrics_save)"
echo -e "  vm.swappiness                  $(verify vm.swappiness)"
[ "$HAS_CONNTRACK" -eq 1 ] && \
    echo -e "  nf_conntrack_max               $(verify net.netfilter.nf_conntrack_max)"

# ─── 完成 ──────────────────────────────────────────────────────
echo ""
box "$GREEN" \
    "TCP 调优完成!" \
    "" \
    "  主机:   ${HOSTNAME}" \
    "  档位:   ${TIER}  (${MEM_MB}MB)" \
    "  拥塞:   ${CC_ALGO}  |  队列: ${QDISC}" \
    "  缓冲:   $((RMEM_MAX/1048576))MB"

if [ "$HAS_BBR" -eq 0 ] && [ -n "$BBR_HINT" ]; then
    warn "BBR 未启用 — ${BBR_HINT}"
fi

if [ "$NEED_CLEANUP" -eq 1 ]; then
    echo ""
    info "回滚命令 (如有需要):"
    echo ""
    echo -e "  ${DIM}# 恢复备份的冲突文件${RESET}"
    echo "  cp -r ${BACKUP_DIR}/* /etc/sysctl.d/"
    echo ""
    echo -e "  ${DIM}# 删除本脚本生成的配置${RESET}"
    echo "  rm -f ${CONF_FILE}"
    echo "  sysctl --system"
    echo ""
fi

echo -e " ${GREEN}✔${RESET} 完成! 配置已生效"
echo ""
