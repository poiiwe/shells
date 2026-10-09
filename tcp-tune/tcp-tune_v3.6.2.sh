#!/usr/bin/env bash
# tcp-tune.sh - throughput-oriented Linux TCP/qdisc tuning assistant
# License: MIT
#
# v3.6.2:
# · TCP 累计计数保留十进制文本，避免科学计数法与 awk %d 截断。
# · 自适应状态归一化十进制；空样本安全跳过，零流量基线不反复初始化。
# · latest/baseline 备份指针纳入事务快照，失败时同步恢复。
# v3.6.1:
# · 单流缓冲策略合并到默认 streaming 场景；single 仅作为旧参数兼容别名。
# · 状态检查与备份选择在锁内复核，避免并发切换/恢复使用过期状态。
# · status 复用 sysctl 文件与连接快照，减少重复扫描。
# · 主菜单直接提供单线程入口；--version 显示版本和实际运行文件。
# · diagnose --test-port 按测速端口筛选，并检查旧调优参数与实际连接限制。
# v3.6.0:
# · single 单线程优先：BBR + FQ + 不整形，增加有界的自动调节缓冲预算。
# · 自适应增加 throughput / balanced 重传策略，吞吐策略允许少量重传并更快回升。
# · diagnose 显示窗口、内存压力和现有 TCP 连接；优化效果须同端点实测核验。
# v3.5.1:
# · 保留单节点 quick / setup / install；移除远程节点与 SSH 批量管理。
# · --mbps 简写、--dry-run 预览、菜单独立切换队列/拥塞控制/整形。
# · 交互数字输入就地重试；支持单节点非交互执行。
# v3.4.0:
# · 默认 BBR + FQ + 不整形；支持 throughput/balanced/latency/cake/adaptive 预设。
# · switch 与菜单可复用链路参数切换模式；参数按命令行从左到右覆盖。
# · 显式清除 CAKE/FQ 旧限速、RPS 与场景参数；旧调速服务在切换前停止。
# · 记录原文件、实时 sysctl、队列参数、RPS、offload 和服务状态；失败/信号回滚。
# · flock 避免切换、开机重放和自适应控制器并发；自适应模式需要 systemd。
# · RTT 移动 120.222.50.77 / 电信 60.235.1.202 / 自定义 / 手动。
# · 仅自动接管可完整回放的普通队列；CAKE 内部 class 不当作自定义 class。
# · 实际算法依赖内核；BBR 不可用时默认报错，--cc auto 可选择自动降级。
#

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.6.2"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
CLI_FILE="/usr/local/sbin/tcp-tune"
CONFIG_FILE="/etc/sysctl.d/99-tcp-tune.conf"
MODULE_FILE="/etc/modules-load.d/99-tcp-tune.conf"
LEGACY_RUNTIME_FILE="/usr/local/libexec/tcp-tune-runtime"
LEGACY_SERVICE_FILE="/etc/systemd/system/tcp-tune-runtime.service"
QDISC_RUNTIME_FILE="/usr/local/libexec/tcp-tune-qdisc"
QDISC_SERVICE_FILE="/etc/systemd/system/tcp-tune-qdisc.service"
QDISC_SERVICE_NAME="tcp-tune-qdisc.service"
ADAPT_RUNTIME_FILE="/usr/local/libexec/tcp-tune-adapt"
ADAPT_SERVICE_FILE="/etc/systemd/system/tcp-tune-adapt.service"
ADAPT_TIMER_FILE="/etc/systemd/system/tcp-tune-adapt.timer"
ADAPT_SERVICE_NAME="tcp-tune-adapt.service"
ADAPT_TIMER_NAME="tcp-tune-adapt.timer"
ADAPT_STATE_DIR="/var/lib/tcp-tune"
ADAPT_STATE_FILE="/var/lib/tcp-tune/adapt.state"
BACKUP_ROOT="/var/backups/tcp-tune"
INPUT_STATE_FILE="/var/lib/tcp-tune/settings.conf"
MUTATION_LOCK_FILE="/run/lock/tcp-tune.lock"
SYS_NET_DIR="/sys/class/net"
TRANSACTION_ACTIVE=0
CURRENT_BACKUP_DIR=""
MODE_REQUEST="throughput"
MANAGED_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling net.ipv4.tcp_limit_output_bytes
  net.ipv4.tcp_mem net.core.optmem_max net.core.netdev_max_backlog net.core.netdev_budget
  net.core.netdev_budget_usecs net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.core.rps_sock_flow_entries net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen
  net.ipv4.tcp_sack
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_fin_timeout net.ipv4.tcp_slow_start_after_idle)

ACTION=""
DIAG_PORT=""
LOCAL_MBPS=""
SERVER_MBPS=""
RTT_MS=""
RTT_HOST=""
RTT_LINE=""
RTT_MOBILE_HOST="120.222.50.77"
RTT_TELECOM_HOST="60.235.1.202"
RTT_AVG_MS=""
RTT_JITTER_MS=""
RTT_RECEIVED=""
RTT_LOSS_PCT=""
RTT_SOURCE="manual"
MEMORY_MIB=""
PROFILE="streaming"
CURVE="0.8"
CURVE_STEP=8
QDISC_REQUEST="fq"
QDISC=""
CC_REQUEST="bbr"
CC=""
ROLE="host"
IFACE="auto"
TUNE_RPS="auto"
NIC_TUNE=0
CAKE_RATE_MBPS=""
SHAPE_REQUEST="off"
SHAPE_MBPS=""
SHAPE_KBIT=""
SHAPE_GOODPUT_MBPS=0
SHAPE_CPU_X10=0
SHAPE_SOURCE=""
ADAPT=0
ADAPT_REQUEST=0
RETRANS_POLICY="throughput"
FQ_PIE_FLOWS_REQUEST="auto"
FQ_PIE_FLOWS=""
ASSUME_YES=0
DRY_RUN=0
TUNING_EXPLICIT=0
RESOLVE_CONFLICTS=0
ABSORB_ORPHANS=0
NO_COLOR=0
VERBOSE=0
APPLIED_FILES=()
ORPHAN_FILES=()
ORPHAN_LINES=()
ORPHAN_SKIPPED=()
CARRY_FILES=()
READONLY_CONFLICTS=()

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

say()  { printf '%s\n' "$*"; }
running_script_path() {
  local path
  path=$(readlink -f -- "$SCRIPT_SOURCE" 2>/dev/null || true)
  printf '%s' "${path:-${SCRIPT_SOURCE:-stdin}}"
}
show_version() {
  say "tcp-tune v${VERSION}"
  say "运行文件：$(running_script_path)"
}
info() { printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  {
  printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  if (( TRANSACTION_ACTIVE )); then transaction_failed 1; fi
  exit 1
}

set_mode() {
  MODE_REQUEST=$1
  [[ "$MODE_REQUEST" != single ]] || MODE_REQUEST=throughput
  CAKE_RATE_MBPS=""; ADAPT_REQUEST=0
  SHAPE_MBPS=""; SHAPE_KBIT=""; CAKE_RATE_KBIT=""; ADAPT=0
  CC_REQUEST=bbr
  RETRANS_POLICY=throughput
  case "$MODE_REQUEST" in
    throughput) PROFILE=streaming; QDISC_REQUEST=fq; SHAPE_REQUEST=off ;;
    balanced) PROFILE=balanced; QDISC_REQUEST=fq_pie; SHAPE_REQUEST=off; RETRANS_POLICY=balanced ;;
    latency) PROFILE=latency; QDISC_REQUEST=fq_pie; SHAPE_REQUEST=off; RETRANS_POLICY=balanced ;;
    cake) PROFILE=streaming; QDISC_REQUEST=cake; SHAPE_REQUEST=auto ;;
    adaptive) PROFILE=streaming; QDISC_REQUEST=cake; SHAPE_REQUEST=adapt ;;
    *) die "mode 必须是 throughput、balanced、latency、cake 或 adaptive" ;;
  esac
}

honor_queue_choice() {
  if [[ "$QDISC_REQUEST" == fq || "$QDISC_REQUEST" == fq_pie ]]; then
    if [[ "$SHAPE_REQUEST" != off || -n "$CAKE_RATE_MBPS" ]]; then
      SHAPE_REQUEST=off; CAKE_RATE_MBPS=""; ADAPT_REQUEST=0
      info "已选择 $QDISC_REQUEST，整形同时关闭；需要整形时请选 CAKE"
    fi
  fi
}

systemd_available() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

load_link_settings() {
  [[ -r "$INPUT_STATE_FILE" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      LOCAL_MBPS|SERVER_MBPS|RTT_MS|MEMORY_MIB|CURVE|IFACE|ROLE|TUNE_RPS|NIC_TUNE)
        printf -v "$key" '%s' "$value" ;;
    esac
  done < "$INPUT_STATE_FILE"
  RTT_HOST=""; RTT_LINE=""; RTT_SOURCE=saved
  [[ -n "$LOCAL_MBPS" && -n "$SERVER_MBPS" && -n "$RTT_MS" ]]
}

load_tuning_settings() {
  local key value mode=throughput
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ "$key" != MODE ]] || mode=$value
  done < "$INPUT_STATE_FILE"
  set_mode "$mode"
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      QDISC) QDISC_REQUEST=$value ;;
      CC) CC_REQUEST=$value ;;
      SHAPE) SHAPE_REQUEST=$value ;;
      PROFILE|CAKE_RATE_MBPS|FQ_PIE_FLOWS_REQUEST|RETRANS_POLICY) printf -v "$key" '%s' "$value" ;;
    esac
  done < "$INPUT_STATE_FILE"
  [[ "$PROFILE" != single ]] || PROFILE=streaming
}

save_link_settings() {
  local key tmp
  install -d -m 0755 "$(dirname "$INPUT_STATE_FILE")"
  tmp=$(mktemp "${INPUT_STATE_FILE}.XXXXXX")
  for key in LOCAL_MBPS SERVER_MBPS RTT_MS MEMORY_MIB CURVE IFACE ROLE TUNE_RPS NIC_TUNE; do
    printf '%s=%s\n' "$key" "${!key}"
  done > "$tmp"
  printf 'MODE=%s\nQDISC=%s\nCC=%s\nSHAPE=%s\n' "$MODE_REQUEST" "$QDISC" "$CC" "$SHAPE_REQUEST" >> "$tmp"
  printf 'PROFILE=%s\nCAKE_RATE_MBPS=%s\nFQ_PIE_FLOWS_REQUEST=%s\n' "$PROFILE" "$CAKE_RATE_MBPS" "$FQ_PIE_FLOWS_REQUEST" >> "$tmp"
  printf 'RETRANS_POLICY=%s\n' "$RETRANS_POLICY" >> "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$INPUT_STATE_FILE"
}

usage() {
  cat <<'EOF'
tcp-tune.sh - 交互式 Linux TCP 调优工具

用法：
  sudo bash tcp-tune.sh              # 推荐：打开交互式主菜单
  sudo bash tcp-tune.sh quick        # 快速向导：带宽、RTT、模式
  sudo bash tcp-tune.sh setup --mbps 1000 --rtt-line mobile --yes
                                    # 一次应用并安装 tcp-tune 命令
  sudo bash tcp-tune.sh install --yes # 只安装命令，不改网络
  sudo bash tcp-tune.sh wizard
  bash tcp-tune.sh preview [参数]
  sudo bash tcp-tune.sh apply [参数]
  sudo bash tcp-tune.sh switch --mode throughput  # 复用已应用的带宽、RTT、网卡
  sudo bash tcp-tune.sh restore [--yes]
  sudo bash tcp-tune.sh uninstall [--yes]
  bash tcp-tune.sh status
  bash tcp-tune.sh diagnose          # 测速过程中运行：窗口、内存和连接诊断
  bash tcp-tune.sh diagnose --test-port 5858  # 仅显示该测速端口的活动连接
  bash tcp-tune.sh --version         # 确认版本和实际运行文件
  bash tcp-tune.sh rtt               # 交互选择移动、电信或自定义目标
  bash tcp-tune.sh rtt --rtt-line mobile
  bash tcp-tune.sh rtt --rtt-host IP或域名

参数：
  --mbps N             简写：将本地和服务器带宽都设为 N（已知瓶颈容量）
  --bandwidth-mbps N   等价于 --mbps；不会测速，也不会自动猜测带宽
  --local-mbps N        本地接入带宽（Mbps）
  --server-mbps N       服务器端口带宽（Mbps）
  --rtt-ms N            典型往返延迟（ms）
  --rtt-host HOST       ping 指定 IP/域名 5 次，平均 RTT 向上取整到 10ms；可代替 --rtt-ms
  --rtt-line LINE       mobile（移动：120.222.50.77）| telecom（电信：60.235.1.202）
                        --rtt-ms / --rtt-host / --rtt-line 三选一
  --memory-mib N        用于计算的内存；默认自动检测
  --profile NAME        balanced | streaming（默认，含单流缓冲优化）| latency | bulk
  --mode NAME           throughput（默认：BBR+FQ+不整形）| balanced | latency | cake | adaptive
                        参数按从左到右生效，后面的选项覆盖前面的选项
  --qdisc NAME          auto | fq（默认）| fq_pie | cake
  --cc NAME             auto | bbr（默认，需要内核支持）| cubic
  --role NAME           host（代理/VPS）| router（转发设备）
  --interface NAME      出口网卡；默认自动检测
  --curve N             缓冲/队列倍率 0.1-1.0；默认 0.8（不修改 BBR 算法的发送增益）
  --cake-rate-mbps N    CAKE 的显式整形速率
  --shape MODE          出口整形：off（默认，不整形）| auto（固定）| adapt（自适应）| N(Mbps)
                        adapt = 以瓶颈带宽为上限，按实测重传率自动升降速
                                （持续较高重传时退让、状况改善后回升；需 systemd）
                        auto  = 按瓶颈带宽 min(local,server) 定速，不自动调整
                        off   = cake 显式 unlimited，清除上次限速
                        整形只作用于本机出口；效果取决于线路与服务器性能
  --adapt               等价于 --shape adapt
  --retrans-policy NAME throughput（默认）| balanced，仅自适应整形时生效
                        throughput：≤1% 每窗回升，1%-3% 保持并定期探测；>3% 连续两窗降 6%
                                    >8% 立即降 15%；默认采样间隔 30 秒
                        balanced：≤0.3% 两窗回升，>2% 即温和退让
                        这些是整机 TCP 统计的启发式阈值，不是线路最优丢包率
  --fq-pie-flows N      FQ-PIE 流表大小；auto=按连接容量推算（默认），范围 256-65536
  --rps MODE            auto | on | off
  --nic-tune            尝试开启 GRO/GSO/TSO 等吞吐型 offload
  --test-port N         diagnose 专用：筛选源/目标端口 N（1-65535）
  --resolve-conflicts   备份并删除包含冲突参数的整个旧配置文件
  --absorb-orphans      把“存在但开机不会生效”的 sysctl 文件（如 systemd 不读的
                        /etc/sysctl.conf）中的键并入本工具配置，配合
                        --resolve-conflicts 即可真正做到只留一个文件
  --yes                 跳过确认
  --dry-run             只测量并预览方案，不安装命令、不修改网络/配置
  --verbose             显示完整 sysctl 配置与 tc 命令（默认仅显示摘要）
  --no-color            禁用颜色
  -h, --help            显示帮助
  -V, --version         显示版本和实际运行文件

示例：
  sudo bash tcp-tune.sh setup --mbps 1000 --rtt-line mobile --yes
  sudo tcp-tune switch --mode adaptive --yes
  sudo tcp-tune switch --mode throughput --yes
  sudo tcp-tune switch --mode adaptive --retrans-policy throughput --yes
  sudo tcp-tune switch --qdisc cake --shape off --yes
  sudo tcp-tune switch --mode throughput --dry-run
  sudo bash tcp-tune.sh apply --local-mbps 1000 --server-mbps 500 \
    --rtt-ms 180 --profile streaming --qdisc fq --curve 0.8
  bash tcp-tune.sh preview --local-mbps 1000 --server-mbps 500 --rtt-line telecom

quick/setup 在非交互环境默认测试移动 RTT；ICMP 不通即失败，不会猜测 RTT。
可用 --rtt-ms N 跳过 ping。apply/preview 保留原来的显式参数要求。
重复 setup 会更新已有 tcp-tune 命令并重新应用；每次应用均保留独立备份。
uninstall 恢复调优前的网络设置，保留 tcp-tune 命令供以后使用。
默认调优已包含单流缓冲优化，无需单独选择；旧 single 参数自动映射到默认配置。
缓冲上限按带宽×RTT 与内存预算计算，不固定套用 15MB/64MB。
诊断会显示 tcp_notsent_lowat 等旧设置；不把 4096 当作通用吞吐优化值。
tcp_adv_win_scale 自 Linux 6.6 起废弃；不靠它增加现代内核的窗口。
默认 streaming 场景增加缓冲上限并保留自动调节；上限不是预分配内存，也不保证达到目标带宽。
带宽应填可信瓶颈容量（可参考同端点多流测速），不要把当前低单流速度当作容量上限。
RTT 请尽量使用实际测速路径；移动/电信测试地址不能代表所有业务目的地。
EOF
}

is_uint() {
  local value=${1:-}
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  value=${value#"${value%%[!0]*}"}
  [[ -n "$value" && ${#value} -le 9 ]] && (( 10#$value > 0 ))
}
# 归一化：把可带前导零的十进制串转成规范十进制，避免 bash 算术把 0100 当八进制(64)
norm_uint() {
  local value=$1
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    value=${value#"${value%%[!0]*}"}
    printf '%s' "${value:-0}"
  else
    printf '%s' "$value"
  fi
}
clamp() { local n=$1 lo=$2 hi=$3; ((n < lo)) && n=$lo; ((n > hi)) && n=$hi; printf '%s' "$n"; }
min() { local a b; a=$(norm_uint "$1"); b=$(norm_uint "$2"); (( a < b )) && printf '%s' "$a" || printf '%s' "$b"; }

parse_args() {
  ACTION="${1:-}"
  DIAG_PORT=""
  [[ $# -gt 0 ]] && shift
  while (($#)); do
    case "$1" in
      --mbps|--bandwidth-mbps) [[ $# -ge 2 ]] || die "$1 缺少数值"; LOCAL_MBPS=$2; SERVER_MBPS=$2; shift 2 ;;
      --local-mbps)      [[ $# -ge 2 ]] || die "$1 缺少数值"; LOCAL_MBPS=$2; shift 2 ;;
      --server-mbps)     [[ $# -ge 2 ]] || die "$1 缺少数值"; SERVER_MBPS=$2; shift 2 ;;
      --rtt-ms)          [[ $# -ge 2 ]] || die "$1 缺少数值"; RTT_MS=$2; shift 2 ;;
      --rtt-host)        [[ $# -ge 2 ]] || die "$1 缺少 IP 或域名"; RTT_HOST=$2; shift 2 ;;
      --rtt-line)        [[ $# -ge 2 ]] || die "$1 缺少线路名称"; RTT_LINE=$2; shift 2 ;;
      --memory-mib)      [[ $# -ge 2 ]] || die "$1 缺少数值"; MEMORY_MIB=$2; shift 2 ;;
      --profile)         [[ $# -ge 2 ]] || die "$1 缺少名称"; PROFILE=$2; TUNING_EXPLICIT=1; shift 2 ;;
      --mode)            [[ $# -ge 2 ]] || die "$1 缺少模式"; set_mode "$2"; TUNING_EXPLICIT=1; shift 2 ;;
      --qdisc)           [[ $# -ge 2 ]] || die "$1 缺少名称"; QDISC_REQUEST=$2; honor_queue_choice; TUNING_EXPLICIT=1; shift 2 ;;
      --cc)              [[ $# -ge 2 ]] || die "$1 缺少名称"; CC_REQUEST=$2; TUNING_EXPLICIT=1; shift 2 ;;
      --role)            [[ $# -ge 2 ]] || die "$1 缺少名称"; ROLE=$2; shift 2 ;;
      --interface)       [[ $# -ge 2 ]] || die "$1 缺少名称"; IFACE=$2; shift 2 ;;
      --curve)           [[ $# -ge 2 ]] || die "$1 缺少数值"; CURVE=$2; shift 2 ;;
      --cake-rate-mbps)  [[ $# -ge 2 ]] || die "$1 缺少数值"; CAKE_RATE_MBPS=$2; TUNING_EXPLICIT=1; shift 2 ;;
      --shape)           [[ $# -ge 2 ]] || die "$1 缺少数值"; SHAPE_REQUEST=$2; TUNING_EXPLICIT=1; shift 2 ;;
      --adapt)           SHAPE_REQUEST=adapt; ADAPT_REQUEST=0; TUNING_EXPLICIT=1; shift ;;
      --retrans-policy)  [[ $# -ge 2 ]] || die "$1 缺少策略名称"; RETRANS_POLICY=$2; TUNING_EXPLICIT=1; shift 2 ;;
      --fq-pie-flows)    [[ $# -ge 2 ]] || die "$1 缺少数值"; FQ_PIE_FLOWS_REQUEST=$2; shift 2 ;;
      --rps)             [[ $# -ge 2 ]] || die "$1 缺少模式"; TUNE_RPS=$2; shift 2 ;;
      --nic-tune)        NIC_TUNE=1; shift ;;
      --test-port)       [[ $# -ge 2 ]] || die "$1 缺少端口"; is_uint "$2" || die "--test-port 必须是 1-65535 的端口"; DIAG_PORT=$(norm_uint "$2"); (( DIAG_PORT <= 65535 )) || die "--test-port 必须是 1-65535 的端口"; shift 2 ;;
      --resolve-conflicts) RESOLVE_CONFLICTS=1; shift ;;
      --absorb-orphans)  ABSORB_ORPHANS=1; shift ;;
      --yes|-y)          ASSUME_YES=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --verbose)         VERBOSE=1; shift ;;
      --no-color)        NO_COLOR=1; C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"
  [[ -r /proc/meminfo && -d /proc/sys/net/ipv4 ]] || die "当前环境缺少 Linux procfs"
}

require_root() { (( EUID == 0 )) || die "该操作需要 root：请使用 sudo bash $0 $ACTION ..."; }

detect_memory_mib() {
  local kb
  kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
  printf '%s' "$((kb / 1024))"
}

resolve_rtt_args() {
  local count=0
  [[ -z "$RTT_MS" ]] || count=$((count + 1))
  [[ -z "$RTT_HOST" ]] || count=$((count + 1))
  [[ -z "$RTT_LINE" ]] || count=$((count + 1))
  (( count <= 1 )) || die "--rtt-ms、--rtt-host、--rtt-line 只能选择一个，避免 RTT 来源被静默覆盖"
  case "$RTT_LINE" in
    "") ;;
    mobile) RTT_HOST=$RTT_MOBILE_HOST ;;
    telecom) RTT_HOST=$RTT_TELECOM_HOST ;;
    *) die "--rtt-line 必须是 mobile（移动）或 telecom（电信）" ;;
  esac
}

rtt_target_label() {
  case "$RTT_HOST" in
    "$RTT_MOBILE_HOST") printf '移动线路（%s）' "$RTT_HOST" ;;
    "$RTT_TELECOM_HOST") printf '电信线路（%s）' "$RTT_HOST" ;;
    *) printf '自定义目标（%s）' "$RTT_HOST" ;;
  esac
}

measure_rtt() {
  local target=$1 output measured rounded received avg jitter loss ping_cmd=ping
  # 每次测试清除旧样本，失败不能沿用其他线路的 RTT。
  RTT_MS=""; RTT_AVG_MS=""; RTT_JITTER_MS=""; RTT_RECEIVED=""; RTT_LOSS_PCT=""
  RTT_SOURCE="manual"
  if [[ -z "$target" || "$target" == -* || ! "$target" =~ ^[a-zA-Z0-9._:%-]+$ ]]; then
    warn "RTT 测试目标不是有效的 IP 或域名：${target:-空}"
    return 1
  fi
  # 旧版系统可能需要独立的 ping6；现代 iputils 的 ping 可直接识别 IPv6。
  if [[ "$target" == *:* ]] && command -v ping6 >/dev/null 2>&1; then ping_cmd=ping6; fi
  if ! command -v "$ping_cmd" >/dev/null 2>&1; then
    warn "自动测量 RTT 需要 $ping_cmd（通常由 iputils-ping 提供），也可以手动输入 RTT"
    return 1
  fi
  info "正在测试 $target 的 RTT（5 次，超时 2 秒/次，总期限 15 秒）..."
  output=$(LC_ALL=C "$ping_cmd" -n -c 5 -W 2 -w 15 "$target" 2>&1 || true)
  measured=$(printf '%s\n' "$output" | awk '
    /(icmp_[sr]eq|seq)=/ && !/DUP!/ {
      # 同时兼容 iputils 的 time=1.2 与 BusyBox 的 time= 1.2。
      if (match($0, /time[=<][[:space:]]*[0-9]+([.][0-9]+)?/)) {
        v=substr($0, RSTART, RLENGTH); sub(/^time[=<][[:space:]]*/, "", v)
        sum+=v; squares+=v*v; n++
      }
    }
    END {
      if (n > 0) {
        avg=sum/n; variance=squares/n-avg*avg
        if (variance < 0) variance=0
        rounded=int(avg/10); if (avg > rounded*10) rounded++
        rounded*=10; if (rounded < 10) rounded=10
        loss=(5-n)*20; if (loss < 0) loss=0
        printf "%d:%d:%.3f:%.3f:%d", rounded, n, avg, sqrt(variance), loss
      }
    }')
  if [[ -z "$measured" ]]; then
    printf '%s\n' "$output" >&2
    warn "无法从 $target 获得 RTT：目标可能不回应 ICMP，也可能是 DNS 或网络问题"
    return 1
  fi
  IFS=: read -r rounded received avg jitter loss <<< "$measured"
  if ! is_uint "$rounded" || (( rounded > 10000 )); then
    warn "测得 RTT 超出可用范围（1-10000 ms），请重试或手动输入"
    return 1
  fi
  RTT_HOST=$target; RTT_MS=$rounded; RTT_RECEIVED=$received; RTT_AVG_MS=$avg
  RTT_JITTER_MS=$jitter; RTT_LOSS_PCT=$loss; RTT_SOURCE="ping"
  ok "RTT 测量完成：成功 $received/5，平均 ${avg} ms，抖动（标准差）${jitter} ms，丢包 ${loss}%"
  info "用于调优的 RTT：${RTT_MS} ms（平均值向上取整到 10ms）"
  (( received >= 3 )) || warn "有效样本少于 3 个，建议重测；ICMP 丢包不能直接代表 TCP 丢包"
  return 0
}

input_manual_rtt() {
  local answer
  while true; do
    answer=$(prompt_default "典型往返 RTT（ms）" "${RTT_MS:-150}") || return 1
    if is_uint "$answer"; then
      answer=$(norm_uint "$answer")
      if (( answer <= 10000 )); then
        RTT_MS=$answer; RTT_HOST=""; RTT_LINE=""; RTT_SOURCE="manual"
        RTT_AVG_MS=""; RTT_JITTER_MS=""; RTT_RECEIVED=""; RTT_LOSS_PCT=""
        return 0
      fi
    fi
    warn "RTT 必须是 1-10000 的整数"
  done
}

choose_rtt() {
  local mode recovery select_target=1 default_index=1
  [[ "$RTT_HOST" != "$RTT_TELECOM_HOST" ]] || default_index=2
  [[ -z "$RTT_HOST" || "$RTT_HOST" == "$RTT_MOBILE_HOST" || "$RTT_HOST" == "$RTT_TELECOM_HOST" ]] || default_index=3
  [[ -z "$RTT_MS" || -n "$RTT_HOST" ]] || default_index=4
  while true; do
    if (( select_target )); then
      choose_option mode "RTT 测试目标" "$default_index" \
        "mobile|移动线路：$RTT_MOBILE_HOST" \
        "telecom|电信线路：$RTT_TELECOM_HOST" \
        'custom|自定义 IP 或域名' \
        'manual|手动输入 RTT（跳过测试）'
      case "$mode" in
        mobile) RTT_LINE=mobile; RTT_HOST=$RTT_MOBILE_HOST; default_index=1 ;;
        telecom) RTT_LINE=telecom; RTT_HOST=$RTT_TELECOM_HOST; default_index=2 ;;
        custom) RTT_LINE=""; RTT_HOST=$(prompt_default "用于测试 RTT 的 IP 或域名" "${RTT_HOST:-$RTT_MOBILE_HOST}") || return 1; default_index=3 ;;
        manual) input_manual_rtt || return 1; return 0 ;;
      esac
    fi
    if measure_rtt "$RTT_HOST"; then return 0; fi
    choose_option recovery "RTT 测试未成功，接下来" 1 \
      'select|更换测试目标' 'retry|重试当前目标' 'manual|手动输入 RTT' 'cancel|取消当前操作'
    case "$recovery" in
      select) select_target=1 ;;
      retry) select_target=0 ;;
      manual) input_manual_rtt || return 1; return 0 ;;
      cancel) info "已取消 RTT 测试"; return 1 ;;
    esac
  done
}

validate_inputs() {
  local name value
  for name in LOCAL_MBPS SERVER_MBPS RTT_MS MEMORY_MIB; do
    value=${!name}
    is_uint "$value" || die "$name 必须是大于 0 的整数（当前：${value:-空}）"
    printf -v "$name" '%s' "$(norm_uint "$value")"   # 0100 -> 100，杜绝八进制误读
  done
  ((LOCAL_MBPS <= 100000)) || die "本地带宽不能超过 100000 Mbps"
  ((SERVER_MBPS <= 100000)) || die "服务器带宽不能超过 100000 Mbps"
  ((RTT_MS <= 10000)) || die "RTT 不能超过 10000 ms"
  ((MEMORY_MIB >= 64 && MEMORY_MIB <= 1048576)) || die "内存范围必须是 64-1048576 MiB"
  [[ "$NIC_TUNE" == 0 || "$NIC_TUNE" == 1 ]] || die "NIC_TUNE 必须是 0 或 1"
  normalize_curve
  [[ "$PROFILE" != single ]] || PROFILE=streaming
  case "$PROFILE" in balanced|streaming|latency|bulk) ;; *) die "未知场景：$PROFILE" ;; esac
  case "$RETRANS_POLICY" in throughput|balanced) ;; *) die "retrans-policy 必须是 throughput 或 balanced" ;; esac
  case "$QDISC_REQUEST" in auto|fq|fq_pie|cake) ;; *) die "未知 qdisc：$QDISC_REQUEST" ;; esac
  case "$CC_REQUEST" in auto|bbr|cubic) ;; *) die "未知拥塞控制：$CC_REQUEST" ;; esac
  case "$ROLE" in host|router) ;; *) die "role 必须是 host 或 router" ;; esac
  case "$TUNE_RPS" in auto|on|off) ;; *) die "rps 必须是 auto、on 或 off" ;; esac
  if [[ -n "$CAKE_RATE_MBPS" ]]; then
    is_uint "$CAKE_RATE_MBPS" || die "cake-rate-mbps 必须是正整数"
    CAKE_RATE_MBPS=$(norm_uint "$CAKE_RATE_MBPS")
    (( CAKE_RATE_MBPS <= 100000 )) || die "cake-rate-mbps 不能超过 100000"
  fi
  case "$SHAPE_REQUEST" in
    auto|adapt|off) ;;
    *)
      is_uint "$SHAPE_REQUEST" || die "shape 必须是 auto、off 或正整数 Mbps（当前：${SHAPE_REQUEST:-空}）"
      SHAPE_REQUEST=$(norm_uint "$SHAPE_REQUEST")
      (( SHAPE_REQUEST <= 100000 )) || die "shape 不能超过 100000 Mbps"
      ;;
  esac
  case "$FQ_PIE_FLOWS_REQUEST" in
    auto) ;;
    *)
      is_uint "$FQ_PIE_FLOWS_REQUEST" || die "fq-pie-flows 必须是 auto 或正整数（当前：${FQ_PIE_FLOWS_REQUEST:-空}）"
      FQ_PIE_FLOWS_REQUEST=$(norm_uint "$FQ_PIE_FLOWS_REQUEST")
      (( FQ_PIE_FLOWS_REQUEST >= 256 && FQ_PIE_FLOWS_REQUEST <= 65536 )) || die "fq-pie-flows 范围是 256-65536"
      ;;
  esac
  [[ "$IFACE" == auto || ( "$IFACE" != -* && "$IFACE" =~ ^[a-zA-Z0-9_.:@-]+$ ) ]] || die "网卡名称含有非法字符"
  if [[ -n "$CAKE_RATE_MBPS" && "$SHAPE_REQUEST" == off ]]; then
    die "--shape off 与 --cake-rate-mbps 冲突；需要固定限速请使用 --shape N"
  fi
}

normalize_curve() {
  local step
  case "$CURVE" in
    # 支持一位与两位小数：0.7 / 0.75 / 0.10
    0.[0-9]|0.[0-9][0-9])
      awk -v c="$CURVE" 'BEGIN { exit !(c >= 0.1 && c <= 1.0) }' || die "curve 必须是 0.1-1.0（当前：$CURVE）"
      step=$(awk -v c="$CURVE" 'BEGIN { printf "%d", c * 10 + 0.5 }')
      CURVE_STEP=$step
      ;;
    1|1.0|1.00) CURVE_STEP=10; CURVE="1.0" ;;
    10)        CURVE_STEP=10; CURVE="1.0" ;;
    [1-9])     CURVE_STEP=$(( 10#$CURVE )); CURVE="0.$CURVE" ;;
    *) die "curve 必须是 0.1-1.0（也兼容旧写法 1-10；支持两位小数如 0.75）" ;;
  esac
}

detect_interface() {
  if [[ "$IFACE" == auto ]]; then
    command -v ip >/dev/null 2>&1 || die "自动检测网卡需要 iproute2"
    IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
    [[ -n "$IFACE" ]] || IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
    if [[ -z "$IFACE" && -t 0 ]] && (( ! ASSUME_YES )); then IFACE=$(prompt_interface); fi
  fi
  [[ -n "$IFACE" && -d "$SYS_NET_DIR/$IFACE" ]] || die "无法找到出口网卡：${IFACE:-空}；可通过 --interface 显式指定"
  MTU=$(<"$SYS_NET_DIR/$IFACE/mtu")
  is_uint "$MTU" || MTU=1500
  CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || say 1)
  is_uint "$CPU_COUNT" || CPU_COUNT=1
  RX_QUEUES=$(find "$SYS_NET_DIR/$IFACE/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l)
  TX_QUEUES=$(find "$SYS_NET_DIR/$IFACE/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)
  ((RX_QUEUES > 0)) || RX_QUEUES=1
  ((TX_QUEUES > 0)) || TX_QUEUES=1
}

prompt_interface() {
  local directory name answer default="" names=""
  for directory in "$SYS_NET_DIR"/*; do
    [[ -d "$directory" ]] || continue
    name=${directory##*/}
    [[ "$name" != lo ]] || continue
    names+=" ${name}"; [[ -n "$default" ]] || default=$name
  done
  [[ -n "$default" ]] || die "未找到可用网卡；请检查网络设备与 iproute2"
  warn "未检测到默认路由，请手动选择出口网卡。可选：$names"
  while true; do
    answer=$(prompt_default "出口网卡" "$default") || return 1
    if [[ "$answer" != -* && "$answer" =~ ^[a-zA-Z0-9_.:@-]+$ && -d "$SYS_NET_DIR/$answer" ]]; then printf '%s' "$answer"; return 0; fi
    warn "网卡不存在或名称无效：$answer；可选：$names"
  done
}

prompt_default() {
  local prompt=$1 default=$2 answer
  read -r -p "$prompt [$default]: " answer || die "输入已结束，操作已取消"
  printf '%s' "${answer:-$default}"
}

prompt_uint() {
  local prompt=$1 default=$2 lo=$3 hi=$4 answer
  while true; do
    answer=$(prompt_default "$prompt" "$default") || return 1
    answer=$(norm_uint "$answer")
    if [[ "$answer" == 0 && "$lo" == 0 ]] || is_uint "$answer"; then
      if (( answer >= lo && answer <= hi )); then printf '%s' "$answer"; return 0; fi
    fi
    warn "请输入 ${lo}-${hi} 的整数；当前输入：${answer:-空}"
  done
}

prompt_memory() {
  local value
  while true; do
    value=$(prompt_uint "服务器内存（MiB，0=自动检测）" 0 0 1048576) || return 1
    if [[ "$value" == 0 ]] || (( value >= 64 )); then printf '%s' "$value"; return 0; fi
    warn "内存至少需要 64 MiB；输入 0 可自动检测"
  done
}

prompt_curve() {
  local answer
  while true; do
    answer=$(prompt_default "缓冲/队列倍率 0.1-1.0（不改变 BBR 发送增益）" "$CURVE") || return 1
    if (CURVE=$answer; normalize_curve) >/dev/null 2>&1; then printf '%s' "$answer"; return 0; fi
    warn "请输入 0.1-1.0；例如 0.8"
  done
}

option_index() {
  local value=$1 index=1 item
  shift
  for item in "$@"; do
    if [[ "$value" == "$item" ]]; then printf '%s' "$index"; return 0; fi
    index=$((index + 1))
  done
  printf '1'
}

choose_queue() {
  choose_option QDISC_REQUEST "队列算法（整形需要 CAKE）" "$(option_index "$QDISC_REQUEST" fq fq_pie cake auto)" \
    'fq|FQ：BBR 与吞吐优先' 'fq_pie|FQ-PIE：兼顾公平和延迟' \
    'cake|CAKE：整形、公平与抗 bufferbloat' 'auto|自动按场景选择'
  honor_queue_choice
}

choose_cc() {
  choose_option CC_REQUEST "拥塞控制算法" "$(option_index "$CC_REQUEST" bbr cubic auto)" \
    'bbr|BBR（需要内核支持）' 'cubic|使用内核 Cubic' 'auto|优先 BBR，不支持时使用 Cubic'
}

choose_shape() {
  local default=4 shape_hint=1000
  case "$SHAPE_REQUEST" in off) default=1 ;; auto) default=2 ;; adapt) default=3 ;; esac
  choose_option SHAPE_REQUEST "出口整形" "$default" \
    'off|不整形（清除原限速）' 'auto|固定整形：按瓶颈带宽定速' \
    'adapt|自适应：按整机 TCP 重传率调速（需要 systemd）' 'custom|自定义固定速率（Mbps）'
  CAKE_RATE_MBPS=""; ADAPT_REQUEST=0
  if [[ "$SHAPE_REQUEST" == custom ]]; then
    if is_uint "$LOCAL_MBPS" && is_uint "$SERVER_MBPS"; then shape_hint=$(min "$LOCAL_MBPS" "$SERVER_MBPS"); fi
    SHAPE_REQUEST=$(prompt_uint "整形速率（Mbps）" "$shape_hint" 1 100000) || return 1
  fi
  if [[ "$SHAPE_REQUEST" != off ]]; then
    QDISC_REQUEST=cake
    info "已启用整形，队列选择 CAKE"
  fi
}

choose_tuning() {
  local choice
  while true; do
    say "当前选择：${CC_REQUEST} + ${QDISC_REQUEST}，整形 ${SHAPE_REQUEST}"
    choose_option choice "单独调整（其他选择保留）" 1 \
      'queue|队列算法' 'cc|拥塞控制算法' 'shape|整形 / 自适应' 'back|返回方案预览' \
      'policy|自适应重传策略'
    case "$choice" in
      queue) choose_queue ;; cc) choose_cc ;; shape) choose_shape ;; back) return 0 ;;
      policy) choose_option RETRANS_POLICY "重传策略（仅自适应整形生效）" "$(option_index "$RETRANS_POLICY" throughput balanced)" \
        'throughput|吞吐优先：允许少量重传，恢复更快' 'balanced|均衡：对持续重传更敏感' ;;
    esac
  done
}

choose_option() {
  local target=$1 prompt=$2 default_index=$3 answer index option label marker
  shift 3
  local options=("$@")
  while true; do
    say
    say "${C_BOLD}${prompt}${C_RESET}"
    for index in "${!options[@]}"; do
      option=${options[$index]}
      label=${option#*|}
      marker=""
      if [[ $((index + 1)) -eq $default_index ]]; then marker='（默认）'; fi
      printf '  %d) %s%s\n' "$((index + 1))" "$label" "$marker"
    done
    read -r -p "请选择 [$default_index]: " answer || die "输入已结束，操作已取消"
    answer=${answer:-$default_index}
    if is_uint "$answer"; then
      answer=$(norm_uint "$answer")
      if ((answer >= 1 && answer <= ${#options[@]})); then
        option=${options[$((answer - 1))]}
        printf -v "$target" '%s' "${option%%|*}"
        return 0
      fi
    fi
    warn "请输入 1-${#options[@]}"
  done
}

choose_yes_no() {
  local target=$1 prompt=$2 default=${3:-yes} result
  if [[ "$default" == yes ]]; then
    choose_option result "$prompt" 1 'yes|是' 'no|否'
  else
    choose_option result "$prompt" 2 'yes|是' 'no|否'
  fi
  [[ "$result" == yes ]] && printf -v "$target" '%s' 1 || printf -v "$target" '%s' 0
}

wizard() {
  require_root
  set_mode throughput
  say "${C_BOLD}TCP 性能调优向导 v${VERSION}${C_RESET}"
  say "默认：BBR + FQ + 不整形；直接按回车即可采用默认值。"
  say "带宽请填【可信的瓶颈容量】，可参考同端点多连接测速结果。"
  say "不要把当前偏低的单线程速度或零重传时的速率当作容量上限。"
  say "整形模式按此值限制出口；不整形模式用它计算缓冲，不限速。"
  say
  LOCAL_MBPS=$(prompt_uint "本地宽带（Mbps）" "1000" 1 100000)
  SERVER_MBPS=$(prompt_uint "服务器端口（Mbps）" "1000" 1 100000)
  choose_rtt || return 0
  MEMORY_MIB=$(prompt_memory)
  [[ "$MEMORY_MIB" == "0" ]] && MEMORY_MIB=$(detect_memory_mib)
  choose_option PROFILE "使用场景" 1 \
    'streaming|代理、视频与高吞吐（推荐）' \
    'balanced|综合均衡' \
    'latency|游戏与低延迟' \
    'bulk|大文件传输与多连接下载'
  choose_option ROLE "机器角色" 1 \
    'host|VPS、代理服务器或普通主机（推荐）' \
    'router|路由器、网关或转发设备'
  choose_queue
  choose_cc
  choose_shape
  CURVE=$(prompt_curve)
  IFACE=$(prompt_default "出口网卡（auto=自动）" "auto")
  choose_option TUNE_RPS "多核网络处理 RPS/RFS（仅当前开机有效）" 1 \
    'auto|单 RX 队列且多核时自动开启（推荐，仅立即应用）' \
    'on|强制开启（仅立即应用）' \
    'off|关闭'
  choose_yes_no NIC_TUNE "开启 GRO/GSO/TSO 等吞吐型网卡 offload？" no
  choose_yes_no RESOLVE_CONFLICTS "备份并删除包含冲突参数的整个旧 sysctl 文件？" yes
  review_and_apply
}

choose_mode() {
  local selected
  choose_option selected "调优模式" "$(option_index "$MODE_REQUEST" throughput balanced latency cake adaptive)" \
    'throughput|默认方案：BBR + FQ + 不整形（含单流缓冲优化）' \
    'balanced|均衡：BBR + FQ-PIE + 不整形' \
    'latency|低延迟：BBR + FQ-PIE + 不整形（较小缓冲）' \
    'cake|CAKE 固定整形：按瓶颈带宽限速' \
    'adaptive|CAKE 自适应整形：按整机重传率调速'
  set_mode "$selected"
}

prepare_plan() {
  validate_inputs
  detect_interface
  calculate
  audit_sysctl_sources
  find_conflicts
  collect_orphans
}

review_and_apply() {
  local choice saved_verbose
  while true; do
    prepare_plan
    preview_config
    choose_option choice "接下来" 1 \
      'apply|应用以上方案' \
      'details|查看完整参数' \
      'mode|更换调优模式' \
      'link|修改带宽或 RTT' \
      'back|返回 / 取消' \
      'tuning|单独调整队列 / 拥塞控制 / 整形'
    case "$choice" in
      apply)
        if (( DRY_RUN )); then info "预览结束，未作修改"; return 0; fi
        if (( ADAPT )) && ! systemd_available; then warn "自适应需要 systemd；请选择其他模式或整形策略"; continue; fi
        if confirm "确认应用到当前服务器？"; then ACTION=apply; apply_config; fi
        return 0 ;;
      details) saved_verbose=$VERBOSE; VERBOSE=1; preview_config; VERBOSE=$saved_verbose ;;
      mode) choose_mode ;;
      link)
        LOCAL_MBPS=$(prompt_uint "本地宽带（Mbps）" "$LOCAL_MBPS" 1 100000)
        SERVER_MBPS=$(prompt_uint "服务器端口（Mbps）" "$SERVER_MBPS" 1 100000)
        choose_rtt || return 0 ;;
      tuning) choose_tuning ;;
      back) info "已取消"; return 0 ;;
    esac
  done
}

switch_wizard() {
  require_root
  if ! load_link_settings; then info "没有可复用的链路参数，先完成首次向导"; wizard; return 0; fi
  load_tuning_settings
  choose_mode
  review_and_apply
}

script_file() {
  [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]] || die "请先将脚本下载为文件；通过 bash -s / 管道运行时不能安装命令"
  printf '%s' "$SCRIPT_SOURCE"
}

install_cli() {
  require_root
  local source_file tmp
  source_file=$(script_file)
  bash -n "$source_file" || die "脚本语法检查失败，未安装"
  [[ ! -L "$CLI_FILE" ]] || die "$CLI_FILE 是符号链接，拒绝覆盖；请检查后手动处理"
  if [[ -e "$CLI_FILE" ]]; then
    [[ -f "$CLI_FILE" ]] || die "$CLI_FILE 不是普通文件，拒绝覆盖"
    grep -Fxq '# tcp-tune.sh - throughput-oriented Linux TCP/qdisc tuning assistant' "$CLI_FILE" || die "$CLI_FILE 已被其他程序使用，拒绝覆盖"
  fi
  if (( DRY_RUN )); then info "预览：将安装命令到 $CLI_FILE；未作修改"; return 0; fi
  if [[ "$source_file" -ef "$CLI_FILE" ]]; then ok "tcp-tune 命令已是当前脚本"; return 0; fi
  install -d -m 0755 "$(dirname "$CLI_FILE")"
  tmp=$(mktemp "${CLI_FILE}.XXXXXX")
  if ! install -m 0755 "$source_file" "$tmp"; then rm -f -- "$tmp"; die "无法复制命令到 $CLI_FILE"; fi
  if ! mv -f -- "$tmp" "$CLI_FILE"; then rm -f -- "$tmp"; die "无法安装命令到 $CLI_FILE"; fi
  ok "已安装命令：$CLI_FILE（v$VERSION）"
  info "后续可用：sudo tcp-tune status；sudo tcp-tune switch --mode throughput --yes"
}

quick_setup() {
  local bandwidth
  if [[ -z "$LOCAL_MBPS" && -z "$SERVER_MBPS" ]]; then
    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
      say "快速优化：填写实际瓶颈带宽；默认 BBR + FQ + 不整形。"
      bandwidth=$(prompt_uint "瓶颈带宽（Mbps，填实测容量）" 1000 1 100000)
      LOCAL_MBPS=$bandwidth; SERVER_MBPS=$bandwidth
    else
      die "首次快速优化需要带宽：例如 $ACTION --mbps 1000 --rtt-line mobile --yes；切换已有设置请用 switch"
    fi
  fi
  [[ -n "$LOCAL_MBPS" && -n "$SERVER_MBPS" ]] || die "请用 --mbps N，或同时提供 --local-mbps N 与 --server-mbps N"
  if [[ -z "$RTT_MS" && -z "$RTT_HOST" ]]; then
    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
      choose_rtt || return 0
    else
      RTT_LINE=mobile; RTT_HOST=$RTT_MOBILE_HOST
      info "未指定 RTT，快速入口默认测试移动线路：$RTT_HOST"
    fi
  fi
  if [[ -n "$RTT_HOST" && "$RTT_SOURCE" != ping ]]; then
    measure_rtt "$RTT_HOST" || die "RTT 测试失败；改用 --rtt-line telecom、--rtt-host 目标 或 --rtt-ms 实测值重试；未修改网络"
  fi
  if [[ -t 0 ]] && (( ! ASSUME_YES && ! TUNING_EXPLICIT )); then choose_mode; fi
  prepare_plan
  preview_config
  if (( DRY_RUN )); then info "预览结束，未安装命令、未修改网络或配置"; return 0; fi
  require_root
  if [[ "$ACTION" == setup ]]; then
    # 管道安装在任何网络变更前明确拒绝。
    script_file >/dev/null
    if confirm "确认应用以上方案并安装 tcp-tune 命令？"; then install_cli; apply_config; else info "已取消"; fi
  else
    if confirm "确认应用以上方案？"; then apply_config; else info "已取消"; fi
  fi
}

main_menu() {
  local choice
  while true; do
    say "${C_BOLD}TCP 性能优化工具 v${VERSION}${C_RESET}"
    say "运行文件：$(running_script_path)"
    say "默认 BBR + FQ + 不整形；切换模式复用已保存的链路参数"
    say '  1) 完整向导（所有设置）'
    say '  2) 查看当前网络状态'
    say '  3) 恢复最近一次备份'
    say '  4) 卸载并恢复初始设置'
    say '  5) 显示命令行帮助'
    say '  6) 单独测试 RTT（选择线路）'
    say '  7) 切换调优模式'
    say '  8) 快速优化（推荐：带宽、RTT、模式）'
    say '  9) 单独调整队列 / 拥塞控制 / 整形'
    say '  0) 退出'
    read -r -p '请选择 [8]: ' choice || return 0
    choice=$(norm_uint "${choice:-8}")
    case "$choice" in
      1) wizard ;;
      2) status ;;
      3) ACTION=restore; restore_latest ;;
      4) ACTION=uninstall; uninstall_config ;;
      5) usage ;;
      6) if choose_rtt; then :; fi ;;
      7) switch_wizard ;;
      8) ACTION=quick; set_mode throughput; LOCAL_MBPS=""; SERVER_MBPS=""; RTT_MS=""; RTT_HOST=""; RTT_LINE=""; RTT_SOURCE=manual; TUNING_EXPLICIT=0; quick_setup ;;
      9)
        require_root
        if load_link_settings; then load_tuning_settings; choose_tuning; review_and_apply
        else info "尚无已应用的链路参数，请先进行快速优化或完整向导"; fi ;;
      0) info "已退出"; return 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}

confirm() {
  local prompt=$1 answer
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "非交互执行需明确添加 --yes"
  read -r -p "$prompt [Y/n]: " answer || return 1
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

cc_available() {
  local cc=$1 available
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  [[ " $available " == *" $cc "* ]]
}

select_congestion_control() {
  case "$CC_REQUEST" in
    bbr) CC=bbr ;;
    cubic) CC=cubic ;;
    auto)
      if cc_available bbr; then
        CC=bbr
      elif command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
        CC=bbr
      else
        CC=cubic
      fi
      ;;
  esac
}

select_qdisc() {
  if [[ -n "$SHAPE_KBIT" || -n "$CAKE_RATE_MBPS" ]]; then
    # 需要整形时只能用 cake
    QDISC=cake
    [[ "$QDISC_REQUEST" == auto || "$QDISC_REQUEST" == cake ]] || \
      warn "已启用整形，qdisc 由 ${QDISC_REQUEST} 改为 cake（只有 cake 能可靠整形）"
  elif [[ "$QDISC_REQUEST" != auto ]]; then
    QDISC=$QDISC_REQUEST
  elif [[ "$ROLE" == router ]]; then
    QDISC=cake
  elif [[ "$PROFILE" == latency || "$PROFILE" == balanced ]]; then
    QDISC=fq_pie
  else
    QDISC=fq
  fi
}

calculate() {
  local bottleneck factor mem_cap hard_cap profile_backlog shape_auto cpu_shape_cap
  # 向导/应用可能重复计算；不能残留上一次 adapt 模式。
  ADAPT=$ADAPT_REQUEST
  bottleneck=$(min "$LOCAL_MBPS" "$SERVER_MBPS")
  BDP_BYTES=$((bottleneck * RTT_MS * 125))

  case "$PROFILE" in
    balanced)  factor=$((220 + CURVE_STEP * 18)); profile_backlog=8 ;;
    streaming) factor=$((400 + CURVE_STEP * 20)); profile_backlog=12 ;;
    latency)   factor=$((180 + CURVE_STEP * 12)); profile_backlog=6 ;;
    bulk)      factor=$((350 + CURVE_STEP * 30)); profile_backlog=18 ;;
  esac

  BUFFER_TARGET_BYTES=$((BDP_BYTES * factor / 100))
  BUFFER_BYTES=$BUFFER_TARGET_BYTES
  # ── 内存模型 ──────────────────────────────────────────────
  # 全局 TCP 内存预算 = 内存的 1/8；tcp_mem 三级水位按内核同构关系推导：
  #   low = max/2,  high = max*2/3,  max = 预算
  # 单 socket 上限再收紧到 high 的 1/4。旧版只限了单 socket 却从不设 tcp_mem，
  # 实测出现过 rmem_max 124MiB > 实测 tcp_mem high 116MiB 的矛盾。
  TCP_MEM_MAX_BYTES=$((MEMORY_MIB * 1048576 / 8))
  (( TCP_MEM_MAX_BYTES < 8 * 1048576 )) && TCP_MEM_MAX_BYTES=$((8 * 1048576))
  TCP_MEM_HIGH_BYTES=$((TCP_MEM_MAX_BYTES * 2 / 3))
  TCP_MEM_LOW_BYTES=$((TCP_MEM_MAX_BYTES / 2))
  mem_cap=$((TCP_MEM_HIGH_BYTES / 4))
  if [[ "$PROFILE" == streaming ]]; then
    # 单流高 BDP 链路采用 RAM 的 1/4 作为 TCP 全局最高水位；socket 上限
    # ≤压力水位的 1/3 且 ≤256MiB。两方向各达到上限时仍低于压力水位。
    # 这是上限而非预分配；不能将此值当作实际 TCP 接收窗口。
    TCP_MEM_MAX_BYTES=$((MEMORY_MIB * 1048576 / 4))
    TCP_MEM_HIGH_BYTES=$((TCP_MEM_MAX_BYTES * 3 / 4))
    TCP_MEM_LOW_BYTES=$((TCP_MEM_MAX_BYTES / 2))
    mem_cap=$(min "$((TCP_MEM_HIGH_BYTES / 3))" "$((256 * 1048576))")
  fi
  PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || say 4096)
  is_uint "$PAGE_SIZE" || PAGE_SIZE=4096
  TCP_MEM_PAGES="$((TCP_MEM_LOW_BYTES / PAGE_SIZE)) $((TCP_MEM_HIGH_BYTES / PAGE_SIZE)) $((TCP_MEM_MAX_BYTES / PAGE_SIZE))"
  local socket_min
  socket_min=$(min "$((4 * 1048576))" "$mem_cap")
  BUFFER_BYTES=$(clamp "$BUFFER_BYTES" "$socket_min" "$mem_cap")
  RECV_DEFAULT_BYTES=131072; SEND_DEFAULT_BYTES=16384
  if [[ "$PROFILE" == streaming ]]; then
    RECV_DEFAULT_BYTES=$(clamp "$((BUFFER_BYTES / 8))" 131072 1048576)
    SEND_DEFAULT_BYTES=$(clamp "$((BUFFER_BYTES / 16))" 16384 262144)
  fi
  OPTMEM_MAX=$(clamp "$((BUFFER_BYTES / 8))" 131072 1048576)

  BACKLOG=$((bottleneck * profile_backlog))
  local backlog_cap=65536
  ((MEMORY_MIB < 1024)) && backlog_cap=8192
  ((MEMORY_MIB >= 1024 && MEMORY_MIB < 4096)) && backlog_cap=32768
  BACKLOG=$(clamp "$BACKLOG" 4096 "$backlog_cap")
  SOMAXCONN=$(clamp "$((BACKLOG / 2))" 4096 32768)
  NETDEV_BUDGET=$((300 + CURVE_STEP * 150))
  NETDEV_BUDGET_USECS=$((3000 + CURVE_STEP * 700))
  FQ_LIMIT=$(clamp "$((BDP_BYTES / MTU * 2 + 4096))" 4096 65536)
  FQ_FLOW_LIMIT=$((100 + CURVE_STEP * 40))
  FQ_QUANTUM=$((MTU * 2))
  FQ_INITIAL_QUANTUM=$((MTU * (8 + CURVE_STEP * 2)))
  # FQ-PIE 流表：旧版固定 1024，实测高并发代理下几乎每个包都在新建流（刷表），
  # 使每流状态（target/deficit）被反复重建，PIE 的公平性与抑抖基本失效。
  if [[ "$FQ_PIE_FLOWS_REQUEST" == auto ]]; then
    FQ_PIE_FLOWS=$(clamp "$BACKLOG" 1024 16384)
  else
    FQ_PIE_FLOWS=$(clamp "$FQ_PIE_FLOWS_REQUEST" 256 65536)
  fi
  PIE_TARGET_MS=$(clamp "$((RTT_MS * (5 + CURVE_STEP) / 100))" 5 30)
  QDISC_MEMORY=$((BUFFER_BYTES / 2))
  QDISC_MEMORY=$(clamp "$QDISC_MEMORY" $((4 * 1024 * 1024)) "$(min "$((MEMORY_MIB * 1048576 / 16))" "$((128 * 1024 * 1024))")")
  # ── 出口整形 ──────────────────────────────────────────────────
  # 只用 cake 整形：实测 Debian 6.1 内核上 `tc qdisc ... fq maxrate` 会被接受
  # 但完全不执行（配 650mbit 仍跑出 858 Mbps），不能作为整形手段。
  case "$SHAPE_REQUEST" in
    off)   SHAPE_MBPS=""; shape_auto=0 ;;
    auto)  SHAPE_MBPS=$bottleneck; shape_auto=1 ;;
    adapt) SHAPE_MBPS=$bottleneck; shape_auto=1; ADAPT=1 ;;
    *)     SHAPE_MBPS=$SHAPE_REQUEST; shape_auto=0 ;;
  esac
  if (( ADAPT )) && [[ -z "$SHAPE_MBPS" ]]; then
    warn "--adapt 需要整形开启，但与 --shape off 冲突；自适应已禁用"
    ADAPT=0
  fi
  if [[ -n "$SHAPE_MBPS" ]]; then
    # ── CPU 上限 ───────────────────────────────────────────────
    # 实测 cake 开销约 0.8~1 核/Gbps。单核节点如果按声明的 1000 Mbps 整形，
    # 会把唯一的核心吃满、反而拖垮代理，所以给每核留一半余量（≈500 Mbps/核）。
    # 自动模式直接降速；显式 --shape N 只告警，尊重用户意图。
    cpu_shape_cap=$(( CPU_COUNT * 500 ))
    (( cpu_shape_cap < 100 )) && cpu_shape_cap=100
    if (( SHAPE_MBPS > cpu_shape_cap )); then
      if (( shape_auto )); then
        warn "自动整形速率 ${SHAPE_MBPS} Mbps 超出本机 ${CPU_COUNT} 核能力，已下调为 ${cpu_shape_cap} Mbps（如需强制：--shape N）"
        SHAPE_MBPS=$cpu_shape_cap
      else
        warn "整形速率 ${SHAPE_MBPS} Mbps 对 ${CPU_COUNT} 核可能过高（建议 ≤ ${cpu_shape_cap} Mbps）"
      fi
    fi
    SHAPE_KBIT=$((SHAPE_MBPS * 1000))
    if (( ADAPT )); then
      SHAPE_SOURCE="adapt = 上限 ${bottleneck} Mbps，按实测重传率自动升降"
    elif (( shape_auto )); then
      SHAPE_SOURCE="auto = 瓶颈带宽 ${bottleneck} Mbps"
      (( SHAPE_MBPS != bottleneck )) && SHAPE_SOURCE="${SHAPE_SOURCE}（CPU 上限下调至 ${SHAPE_MBPS}）" || true
    else
      SHAPE_SOURCE="--shape ${SHAPE_REQUEST}"
    fi
  else
    SHAPE_KBIT=""; SHAPE_SOURCE=""
  fi
  # cake 实际生效的速率：--cake-rate-mbps 优先，其次 --shape；都不给就不传 bandwidth
  # （即真正的无限速。旧版这里会退回 bottleneck×0.94~1.0，导致 --shape off 仍被偷偷限速）
  if [[ -n "$CAKE_RATE_MBPS" ]]; then
    CAKE_RATE_KBIT=$((CAKE_RATE_MBPS * 1000))
    SHAPE_SOURCE="--cake-rate-mbps ${CAKE_RATE_MBPS}"
  elif [[ -n "$SHAPE_KBIT" ]]; then
    CAKE_RATE_KBIT=$SHAPE_KBIT
  else
    CAKE_RATE_KBIT=""
  fi
  # 展示/告警用的派生值，一律以“实际生效速率”为准
  if [[ -n "$CAKE_RATE_KBIT" ]]; then
    SHAPE_GOODPUT_MBPS=$((CAKE_RATE_KBIT / 1000 * 86 / 100))
    SHAPE_CPU_X10=$((CAKE_RATE_KBIT / 1000 * 8 / 1000))
  else
    SHAPE_GOODPUT_MBPS=0; SHAPE_CPU_X10=0
  fi
  RPS_ENTRIES=$(clamp "$((CPU_COUNT * 8192))" 32768 262144)
  RPS_FLOW_PER_QUEUE=$((RPS_ENTRIES / RX_QUEUES))
  TCP_LIMIT_OUTPUT_BYTES=$((BDP_BYTES * (5 + CURVE_STEP) / 100))
  TCP_LIMIT_OUTPUT_BYTES=$(clamp "$TCP_LIMIT_OUTPUT_BYTES" 1048576 16777216)
  select_congestion_control
  select_qdisc
}

adapt_netdev_budget_usecs() {
  local key="net.core.netdev_budget_usecs" current candidate
  candidate=$NETDEV_BUDGET_USECS
  current=$(sysctl -n "$key" 2>/dev/null || true)
  [[ "$current" =~ ^[0-9]+$ ]] || return 0

  # Recent kernels may enforce a clock-dependent minimum for this value.
  # Probe the exact candidate, then immediately restore the previous live
  # value so validation itself has no lasting effect.
  if sysctl -q -w "$key=$candidate" >/dev/null 2>&1; then
    if ! sysctl -q -w "$key=$current" >/dev/null 2>&1; then
      die "验证 $key 后无法恢复原值 $current；已停止应用"
    fi
    return 0
  fi

  NETDEV_BUDGET_USECS=$current
  warn "$key=$candidate 被当前内核拒绝；已自动采用内核当前有效值 $current"
}

human_bytes() {
  local n=$1
  if ((n >= 1073741824)); then printf '%d.%02d GiB' "$((n/1073741824))" "$(((n%1073741824)*100/1073741824))"
  elif ((n >= 1048576)); then printf '%d.%02d MiB' "$((n/1048576))" "$(((n%1048576)*100/1048576))"
  else printf '%d KiB' "$((n/1024))"; fi
}

should_enable_rps() {
  [[ "$TUNE_RPS" == on ]] || [[ "$TUNE_RPS" == auto && "$CPU_COUNT" -gt 1 && "$RX_QUEUES" -le 1 ]]
}

cpu_mask() {
  local remaining=$CPU_COUNT rem groups=()
  rem=$((remaining % 32))
  if ((rem)); then groups+=("$(printf '%x' "$(((1 << rem) - 1))")"); fi
  remaining=$((remaining / 32))
  while ((remaining-- > 0)); do groups+=(ffffffff); done
  local joined="" group
  for group in "${groups[@]}"; do joined+="${joined:+,}$group"; done
  printf '%s' "$joined"
}

build_qdisc_args() {
  case "$QDISC" in
    fq)
      # FQ 的不限速哨兵是 UINT32_MAX 字节/秒；tc 的 maxrate 接收速率数值，
      # 不能套用 CAKE 的 unlimited 标志。显式写入以清除旧的每流限速。
      QDISC_ARGS=(fq limit "$FQ_LIMIT" flow_limit "$FQ_FLOW_LIMIT" quantum "$FQ_QUANTUM" initial_quantum "$FQ_INITIAL_QUANTUM" pacing maxrate 34359738360bit)
      ;;
    fq_pie)
      # flows 无法用 replace 修改（实测报 "Number of flows cannot be changed"），
      # 因此 apply 时先试 replace，失败再 del+add 重建。
      QDISC_ARGS=(fq_pie limit "$FQ_LIMIT" flows "$FQ_PIE_FLOWS" target "${PIE_TARGET_MS}ms" tupdate "${PIE_TARGET_MS}ms" quantum "$MTU" memory_limit "$QDISC_MEMORY" ecn dq_rate_estimator)
      ;;
    cake)
      # CAKE_RATE_KBIT 为空时显式 unlimited，清除上次 bandwidth（--shape off）。
      QDISC_ARGS=(cake)
      if [[ -n "$CAKE_RATE_KBIT" ]]; then
        QDISC_ARGS+=(bandwidth "${CAKE_RATE_KBIT}Kbit")
      else
        # 同一种 cake 实例 replace 时，省略 bandwidth 会保留旧速率。
        QDISC_ARGS+=(unlimited)
      fi
      QDISC_ARGS+=(besteffort flows nonat nowash no-ack-filter rtt "${RTT_MS}ms")
      if [[ -n "$CAKE_RATE_KBIT" ]] && (( CAKE_RATE_KBIT >= 10000000 )); then
        QDISC_ARGS+=(no-split-gso)
      fi
      ;;
  esac
}

print_qdisc_command() {
  local item
  printf 'tc qdisc replace dev %q root' "$IFACE"
  for item in "${QDISC_ARGS[@]}"; do printf ' %q' "$item"; done
  say
}

emit_config() {
  cat <<EOF
# Managed by tcp-tune.sh v${VERSION}
# Inputs: local=${LOCAL_MBPS}Mbps server=${SERVER_MBPS}Mbps rtt=${RTT_MS}ms memory=${MEMORY_MIB}MiB
# RTT source: ${RTT_SOURCE}; target=${RTT_HOST:-manual}; average=${RTT_AVG_MS:-n/a}ms
# Profile: ${PROFILE}; buffer/queue factor=${CURVE}; qdisc=${QDISC}; calculated BDP=${BDP_BYTES} bytes

# Queue discipline and congestion control
EOF
  emit_setting net.core.default_qdisc "$QDISC"
  emit_setting net.ipv4.tcp_congestion_control "$CC"
  say
  say "# BDP-aware socket ceilings; TCP receive auto-tuning remains enabled"
  emit_setting net.core.rmem_max "$BUFFER_BYTES"
  emit_setting net.core.wmem_max "$BUFFER_BYTES"
  emit_setting net.ipv4.tcp_rmem "4096 $RECV_DEFAULT_BYTES $BUFFER_BYTES"
  emit_setting net.ipv4.tcp_wmem "4096 $SEND_DEFAULT_BYTES $BUFFER_BYTES"
  emit_setting net.ipv4.tcp_moderate_rcvbuf 1
  emit_setting net.ipv4.tcp_window_scaling 1
  emit_setting net.ipv4.tcp_limit_output_bytes "$TCP_LIMIT_OUTPUT_BYTES"
  say
  say "# 全局 TCP 内存水位（单位：页）；让单 socket 上限与全局上限自洽"
  emit_setting net.ipv4.tcp_mem "$TCP_MEM_PAGES"
  emit_setting net.core.optmem_max "$OPTMEM_MAX"
  say
  say "# Burst and connection queues"
  emit_setting net.core.netdev_max_backlog "$BACKLOG"
  emit_setting net.core.netdev_budget "$NETDEV_BUDGET"
  emit_setting net.core.netdev_budget_usecs "$NETDEV_BUDGET_USECS"
  emit_setting net.core.somaxconn "$SOMAXCONN"
  emit_setting net.ipv4.tcp_max_syn_backlog "$SOMAXCONN"
  if should_enable_rps; then emit_setting net.core.rps_sock_flow_entries "$RPS_ENTRIES"; else emit_setting net.core.rps_sock_flow_entries 0; fi
  say
  say "# Resilience for tunnels, proxies and long-lived connections"
  emit_setting net.ipv4.tcp_mtu_probing 1
  emit_setting net.ipv4.tcp_fastopen 3
  emit_setting net.ipv4.tcp_sack 1
  emit_setting net.ipv4.tcp_keepalive_time 600
  emit_setting net.ipv4.tcp_keepalive_intvl 30
  emit_setting net.ipv4.tcp_keepalive_probes 5
  emit_setting net.ipv4.tcp_fin_timeout 30
  if [[ "$PROFILE" == streaming || "$PROFILE" == bulk ]]; then
    emit_setting net.ipv4.tcp_slow_start_after_idle 0
  else
    emit_setting net.ipv4.tcp_slow_start_after_idle 1
  fi
  if ((${#ORPHAN_LINES[@]})); then
    say
    say "# ── 非本工具管理的键（上一次 apply 遗留 / --absorb-orphans 继承）──"
    printf '%s\n' "${ORPHAN_LINES[@]}"
  fi
}

emit_setting() {
  local key=$1 value=$2 proc_path="/proc/sys/${1//./\/}"
  if [[ -e "$proc_path" ]]; then
    printf '%s = %s\n' "$key" "$value"
  else
    printf '# unsupported by this kernel: %s\n' "$key"
  fi
}

preview_config() {
  build_qdisc_args
  local shape_text rps_text
  should_enable_rps && rps_text="开（$RPS_ENTRIES 流）" || rps_text="关"
  if [[ "$QDISC" != cake ]]; then
    shape_text="关闭（$QDISC 不整形）"
  elif [[ -n "$CAKE_RATE_KBIT" ]]; then
    if (( ADAPT )); then
      shape_text="自适应，当前/上限 $((CAKE_RATE_KBIT / 1000)) Mbps，允许少量重传"
    else
      shape_text="固定 $((CAKE_RATE_KBIT / 1000)) Mbps"
    fi
  else
    shape_text="关闭（CAKE 不限速）"
  fi

  say
  say "${C_BOLD}优化方案${C_RESET}"
  say "  • 链路：$(min "$LOCAL_MBPS" "$SERVER_MBPS") Mbps，RTT ${RTT_MS} ms，BDP $(human_bytes "$BDP_BYTES")"
  if [[ "$RTT_SOURCE" == ping ]]; then
    say "  • RTT 来源：$(rtt_target_label)，平均 ${RTT_AVG_MS} ms，成功 ${RTT_RECEIVED}/5，丢包 ${RTT_LOSS_PCT}%"
  elif [[ "$RTT_SOURCE" == saved ]]; then
    say "  • RTT 来源：复用上次保存的 ${RTT_MS} ms"
  else
    say "  • RTT 来源：手动输入（跳过 ICMP 测试）"
  fi
  say "  • 算法：$CC + $QDISC（$PROFILE，缓冲/队列倍率 $CURVE）"
  say "  • 整形：$shape_text"
  say "  • 缓冲：单连接 $(human_bytes "$BUFFER_BYTES")；全局上限 $(human_bytes "$TCP_MEM_MAX_BYTES")"
  if [[ "$PROFILE" == streaming ]]; then
    say "  • 单流：保留缓冲自动调节；初始接收 $(human_bytes "$RECV_DEFAULT_BYTES") / 发送 $(human_bytes "$SEND_DEFAULT_BYTES")"
    if (( BUFFER_BYTES < BUFFER_TARGET_BYTES )); then
      warn "单连接缓冲受内存预算限制：目标 $(human_bytes "$BUFFER_TARGET_BYTES")，上限 $(human_bytes "$BUFFER_BYTES")；请用 diagnose 核验是否 rwnd/sndbuf 受限"
    fi
    info "当前上限不等于实际 TCP 窗口；对端窗口、线路与 CPU 仍可能限制单线程速度"
  fi
  say "  • 设备：$IFACE，$CPU_COUNT 核 / ${MEMORY_MIB} MiB，RPS $rps_text"
  [[ "$QDISC" == fq_pie ]] && say "  • FQ-PIE：$FQ_PIE_FLOWS 个流"
  if (( ADAPT )); then
    if [[ "$RETRANS_POLICY" == throughput ]]; then
      say "  • 调速：吞吐优先，≤1% 快速回升；1%-3% 探测；持续 >3% 降 6%；>8% 降 15%"
    else
      say "  • 调速：均衡，≤0.3% 两窗回升；2%~5% 降 8%；>5% 降 15%"
    fi
  fi

  if [[ -n "$CAKE_RATE_KBIT" ]] && (( SHAPE_CPU_X10 > CPU_COUNT * 5 )); then
    warn "CAKE 预计占用约 $((SHAPE_CPU_X10 / 10)).$((SHAPE_CPU_X10 % 10)) 核，繁忙时请留意 CPU。"
  fi
  if (( VERBOSE )); then
    say
    say "${C_BOLD}执行命令${C_RESET}"
    print_qdisc_command
    say
    say "${C_BOLD}完整 sysctl 配置${C_RESET}"
    emit_config
  else
    info "以上为摘要；添加 --verbose 可查看完整 tc 命令和 sysctl 配置"
  fi
}

generated_keys() { printf '%s\n' "${MANAGED_KEYS[@]}"; }

# 优先使用 systemd 给出的文件清单；回退时按同名文件遮蔽与文件名排序处理。
# /etc/sysctl.conf 也可能通过 sysctl.d 内的符号链接加载，不能直接认定无效。
applied_sysctl_files() {
  local f dir name loader="" real
  local -A selected=()
  if systemd_available; then
    loader=$(command -v systemd-sysctl 2>/dev/null || true)
    [[ -n "$loader" ]] || { [[ ! -x /usr/lib/systemd/systemd-sysctl ]] || loader=/usr/lib/systemd/systemd-sysctl; }
    if [[ -n "$loader" ]] && "$loader" --cat-config >/dev/null 2>&1; then
      "$loader" --cat-config 2>/dev/null | sed -n 's|^# \(/.*\)$|\1|p' | while IFS= read -r f; do
        [[ ! -f "$f" ]] || printf '%s\n' "$f"
      done
      return 0
    fi
  fi
  for dir in /usr/lib/sysctl.d /usr/local/lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
    for f in "$dir"/*.conf; do
      [[ -e "$f" || -L "$f" ]] || continue
      name=${f##*/}; selected[$name]=$f
    done
  done
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    f=${selected[$name]}; real=$(readlink -f -- "$f" || true)
    [[ "$real" == /dev/null || ! -f "$f" ]] || printf '%s\n' "$f"
  done < <(printf '%s\n' "${!selected[@]}" | sort)
  if ! systemd_available && [[ -f /etc/sysctl.conf ]]; then printf '%s\n' /etc/sysctl.conf; fi
}

# 审计生效源：报告哪些文件存在却不会开机生效（含高风险键提醒）
audit_sysctl_sources() {
  local f cand n risky
  APPLIED_FILES=(); ORPHAN_FILES=(); CARRY_FILES=()
  # 已存在的本工具配置：二次 apply 时必须把其中“非本工具管理”的键带下去，
  # 否则用不同参数再 apply 一次，上次 --absorb-orphans 继承来的键就丢了。
  [[ -f "$CONFIG_FILE" ]] && CARRY_FILES=("$CONFIG_FILE")
  while IFS= read -r f; do [[ -n "$f" ]] && APPLIED_FILES+=("$f"); done < <(applied_sysctl_files)
  for cand in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [[ -f "$cand" ]] || continue
    for f in "${APPLIED_FILES[@]}"; do [[ "$f" == "$cand" || "$(readlink -f -- "$f")" == "$(readlink -f -- "$cand")" ]] && continue 2; done
    ORPHAN_FILES+=("$cand")
  done
  if (( VERBOSE )); then
    say "${C_BOLD}生效源审计${C_RESET}"
    say "  开机加载：${#APPLIED_FILES[@]} 个 sysctl 文件"
    for f in "${APPLIED_FILES[@]}"; do say "    - $f"; done
  else
    info "配置审计：${#APPLIED_FILES[@]} 个 sysctl 文件开机生效"
  fi
  if ((${#ORPHAN_FILES[@]})); then
    warn "以下文件存在但【开机不会生效】，其中的设置重启后会静默丢失："
    for f in "${ORPHAN_FILES[@]}"; do
      n=$(grep -cE '^[[:space:]]*[a-zA-Z0-9_.]+[[:space:]]*=' "$f" 2>/dev/null || true)
      warn "    - $f（${n:-0} 个键）"
    done
    ((ABSORB_ORPHANS)) || warn "  用 --absorb-orphans 可把它们并入本工具配置（预览会先展示全部内容）"
  else
    ok "未发现“存在但不会生效”的 sysctl 文件"
  fi
  if ((${#READONLY_CONFLICTS[@]})); then
    warn "系统目录（/usr/lib、/run、/usr/local）中有 ${#READONLY_CONFLICTS[@]} 条同类键：不会删除包自带文件，请检查同名文件和按文件名排序的加载优先级"
  fi
}

# 把孤儿文件中“不归本工具管理”的键收集起来（--absorb-orphans）
collect_orphans() {
  ORPHAN_LINES=(); ORPHAN_SKIPPED=()
  local srcs=() entry
  ((ABSORB_ORPHANS)) && srcs+=("${ORPHAN_FILES[@]}")
  if (( RESOLVE_CONFLICTS )); then
    for entry in "${CONFLICTS[@]:-}"; do [[ -z "$entry" ]] || srcs+=("${entry%%:*}"); done
  fi
  srcs+=("${CARRY_FILES[@]}")
  ((${#srcs[@]})) || return 0
  local f line k keys
  declare -A inherited=()
  local order=()
  keys="|$(generated_keys | tr '\n' '|')"
  for f in "${srcs[@]}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_.]+[[:space:]]*=[[:space:]]*[^[:space:]] ]] || continue
      k=${line%%=*}; k=${k//[[:space:]]/}
      [[ "$keys" == *"|$k|"* ]] && continue
      # 内置拒绝表：这两类键在代理节点上风险远大于收益（OOM 直接 panic 重启 /
      # 无限制 overcommit），不自动继承，需要时请手动写进配置文件
      case "$k" in
        vm.panic_on_oom|vm.overcommit_memory)
          ORPHAN_SKIPPED+=("$k"); keys="${keys}${k}|"; continue ;;
      esac
      if [[ ! -v "inherited[$k]" ]]; then order+=("$k"); fi
      inherited[$k]=$line
    done < "$f"
  done
  for k in "${order[@]}"; do ORPHAN_LINES+=("${inherited[$k]}"); done
  if ((${#ORPHAN_SKIPPED[@]})); then
    warn "已跳过高风险键（不自动继承）：${ORPHAN_SKIPPED[*]}；如确实需要请手动写入配置文件"
  fi
  ((${#ORPHAN_LINES[@]})) && info "已保留/继承 ${#ORPHAN_LINES[@]} 个非本工具管理的键"
  return 0
}

# 列出某文件中不归本工具管理的键（删除前提示，避免静默丢失无关设置）
unmanaged_keys_in() {
  local file=$1 line k keys
  keys="|$(generated_keys | tr '\n' '|')"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_.]+[[:space:]]*=[[:space:]]*[^[:space:]] ]] || continue
    k=${line%%=*}; k=${k//[[:space:]]/}
    [[ "$keys" == *"|$k|"* ]] && continue
    printf '%s\n' "$line"
  done < "$file"
}

find_conflicts() {
  local key file line
  CONFLICTS=(); READONLY_CONFLICTS=()
  while IFS= read -r key; do
    # 可接管的：/etc 下属于我们管辖范围的文件
    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
      [[ -f "$file" && "$file" != "$CONFIG_FILE" ]] || continue
      while IFS= read -r line; do
        [[ -n "$line" ]] && CONFLICTS+=("$file:$line")
      done < <(grep -nE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$file" 2>/dev/null || true)
    done
    # 只报告的：系统包自带/运行时目录（不删，本工具的 99- 文件优先级更高）
    for file in /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
      [[ -f "$file" ]] || continue
      while IFS= read -r line; do
        [[ -n "$line" ]] && READONLY_CONFLICTS+=("$file:$line")
      done < <(grep -nE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$file" 2>/dev/null || true)
    done
  done < <(generated_keys)
}


acquire_mutation_lock() {
  command -v flock >/dev/null 2>&1 || die "缺少 flock（util-linux）；无法保证切换与调速不并发"
  install -d -m 0755 "$(dirname "$MUTATION_LOCK_FILE")"
  exec 9>"$MUTATION_LOCK_FILE"
  flock -n 9 || die "另一个调优/调速操作正在运行，请稍后重试"
}

managed_paths() {
  printf '%s\n' "$CONFIG_FILE" "$MODULE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE" \
    "$QDISC_RUNTIME_FILE" "$QDISC_SERVICE_FILE" "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" \
    "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE" "$INPUT_STATE_FILE" \
    "$BACKUP_ROOT/latest" "$BACKUP_ROOT/baseline"
}

backup_file() {
  local source=$1 backup_dir=$2 destination
  if ! grep -Fxq -- "$source" "$backup_dir/files.list" 2>/dev/null; then
    printf '%s\n' "$source" >> "$backup_dir/files.list"
  fi
  [[ -e "$source" || -L "$source" ]] || return 0
  destination="$backup_dir$source"
  mkdir -p "$(dirname "$destination")"
  cp -a -- "$source" "$destination"
}

capture_service_state() {
  local backup_dir=$1 unit enabled active
  : > "$backup_dir/services.tsv"
  systemd_available || return 0
  for unit in "$QDISC_SERVICE_NAME" "$ADAPT_TIMER_NAME" "$ADAPT_SERVICE_NAME" tcp-tune-runtime.service; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$unit" "${enabled:-disabled}" "${active:-inactive}" >> "$backup_dir/services.tsv"
  done
}

stop_managed_services() {
  systemd_available || return 0
  # 持有 flock 后停止旧定时器及正在运行的调速服务，不能只删文件。
  systemctl disable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true
  systemctl stop "$ADAPT_SERVICE_NAME" "$QDISC_SERVICE_NAME" tcp-tune-runtime.service >/dev/null 2>&1 || true
}

capture_live_state() {
  local backup_dir=$1 key value path
  : > "$backup_dir/sysctl.live"
  while IFS= read -r key; do
    value=$(sysctl -n "$key" 2>/dev/null || true)
    [[ -z "$value" ]] || printf '%s = %s\n' "$key" "$value" >> "$backup_dir/sysctl.live"
  done < <({ generated_keys; printf '%s\n' "${ORPHAN_LINES[@]:-}" | awk -F= '/^[[:space:]]*[a-zA-Z0-9_.]+[[:space:]]*=/ {gsub(/[[:space:]]/,"",$1); print $1}'; } | sort -u)
  : > "$backup_dir/rps.tsv"
  for path in "$SYS_NET_DIR/$IFACE/queues"/rx-*/rps_cpus "$SYS_NET_DIR/$IFACE/queues"/rx-*/rps_flow_cnt; do
    [[ -r "$path" ]] || continue
    printf '%s\t%s\n' "$path" "$(<"$path")" >> "$backup_dir/rps.tsv"
  done
  printf '%s\n' "$IFACE" > "$backup_dir/offload.iface"
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -k "$IFACE" > "$backup_dir/offload.txt" 2>/dev/null || true
  fi
}

restore_offloads() {
  local backup_dir=$1 iface feature value failed=0
  [[ -r "$backup_dir/offload.txt" && -r "$backup_dir/offload.iface" ]] || return 0
  command -v ethtool >/dev/null 2>&1 || return 0
  iface=$(<"$backup_dir/offload.iface")
  while IFS=$'\t' read -r feature value; do
    ethtool -K "$iface" "$feature" "$value" >/dev/null 2>&1 || failed=1
  done < <(awk '/^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|rx-checksumming|tx-checksumming):/ && !/\[fixed\]/ {sub(/:$/, "", $1); printf "%s\t%s\n",$1,$2}' "$backup_dir/offload.txt")
  ((failed == 0)) || warn "部分 offload 无法恢复，请检查网卡驱动"
  return 0
}

qdisc_restore_options() {
  # tc show 的元数据（refcnt 等）不是可回放参数；只接收已知语法，绝不 eval。
  local kind=$1 text=$2 token value count i
  local words=() result=()
  IFS=' ' read -r -a words <<< "$text"
  while ((${#words[@]})); do
    token=${words[0]}; words=("${words[@]:1}")
    if [[ "$kind" == cake && "$token" == flows ]]; then result+=(flows); continue; fi
    case "$token" in
      refcnt) ((${#words[@]})) || return 1; words=("${words[@]:1}") ;;
      priomap|weights)
        [[ "$token" != priomap ]] && count=3 || count=16
        ((${#words[@]} >= count)) || return 1
        result+=("$token")
        for ((i=0; i<count; i++)); do
          [[ "${words[$i]}" =~ ^[0-9]+$ ]] || return 1
          result+=("${words[$i]}")
        done
        words=("${words[@]:count}") ;;
      limit|flow_limit|buckets|bands|orphan_mask|quantum|initial_quantum|low_rate_threshold|refill_delay|timer_slack|maxrate|horizon|offload_horizon|ce_threshold|flows|target|interval|memory_limit|drop_batch|tupdate|alpha|beta|ecn_prob|bandwidth|rtt|overhead|mpu|memlimit)
        ((${#words[@]})) || return 1
        value=${words[0]}; words=("${words[@]:1}")
        [[ "$value" =~ ^[a-zA-Z0-9.,/%:-]+$ ]] || return 1
        result+=("$token" "$value") ;;
      pacing|nopacing|horizon_drop|horizon_cap|ecn|noecn|bytemode|nobytemode|dq_rate_estimator|no_dq_rate_estimator|unlimited|autorate-ingress|besteffort|diffserv3|diffserv4|diffserv8|flowblind|flows|srchost|dsthost|hosts|dual-srchost|dual-dsthost|triple-isolate|nat|nonat|wash|nowash|ack-filter|ack-filter-aggressive|no-ack-filter|split-gso|no-split-gso|raw|atm|noatm|ptm|conservative|ingress|egress)
        result+=("$token") ;;
      *) return 1 ;;
    esac
  done
  QDISC_RESTORE_ARGS=("$kind" "${result[@]}")
}

remember_live_qdisc() {
  local backup_dir=$1 line kind handle placement location tail complete=1
  local replay="$backup_dir/qdisc.restore.sh"
  tc qdisc show dev "$IFACE" > "$backup_dir/qdisc.txt" || return 1
  tc -j -d qdisc show dev "$IFACE" > "$backup_dir/qdisc.json" 2>/dev/null || true
  tc class show dev "$IFACE" > "$backup_dir/classes.txt" 2>/dev/null || true
  tc filter show dev "$IFACE" > "$backup_dir/filters.txt" 2>/dev/null || true
  printf '%s\n' "$IFACE" > "$backup_dir/qdisc.iface"
  printf '#!/bin/bash\nset -e\n' > "$replay"
  printf 'tc qdisc del dev %q root 2>/dev/null || true\n' "$IFACE" >> "$replay"
  while IFS= read -r line; do
    [[ "$line" == qdisc* ]] || continue
    # 忽略 ingress/clsact；替换 root 不删除这些入口规则。
    [[ "$line" != *' ingress '* && "$line" != *' clsact '* ]] || continue
    IFS=' ' read -r _ kind handle placement tail <<< "$line"
    location=root
    if [[ "$placement" == parent ]]; then
      IFS=' ' read -r location tail <<< "$tail"
    elif [[ "$placement" != root ]]; then
      complete=0; continue
    fi
    case "$kind" in
      noqueue) printf 'tc qdisc del dev %q root 2>/dev/null || true\n' "$IFACE" >> "$replay"; continue ;;
      mq|pfifo_fast)
        # pfifo_fast 的 bands/priomap 是显示字段，恢复其内核默认即可。
        QDISC_RESTORE_ARGS=("$kind") ;;
      fq|fq_codel|fq_pie|cake)
        qdisc_restore_options "$kind" "$tail" || { complete=0; continue; }
        ;;
      *) complete=0; continue ;;
    esac
    printf 'tc qdisc replace dev %q ' "$IFACE" >> "$replay"
    if [[ "$location" == root ]]; then
      printf 'root ' >> "$replay"
      [[ "$handle" == 0: ]] || printf 'handle %q ' "$handle" >> "$replay"
    else
      printf 'parent %q ' "$location" >> "$replay"
    fi
    printf '%q ' "${QDISC_RESTORE_ARGS[@]}" >> "$replay"
    printf '\n' >> "$replay"
  done < "$backup_dir/qdisc.txt"
  if grep -qE '^class (htb|hfsc|cbq|drr|qfq)' "$backup_dir/classes.txt" || [[ -s "$backup_dir/filters.txt" ]]; then complete=0; fi
  printf '%s\n' "$complete" > "$backup_dir/qdisc.complete"
  if (( complete == 0 )); then
    die "现有出口队列含无法完整回放的自定义参数/class/filter；原始信息已备份到 $backup_dir。请先由原管理工具移除该自定义树。CAKE 的内部 class 不受此限制"
  fi
}

restore_from() {
  local backup_dir=$1 path value unit enabled active failed=0
  stop_managed_services
  [[ -r "$backup_dir/files.list" ]] || { warn "旧版本备份缺少完整清单，无法自动恢复；请使用原版本的 restore"; return 1; }
  while IFS= read -r path; do
    [[ "$path" == /* && "$path" != / && "$path" != *'/../'* ]] || { failed=1; continue; }
    if [[ -e "$backup_dir$path" || -L "$backup_dir$path" ]]; then
      mkdir -p "$(dirname "$path")" || { failed=1; continue; }
      rm -f -- "$path" || { failed=1; continue; }
      cp -a -- "$backup_dir$path" "$path" || failed=1
    else
      rm -f -- "$path" || failed=1
    fi
  done < "$backup_dir/files.list"
  if [[ -r "$backup_dir/sysctl.live" ]]; then sysctl -p "$backup_dir/sysctl.live" >/dev/null || failed=1; fi
  if [[ -r "$backup_dir/qdisc.restore.sh" ]]; then bash "$backup_dir/qdisc.restore.sh" || failed=1; fi
  if [[ -r "$backup_dir/rps.tsv" ]]; then
    while IFS=$'\t' read -r path value; do
      [[ -w "$path" ]] || continue
      printf '%s' "$value" > "$path" || failed=1
    done < "$backup_dir/rps.tsv"
  fi
  restore_offloads "$backup_dir" || failed=1
  if systemd_available; then
    systemctl daemon-reload || failed=1
    while IFS=$'\t' read -r unit enabled active; do
      case "$enabled" in
        enabled) systemctl enable "$unit" >/dev/null 2>&1 || failed=1 ;;
        enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || failed=1 ;;
        *) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
      esac
      # qdisc 已由回放脚本恢复；只重新启动定时器，避免重置恢复的动态速率。
      if [[ "$unit" == "$ADAPT_TIMER_NAME" && "$active" == active ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || failed=1
      fi
    done < "$backup_dir/services.tsv"
  fi
  (( failed == 0 ))
}

transaction_failed() {
  local status=${1:-1}
  trap - ERR INT TERM HUP
  TRANSACTION_ACTIVE=0
  set +e
  warn "操作失败/中断，正在恢复本次修改前的文件、内核参数和队列"
  if restore_from "$CURRENT_BACKUP_DIR"; then
    warn "已回滚；故障备份：$CURRENT_BACKUP_DIR"
  else
    warn "部分项目恢复失败，请检查：$CURRENT_BACKUP_DIR；未宣称完整回滚"
  fi
  exit "$status"
}

apply_rps() {
  local mask=0 count=0 queue failures=0
  if should_enable_rps; then mask=$(cpu_mask); count=$RPS_FLOW_PER_QUEUE; fi
  for queue in "$SYS_NET_DIR/$IFACE/queues"/rx-*; do
    [[ -d "$queue" ]] || continue
    if [[ -e "$queue/rps_cpus" ]]; then { printf '%s' "$mask" > "$queue/rps_cpus"; } 2>/dev/null || failures=$((failures + 1)); fi
    if [[ -e "$queue/rps_flow_cnt" ]]; then { printf '%s' "$count" > "$queue/rps_flow_cnt"; } 2>/dev/null || failures=$((failures + 1)); fi
  done
  ((failures == 0)) && ok "已更新 RPS/RFS（关闭模式会清零）" || warn "部分 RPS 队列不允许修改，已跳过"
  return 0
}

remove_conflict_files() {
  local backup_dir=$1 entry file deleted_count lost
  declare -A touched=()
  for entry in "${CONFLICTS[@]}"; do touched["${entry%%:*}"]=1; done
  deleted_count=${#touched[@]}
  for file in "${!touched[@]}"; do
    # 删前把“不归本工具管理”的键列出来（本机就曾静默丢掉 vm.swappiness=1）
    lost=$(unmanaged_keys_in "$file")
    if [[ -n "$lost" ]]; then
      warn "$file 中以下非调优参数已并入新配置（高风险拒绝项除外）："
      printf '  %s\n' "$lost" >&2
    fi
    backup_file "$file" "$backup_dir"
    rm -f -- "$file"
  done
  ok "已完整备份并删除 $deleted_count 个旧配置文件（包含 ${#CONFLICTS[@]} 条冲突参数）"
}

load_network_modules() {
  command -v modprobe >/dev/null 2>&1 || return 0
  modprobe "sch_${QDISC}" 2>/dev/null || true
  [[ "$CC" == bbr ]] && modprobe tcp_bbr 2>/dev/null || true
}


apply_live_qdisc() {
  command -v tc >/dev/null 2>&1 || { warn "缺少 tc；请安装 iproute2"; return 1; }
  build_qdisc_args
  if [[ "$QDISC" == fq_pie ]]; then
    # flows 未变化时 replace 零中断；需要改 flows 时才 del+add 重建。
    if tc qdisc replace dev "$IFACE" root "${QDISC_ARGS[@]}" 2>/dev/null; then
      ok "已将 fq_pie 实际挂载到 $IFACE（flows=$FQ_PIE_FLOWS）"
    else
      warn "现有 fq_pie 实例无法直接改 flows，改为 del+add 重建（瞬断可忽略）"
      tc qdisc del dev "$IFACE" root 2>/dev/null || true
      if tc qdisc add dev "$IFACE" root "${QDISC_ARGS[@]}"; then
        ok "已将 fq_pie 重建到 $IFACE（flows=$FQ_PIE_FLOWS）"
      else
        warn "fq_pie 无法挂载；可能是内核不支持或参数与当前版本不兼容"
        return 1
      fi
    fi
  elif ! tc qdisc replace dev "$IFACE" root "${QDISC_ARGS[@]}"; then
    warn "qdisc $QDISC 无法挂载；可能是内核不支持或参数与当前版本不兼容"
    return 1
  else
    ok "已将 $QDISC 实际挂载到 $IFACE"
  fi
}


tune_nic_offloads() {
  if (( NIC_TUNE == 0 )); then
    local baseline_dir
    if baseline_dir=$(validated_backup_pointer "$BACKUP_ROOT/baseline"); then restore_offloads "$baseline_dir"; fi
    return 0
  fi
  command -v ethtool >/dev/null 2>&1 || { warn "未安装 ethtool，跳过 NIC offload"; return; }
  ethtool -K "$IFACE" gro on gso on tso on rx on tx on >/dev/null 2>&1 || warn "网卡不支持修改全部 offload，已保留驱动允许的状态"
}

remove_legacy_runtime() {
  local found=0
  [[ -e "$LEGACY_RUNTIME_FILE" || -e "$LEGACY_SERVICE_FILE" ]] && found=1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now tcp-tune-runtime.service >/dev/null 2>&1 || true
  fi
  rm -f "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE"
  if systemd_available; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  ((found)) && ok "已移除旧版本 runtime 和 systemd 服务" || true
}

# 把 qdisc/整形/RPS/offload 落成一个 oneshot 单元，重启后自动重放。
# （sysctl 部分由 systemd-sysctl 读 /etc/sysctl.d 负责，无需在此处理）
install_qdisc_persistence() {
  local tmp ethtool_path mask=0 count=0
  ethtool_path=$(command -v ethtool 2>/dev/null || true)
  build_qdisc_args
  should_enable_rps && { mask=$(cpu_mask); count=$RPS_FLOW_PER_QUEUE; }
  install -d -m 0755 "$(dirname "$QDISC_RUNTIME_FILE")"
  tmp=$(mktemp "${QDISC_RUNTIME_FILE}.XXXXXX")
  {
    printf '#!/bin/bash\n# Managed by tcp-tune.sh v%s\nset -euo pipefail\n' "$VERSION"
    printf 'IFACE=%q\nSYS_NET_DIR=%q\nLOCK_FILE=%q\nADAPT_STATE=%q\n' "$IFACE" "$SYS_NET_DIR" "$MUTATION_LOCK_FILE" "$ADAPT_STATE_FILE"
    cat <<'RUNTIME_EOF'
command -v flock >/dev/null 2>&1 || exit 1
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
for _i in $(seq 1 30); do [[ -d "$SYS_NET_DIR/$IFACE" ]] && break; sleep 1; done
[[ -d "$SYS_NET_DIR/$IFACE" ]] || exit 1
command -v tc >/dev/null 2>&1 || exit 1
RUNTIME_EOF
    if [[ "$QDISC" == fq_pie ]]; then
      printf 'if ! tc qdisc replace dev "$IFACE" root %s; then\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
      printf '  tc qdisc del dev "$IFACE" root 2>/dev/null || true\n'
      printf '  tc qdisc add dev "$IFACE" root %s\nfi\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
    else
      printf 'tc qdisc replace dev "$IFACE" root %s\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
    fi
    if (( ADAPT )); then
      printf 'if [[ -f "$ADAPT_STATE" ]]; then\n'
      printf '  sed -i -e "s/^CUR_KBIT=.*/CUR_KBIT=%s/" -e "s/^LAST_OUT=.*/LAST_OUT=0/" -e "s/^LAST_RETR=.*/LAST_RETR=0/" -e "s/^LAST_TS=.*/LAST_TS=0/" "$ADAPT_STATE"\n' "$CAKE_RATE_KBIT"
      printf '  sed -i -e "s/^OK_COUNT=.*/OK_COUNT=0/" -e "s/^HIGH_COUNT=.*/HIGH_COUNT=0/" "$ADAPT_STATE"\n'
      printf 'fi\n'
    fi
    printf 'for q in "$SYS_NET_DIR/$IFACE/queues"/rx-*; do\n  [[ -d "$q" ]] || continue\n'
    printf '  [[ ! -w "$q/rps_cpus" ]] || printf %%s %q > "$q/rps_cpus"\n' "$mask"
    printf '  [[ ! -w "$q/rps_flow_cnt" ]] || printf %%s %q > "$q/rps_flow_cnt"\n' "$count"
    printf 'done\n'
    if ((NIC_TUNE)) && [[ -n "$ethtool_path" ]]; then
      printf '%q -K "$IFACE" gro on gso on tso on rx on tx on >/dev/null 2>&1 || true\n' "$ethtool_path"
    fi
  } > "$tmp"
  bash -n "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$QDISC_RUNTIME_FILE"
  if systemd_available; then
    cat > "$QDISC_SERVICE_FILE" <<EOF
[Unit]
Description=Re-apply tcp-tune qdisc/RPS/offload settings
Wants=network-online.target
After=network-online.target
ConditionPathExists=$QDISC_RUNTIME_FILE
[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=45
ExecStart=$QDISC_RUNTIME_FILE
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$QDISC_SERVICE_NAME" >/dev/null
    ok "已安装开机队列/RPS 重放单元 $QDISC_SERVICE_NAME"
  else
    warn "未检测到 systemd；队列/RPS 参数只在当前开机生效"
  fi
}

install_adaptive_shaping() {
  local adapt_floor_kbit
  if (( ADAPT == 0 )); then
    if systemd_available; then
      systemctl disable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE"
    return 0
  fi
  command -v tc >/dev/null 2>&1 || return 1
  systemd_available || { warn "自适应整形需要 systemd"; return 1; }
  [[ -n "$CAKE_RATE_KBIT" ]] || { warn "自适应整形需要 cake 速率；已跳过"; ADAPT=0; return 0; }
  install -d -m 0755 "$(dirname "$ADAPT_RUNTIME_FILE")" "$ADAPT_STATE_DIR"

  printf '#!/bin/bash\nSTATE=%q\nLOCK_FILE=%q\nSYS_NET_DIR=%q\n' "$ADAPT_STATE_FILE" "$MUTATION_LOCK_FILE" "$SYS_NET_DIR" > "$ADAPT_RUNTIME_FILE"
  cat >> "$ADAPT_RUNTIME_FILE" <<'ADAPT_EOF' 
# Managed by tcp-tune.sh — 自适应整形控制器
# 由 tcp-tune-adapt.timer 周期调用。吞吐优先：允许少量重传，只有持续明显
# 拥塞才退让；干净、灰区或低流量时更积极回升，避免长期停在低速。
set -u
command -v flock >/dev/null 2>&1 || exit 1
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
[ -r "$STATE" ] || exit 0
. "$STATE"
: "${RETRANS_POLICY:=balanced}" "${HIGH_COUNT:=0}" "${LAST_DROP_TS:=0}" "${LAST_CHANGE_TS:=0}"
case "$RETRANS_POLICY" in throughput|balanced) ;; *) echo "无效重传策略"; exit 1 ;; esac
for field in CEIL_KBIT FLOOR_KBIT CUR_KBIT OK_COUNT HIGH_COUNT LAST_OUT LAST_RETR LAST_TS LAST_DROP_TS LAST_CHANGE_TS; do
  [[ "${!field:-}" =~ ^[0-9]{1,18}$ ]] || { echo "无效的调速状态字段：$field"; exit 1; }
  # 状态文件可含前导零；统一十进制，避免 08/09 被解释为非法八进制。
  printf -v "$field" '%s' "$((10#${!field}))"
done
(( FLOOR_KBIT >= 1000 && FLOOR_KBIT <= CUR_KBIT && CUR_KBIT <= CEIL_KBIT && CEIL_KBIT <= 100000000 )) || exit 1
[[ "$IFACE" != -* && "$IFACE" =~ ^[a-zA-Z0-9_.:@-]+$ ]] || exit 1
command -v tc >/dev/null 2>&1 || exit 0
[ -d "$SYS_NET_DIR/$IFACE" ] || exit 0

# 只在自家挂的 cake 上动作，避免与运维手工改动打架
cur_q=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}')
[ "$cur_q" = cake ] || { echo "当前 qdisc 是 $cur_q，非 cake，跳过"; exit 0; }

# 优先用 nstat；精简系统没有 nstat 时从 /proc/net/snmp 取同一组累计计数。
out= retr=
if command -v nstat >/dev/null 2>&1; then
  IFS=' ' read -r out retr < <(nstat -az 2>/dev/null | awk '
    $1=="TcpOutSegs"{o=$2} $1=="TcpRetransSegs"{r=$2}
    END{if (o ~ /^[0-9]+$/ && r ~ /^[0-9]+$/) printf "%s %s\n", o, r}') || true
fi
if ! [[ "${out:-}" =~ ^[0-9]+$ && "${retr:-}" =~ ^[0-9]+$ ]]; then
  IFS=' ' read -r out retr < <(awk '
    $1=="Tcp:" && !seen++ {for(i=2;i<=NF;i++) col[$i]=i; next}
    $1=="Tcp:" {print $(col["OutSegs"]), $(col["RetransSegs"]); exit}' /proc/net/snmp 2>/dev/null) || true
fi
[[ "${out:-}" =~ ^[0-9]{1,18}$ && "${retr:-}" =~ ^[0-9]{1,18}$ ]] || { echo "无法读取 TCP 计数器"; exit 0; }
out=$((10#$out)); retr=$((10#$retr))
now=$(date +%s)

save_state() {
  sed -i \
    -e "s/^CUR_KBIT=.*/CUR_KBIT=$CUR_KBIT/" \
    -e "s/^OK_COUNT=.*/OK_COUNT=$OK_COUNT/" \
    -e "s/^HIGH_COUNT=.*/HIGH_COUNT=$HIGH_COUNT/" \
    -e "s/^LAST_OUT=.*/LAST_OUT=$out/" \
    -e "s/^LAST_RETR=.*/LAST_RETR=$retr/" \
    -e "s/^LAST_TS=.*/LAST_TS=$now/" \
    -e "s/^LAST_DROP_TS=.*/LAST_DROP_TS=$LAST_DROP_TS/" \
    -e "s/^LAST_CHANGE_TS=.*/LAST_CHANGE_TS=$LAST_CHANGE_TS/" "$STATE"
}

# 首次运行 / 计数器回绕 / 重启：只记基线；兼容旧状态文件。
# 老版本状态文件没有这两个字段，先补齐，使后续 sed 更新可以持久化。
grep -q '^LAST_DROP_TS=' "$STATE" || printf 'LAST_DROP_TS=%s\n' "$LAST_DROP_TS" >> "$STATE"
grep -q '^LAST_CHANGE_TS=' "$STATE" || printf 'LAST_CHANGE_TS=%s\n' "$LAST_CHANGE_TS" >> "$STATE"
grep -q '^HIGH_COUNT=' "$STATE" || printf 'HIGH_COUNT=%s\n' "$HIGH_COUNT" >> "$STATE"
if (( LAST_TS == 0 )) || (( out < LAST_OUT )) || (( retr < LAST_RETR )) || (( now < LAST_TS )); then
  LAST_DROP_TS=$now
  LAST_CHANGE_TS=$now
  OK_COUNT=0; HIGH_COUNT=0
  save_state
  echo "基线建立：out=$out retr=$retr"
  exit 0
fi
d_out=$(( out - LAST_OUT )); d_retr=$(( retr - LAST_RETR )); d_sec=$(( now - LAST_TS ))
(( d_sec > 0 )) || d_sec=1
old=$CUR_KBIT
reason=""

if (( d_out >= 2000 )); then
  ratio_ppm=$(awk -v r="$d_retr" -v o="$d_out" 'BEGIN {printf "%.0f", r*1000000/o}')
  # 启发式策略；统计来自整机本地 TCP 发送，不是每条连接/出口的可用带宽。
  if [[ "$RETRANS_POLICY" == throughput ]]; then
    raise_ppm=10000; drop_ppm=30000; severe_ppm=80000
    bad_windows=2; raise_windows=1; drop_keep=94; raise_pct=12; min_raise_pct=4
    probe_pct=4; probe_wait=90; stable_wait=90
  else
    raise_ppm=3000; drop_ppm=20000; severe_ppm=50000
    bad_windows=1; raise_windows=2; drop_keep=92; raise_pct=8; min_raise_pct=2
    probe_pct=2; probe_wait=120; stable_wait=300
  fi
  if (( ratio_ppm > severe_ppm )); then
    CUR_KBIT=$(( CUR_KBIT * 85 / 100 ))
    OK_COUNT=0; HIGH_COUNT=0
    LAST_DROP_TS=$now
    reason="严重重传"
  elif (( ratio_ppm > drop_ppm )); then
    HIGH_COUNT=$(( HIGH_COUNT + 1 ))
    OK_COUNT=0
    if (( HIGH_COUNT >= bad_windows )); then
      CUR_KBIT=$(( CUR_KBIT * drop_keep / 100 ))
      HIGH_COUNT=0; LAST_DROP_TS=$now
      reason="持续重传偏高"
    fi
  elif (( ratio_ppm <= raise_ppm )); then
    HIGH_COUNT=0
    OK_COUNT=$(( OK_COUNT + 1 ))
    if (( OK_COUNT >= raise_windows )); then
      if (( CUR_KBIT < CEIL_KBIT )); then
        step=$(( CUR_KBIT * raise_pct / 100 )); min_step=$(( CEIL_KBIT * min_raise_pct / 100 ))
        (( step < min_step )) && step=$min_step
        CUR_KBIT=$(( CUR_KBIT + step ))
        reason="可接受重传/低重传样本"
      fi
      OK_COUNT=0
    fi
  else
    OK_COUNT=0; HIGH_COUNT=0
    if (( CUR_KBIT < CEIL_KBIT && now - LAST_DROP_TS >= stable_wait && now - LAST_CHANGE_TS >= probe_wait )); then
      CUR_KBIT=$(( CUR_KBIT + CEIL_KBIT * probe_pct / 100 ))
      reason="可接受重传区间探测"
    fi
  fi

  # 得到足够样本后才推进统计基线。样本不足时保留累计窗口，避免每 30 秒
  # 清零导致低流量永远达不到判定门槛。
  LAST_OUT_NEXT=$out; LAST_RETR_NEXT=$retr; LAST_TS_NEXT=$now
else
  OK_COUNT=0; HIGH_COUNT=0
  LAST_OUT_NEXT=$LAST_OUT; LAST_RETR_NEXT=$LAST_RETR; LAST_TS_NEXT=$LAST_TS
  # 无明显拥塞证据满 2 分钟后，每 2 分钟回升上限的 3%。
  if (( CUR_KBIT < CEIL_KBIT && now - LAST_DROP_TS >= 120 && now - LAST_CHANGE_TS >= 120 )); then
    step=$(( CEIL_KBIT * 3 / 100 )); (( step < 1000 )) && step=1000
    CUR_KBIT=$(( CUR_KBIT + step ))
    reason="低流量积极回升"
  fi
fi
(( CUR_KBIT > CEIL_KBIT )) && CUR_KBIT=$CEIL_KBIT
(( CUR_KBIT < FLOOR_KBIT )) && CUR_KBIT=$FLOOR_KBIT

if (( CUR_KBIT != old )); then
  if tc qdisc change dev "$IFACE" root bandwidth "${CUR_KBIT}Kbit"; then
    LAST_CHANGE_TS=$now
    if (( d_out > 0 )); then
      awk -v why="$reason" -v o="$old" -v n="$CUR_KBIT" -v r="$d_retr" -v t="$d_out" -v s="$d_sec" \
        'BEGIN{printf "整形 %s -> %s Kbit（%s；%s s 内重传 %s/%s = %.3f%%）\n", o, n, why, s, r, t, r*100/t}'
    else
      echo "整形 $old -> $CUR_KBIT Kbit（$reason；${d_sec}s 内无发送样本）"
    fi
  else
    echo "tc 调整失败，保持 $old Kbit"
    CUR_KBIT=$old
  fi
elif (( d_out < 2000 )); then
  echo "累计样本不足（${d_sec}s 内 ${d_out} 段），保持 ${CUR_KBIT} Kbit；满 2000 段评估或到期回升"
fi
if [[ -n "${LAST_OUT_NEXT:-}" ]]; then
  out=$LAST_OUT_NEXT; retr=$LAST_RETR_NEXT; now=$LAST_TS_NEXT
fi
save_state
ADAPT_EOF
  chmod 0755 "$ADAPT_RUNTIME_FILE"

  adapt_floor_kbit=$(clamp "$(( CAKE_RATE_KBIT * 2 / 5 ))" 1000 "$CAKE_RATE_KBIT")
  {
    printf 'IFACE=%q\n' "$IFACE"
    printf 'CEIL_KBIT=%s\n' "$CAKE_RATE_KBIT"
    # 小于 50 Mbps 的线路，下限也不能超过上限。
    printf 'FLOOR_KBIT=%s\n' "$adapt_floor_kbit"
    printf 'CUR_KBIT=%s\n' "$CAKE_RATE_KBIT"
    printf 'RETRANS_POLICY=%s\n' "$RETRANS_POLICY"
    printf 'OK_COUNT=0\nHIGH_COUNT=0\nLAST_OUT=0\nLAST_RETR=0\nLAST_TS=0\nLAST_DROP_TS=0\nLAST_CHANGE_TS=0\n'
    printf 'ARGS=(%s)\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
  } > "$ADAPT_STATE_FILE"
  chmod 0644 "$ADAPT_STATE_FILE"

  if systemd_available; then
    cat > "$ADAPT_SERVICE_FILE" <<EOF
[Unit]
Description=Adaptive cake shaping adjustment (tcp-tune)
Documentation=man:tc(8)
After=network-online.target
ConditionPathExists=$ADAPT_STATE_FILE

[Service]
Type=oneshot
ExecStart=$ADAPT_RUNTIME_FILE
EOF
    cat > "$ADAPT_TIMER_FILE" <<EOF
[Unit]
Description=Periodic adaptive cake shaping adjustment (tcp-tune)

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1; then
      ok "已启用自适应整形：$ADAPT_TIMER_NAME（每 30s 调，上限 $((CAKE_RATE_KBIT/1000)) Mbps，下限 ${adapt_floor_kbit} Kbit）"
    else
      warn "自适应整形单元启用失败；整形仍按固定速率运行"
      return 1
    fi
  else
    warn "自适应整形需要 systemd"
    return 1
  fi
}





apply_config() {
  require_root
  command -v sysctl >/dev/null 2>&1 || die "缺少 sysctl（procps/procps-ng）"
  command -v tc >/dev/null 2>&1 || die "缺少 tc（iproute2）"
  validate_inputs
  detect_interface
  calculate
  if (( ADAPT )) && ! systemd_available; then die "自适应整形需要 systemd；请选固定整形或不整形"; fi
  acquire_mutation_lock
  if [[ -r "$INPUT_STATE_FILE" ]]; then
    local old_iface
    old_iface=$(sed -n 's/^IFACE=//p' "$INPUT_STATE_FILE")
    [[ -z "$old_iface" || "$old_iface" == "$IFACE" ]] || die "当前工具管理 $old_iface；更换网卡前请先卸载，以免旧网卡残留调优"
  fi
  audit_sysctl_sources
  find_conflicts
  collect_orphans

  local backup_dir path tmp
  install -d -m 0700 "$BACKUP_ROOT"
  backup_dir=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).XXXXXX")
  CURRENT_BACKUP_DIR=$backup_dir
  while IFS= read -r path; do backup_file "$path" "$backup_dir"; done < <(managed_paths)
  if [[ -r "$BACKUP_ROOT/latest" ]]; then cp "$BACKUP_ROOT/latest" "$backup_dir/parent-backup"; fi
  capture_service_state "$backup_dir"
  capture_live_state "$backup_dir"
  remember_live_qdisc "$backup_dir"
  # 在任何 live 修改前完成快照；错误/信号都走同一条回滚路径。
  TRANSACTION_ACTIVE=1
  trap 'transaction_failed "$?"' ERR
  trap 'transaction_failed 130' INT
  trap 'transaction_failed 143' TERM
  trap 'transaction_failed 129' HUP
  stop_managed_services
  load_network_modules
  if ! cc_available "$CC"; then
    if [[ "$CC_REQUEST" == auto ]] && cc_available cubic; then CC=cubic; warn "BBR 不可用，auto 模式已改用 Cubic";
    else die "当前内核不支持 $CC；可改选 --cc auto 或 --cc cubic"; fi
  fi
  adapt_netdev_budget_usecs

  if ((${#CONFLICTS[@]})); then
    if ((RESOLVE_CONFLICTS)); then remove_conflict_files "$backup_dir";
    else warn "仍有 ${#CONFLICTS[@]} 条重复参数；--resolve-conflicts 可备份并接管旧文件"; fi
  fi
  write_current_config
  if (( VERBOSE )); then sysctl -p "$CONFIG_FILE"; else sysctl -p "$CONFIG_FILE" >/dev/null; fi
  if ! apply_live_qdisc; then
    if [[ "$QDISC" == cake && "$QDISC_REQUEST" == auto ]]; then
      warn "自动选择的 cake 不可用，降级为 FQ + 不整形"
      set_mode throughput
      calculate
      load_network_modules
      write_current_config
      sysctl -p "$CONFIG_FILE" >/dev/null
      apply_live_qdisc
    else
      die "$QDISC 挂载失败；保持上一模式，正在回滚"
    fi
  fi
  apply_rps
  tune_nic_offloads
  remove_legacy_runtime
  install_qdisc_persistence
  install_adaptive_shaping
  save_link_settings
  printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/latest"
  if [[ ! -r "$BACKUP_ROOT/baseline" ]]; then printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/baseline"; fi
  TRANSACTION_ACTIVE=0
  trap - ERR INT TERM HUP
  exec 9>&-
  say
  ok "优化完成"
  say "  • 算法：$CC + $QDISC"
  if (( ADAPT )); then say "  • 整形：自适应，上限 $((CAKE_RATE_KBIT/1000)) Mbps"
  elif [[ -n "$CAKE_RATE_KBIT" ]]; then say "  • 整形：固定 $((CAKE_RATE_KBIT/1000)) Mbps"
  else say "  • 整形：关闭"; fi
  say "  • 配置：$CONFIG_FILE"
  say "  • 备份：$backup_dir"
}

write_current_config() {
  local tmp
  install -d -m 0755 "$(dirname "$CONFIG_FILE")" "$(dirname "$MODULE_FILE")"
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
  emit_config > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
  tmp=$(mktemp "${MODULE_FILE}.XXXXXX")
  { [[ "$CC" != bbr ]] || printf '%s\n' tcp_bbr; printf '%s\n' "sch_$QDISC"; } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MODULE_FILE"
}

validated_backup_pointer() {
  local pointer=$1 path root
  [[ -r "$pointer" ]] || return 1
  path=$(realpath -e -- "$(<"$pointer")" 2>/dev/null) || return 1
  root=$(realpath -e -- "$BACKUP_ROOT") || return 1
  [[ "$path" == "$root"/* && -d "$path" ]] || return 1
  printf '%s' "$path"
}

restore_latest() {
  require_root
  local backup_dir
  backup_dir=$(validated_backup_pointer "$BACKUP_ROOT/latest") || die "没有有效的备份记录"
  [[ -r "$backup_dir/files.list" ]] || die "这是旧版不完整备份，请用原版脚本恢复"
  confirm "恢复备份 $backup_dir？" || { info "已取消"; return 0; }
  acquire_mutation_lock
  local locked_backup_dir
  locked_backup_dir=$(validated_backup_pointer "$BACKUP_ROOT/latest") || die "等待确认期间备份已改变，请重新执行 restore"
  [[ "$locked_backup_dir" == "$backup_dir" ]] || die "等待确认期间最新备份已改变，请重新执行 restore"
  if ! restore_from "$backup_dir"; then exec 9>&-; die "部分恢复失败，请检查 $backup_dir"; fi
  if [[ -r "$backup_dir/parent-backup" ]]; then cp "$backup_dir/parent-backup" "$BACKUP_ROOT/latest"; else rm -f "$BACKUP_ROOT/latest"; fi
  # 回到首次调优之前后，下次 apply 重新记录基线。
  if [[ -r "$BACKUP_ROOT/baseline" && "$(<"$BACKUP_ROOT/baseline")" == "$backup_dir" ]]; then rm -f "$BACKUP_ROOT/baseline"; fi
  exec 9>&-
  ok "已恢复文件、内核参数、队列和原调速定时器：$backup_dir"
}

uninstall_config() {
  require_root
  local backup_dir
  backup_dir=$(validated_backup_pointer "$BACKUP_ROOT/baseline") || die "缺少首次调优基线；为避免伪恢复，请先 restore 最近备份或用旧版卸载"
  confirm "卸载并恢复首次使用本版本之前的设置？备份会保留。" || { info "已取消"; return 0; }
  acquire_mutation_lock
  local locked_backup_dir
  locked_backup_dir=$(validated_backup_pointer "$BACKUP_ROOT/baseline") || die "等待确认期间基线已改变，请重新执行 uninstall"
  [[ "$locked_backup_dir" == "$backup_dir" ]] || die "等待确认期间基线已改变，请重新执行 uninstall"
  if ! restore_from "$backup_dir"; then exec 9>&-; die "部分卸载恢复失败，请检查 $backup_dir"; fi
  rm -f "$BACKUP_ROOT/latest" "$BACKUP_ROOT/baseline"
  exec 9>&-
  ok "已恢复首次调优之前的设置；备份仍保留在 $BACKUP_ROOT"
}

diagnose() {
  show_version
  status
  say
  say "单线程诊断（请在 iperf3 正在运行时执行）"
  local key value
  for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
    net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling net.ipv4.tcp_sack \
    net.ipv4.tcp_timestamps net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_notsent_lowat \
    net.ipv4.tcp_adv_win_scale net.ipv4.tcp_no_metrics_save net.ipv4.tcp_limit_output_bytes; do
    value=$(sysctl -n "$key" 2>/dev/null || say unavailable)
    printf '  %s = %s\n' "$key" "$value"
  done
  value=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || true)
  if is_uint "$value" && (( value <= 65536 )); then
    info "tcp_notsent_lowat 较小：它限制未发送数据的排队并影响应用唤醒，不是 TCP 拥塞窗口；需对照实测判断影响。"
  fi
  value=$(sysctl -n vm.panic_on_oom 2>/dev/null || true)
  if [[ "$value" == 1 || "$value" == 2 ]]; then
    warn "当前 vm.panic_on_oom=$value：内存不足可能触发内核 panic；本工具未修改此系统策略。"
  fi
  if [[ -r "$INPUT_STATE_FILE" ]]; then
    say "已保存的链路与模式："
    awk -F= '$1 ~ /^(LOCAL_MBPS|SERVER_MBPS|RTT_MS|MEMORY_MIB|MODE|PROFILE|SHAPE|RETRANS_POLICY)$/ {print "  " $0}' "$INPUT_STATE_FILE"
  fi
  say "TCP 内存使用："
  awk '$1 == "TCP:" || $1 == "sockets:" {print "  " $0}' /proc/net/sockstat 2>/dev/null || true
  say "内存可用量："
  awk '$1 == "MemTotal:" || $1 == "MemAvailable:" {print "  " $0}' /proc/meminfo
  if [[ -n "$DIAG_PORT" ]]; then
    say "活动 TCP 连接（测速端口 $DIAG_PORT，前 80 行）："
  else
    say "活动 TCP 连接（前 80 行，可用 --test-port 筛选测速连接）："
  fi
  if command -v ss >/dev/null 2>&1; then
    local sockets
    if [[ -n "$DIAG_PORT" ]]; then
      sockets=$(ss -tinm state established "( sport = :$DIAG_PORT or dport = :$DIAG_PORT )" 2>/dev/null || true)
    else
      sockets=$(ss -tinm state established 2>/dev/null || true)
    fi
    if [[ -n "$sockets" ]]; then printf '%s\n' "$sockets" | sed -n '1,80p'; else info "没有可读取的活动连接"; fi
  else
    warn "缺少 ss，请安装 iproute2 后在测速中运行 diagnose"
  fi
  info "bbr/cubic 是该连接实际算法；rtt 是实际路径延迟；snd_wnd 是对端通告窗口。"
  info "rwnd_limited / sndbuf_limited 表示受对端窗口/本地发送缓冲限制的时间，需结合传输时长观察。"
  info "iperf3 -R 的发送方在服务器：请在服务器测速期间诊断；数据连接通常有较大的 bytes_sent/bytes_received。"
  info "sysctl 修改通常不会替已有 TCP 连接更换拥塞算法；切换后新建测速连接，并核对 ss 中实际算法。"
  info "新连接也可能继承旧监听 socket 的算法；如果仍是旧算法，请重启 iperf3 服务后复测。"
  info "累计整机重传为 0 不能代表远端发送方或本次测速；请同时保留 iperf3 的 sender/receiver 输出。"
  return 0
}

status() {
  say "${C_BOLD}TCP 当前状态${C_RESET}"
  printf '  %-18s %s\n' "内核" "$(uname -r)"
  printf '  %-18s %s\n' "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || say unavailable)"
  printf '  %-18s %s\n' "可用算法" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || say unavailable)"
  printf '  %-18s %s\n' "默认 qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || say unavailable)"
  printf '  %-18s %s\n' "rmem_max" "$(sysctl -n net.core.rmem_max 2>/dev/null || say unavailable)"
  printf '  %-18s %s\n' "wmem_max" "$(sysctl -n net.core.wmem_max 2>/dev/null || say unavailable)"
  printf '  %-18s %s\n' "tcp_mem(页)" "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null || say unavailable)"

  local status_iface=$IFACE
  if [[ "$status_iface" == auto ]]; then
    status_iface=""
    if [[ -r "$INPUT_STATE_FILE" ]]; then status_iface=$(sed -n 's/^IFACE=//p' "$INPUT_STATE_FILE"); fi
    if [[ -z "$status_iface" ]] && command -v ip >/dev/null 2>&1; then
      status_iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
      [[ -n "$status_iface" ]] || status_iface=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
    fi
  fi
  if [[ -n "$status_iface" ]] && command -v tc >/dev/null 2>&1; then
    local qline qstat
    qline=$(tc qdisc show dev "$status_iface" 2>/dev/null | awk '$0 ~ / root / {print; exit}' || true)
    printf '  %-18s %s\n' "实际 qdisc" "$qline"
    if [[ "$qline" == *cake* ]]; then
      [[ "$qline" == *bandwidth* ]] && ok "整形已生效（cake bandwidth）" || warn "cake 未设 bandwidth = 实际没有整形"
    fi
    qstat=$(tc -s qdisc show dev "$status_iface" 2>/dev/null | grep -m1 'dropped' || true)
    [[ -n "$qstat" ]] && printf '  %-18s %s\n' "qdisc 丢/超限" "$(sed -n 's/.*(dropped \([0-9]*\), overlimits \([0-9]*\).*/\1 \/ \2/p' <<<"$qstat")"
  fi

  if command -v nstat >/dev/null 2>&1; then
    local out ret lr tmo ofo
    # 注意：脚本顶部 IFS 不含空格，这里必须显式指定按空格拆字段
    IFS=' ' read -r out ret lr tmo ofo < <(nstat -az 2>/dev/null | awk '
      BEGIN{o=r=l=t=f="0"}
      $1=="TcpOutSegs"{o=$2} $1=="TcpRetransSegs"{r=$2} $1=="TcpExtTCPLostRetransmit"{l=$2}
      $1=="TcpExtTCPTimeouts"{t=$2} $1=="TcpExtTCPOFOQueue"{f=$2}
      END{printf "%s %s %s %s %s\n", o, r, l, t, f}') || true
    if [[ "${out:-}" =~ ^[0-9]{1,18}$ && "${ret:-}" =~ ^[0-9]{1,18}$ ]] && (( 10#$out > 0 )); then
      printf '  %-18s %s\n' "整机发送重传(累计)" "$(awk -v r="$ret" -v o="$out" 'BEGIN{ printf "%.3f%%  (%s/%s)", r*100/o, r, o }')"
      printf '  %-18s %s\n' "重传又丢/超时" "$lr / $tmo"
      printf '  %-18s %s\n' "乱序入队" "$ofo"
    fi
  fi

  local ccmax cccur
  ccmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
  cccur=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || true)
  if [[ "$ccmax" =~ ^[0-9]+$ && "$cccur" =~ ^[0-9]+$ && "$ccmax" -gt 0 ]]; then
    printf '  %-18s %s\n' "conntrack" "$cccur / $ccmax ($(( cccur * 100 / ccmax ))%)"
    (( cccur * 100 / ccmax > 80 )) && warn "conntrack 已用超 80%：高峰可能丢包或建连失败" || true
  fi

  if command -v ss >/dev/null 2>&1; then
    local tot small socket_snapshot
    socket_snapshot=$(ss -tin state established 2>/dev/null || true)
    # 精确匹配 mss 字段，不把 advmss 当作第二条连接；单次扫描快照。
    IFS=' ' read -r tot small < <(printf '%s\n' "$socket_snapshot" | awk '
      {for(i=1;i<=NF;i++) if($i ~ /^mss:[0-9]+$/) {
        n++; split($i, a, ":"); if(a[2] < 1200) s++; break
      }} END{printf "%d %d\n", n, s}')
    if (( ${tot:-0} > 0 )); then
      printf '  %-18s %s\n' "MSS<1200 连接" "${small:-0} / $tot"
      (( ${small:-0} > 0 )) && warn "存在对端 MTU/MSS 偏小的连接：同样丢包率下重传次数被成倍放大" || true
    fi
  fi

  if [[ -f "$QDISC_SERVICE_FILE" ]] && command -v systemctl >/dev/null 2>&1 \
     && systemctl is-enabled "$QDISC_SERVICE_NAME" >/dev/null 2>&1; then
    ok "qdisc 持久化单元已启用（$QDISC_SERVICE_NAME）"
  else
    warn "未安装/未启用 qdisc 持久化单元：重启后整形与 qdisc 参数会丢失"
  fi

  local napp norph cand f
  local status_files=()
  while IFS= read -r f; do [[ -z "$f" ]] || status_files+=("$f"); done < <(applied_sysctl_files 2>/dev/null)
  napp=${#status_files[@]}; norph=0
  for cand in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [[ -f "$cand" ]] || continue
    for f in "${status_files[@]}"; do [[ "$f" == "$cand" || "$(readlink -f -- "$f")" == "$(readlink -f -- "$cand")" ]] && continue 2; done
    norph=$(( norph + 1 ))
  done
  printf '  %-18s %s\n' "开机生效文件" "$napp 个（另有 $norph 个不生效）"
  (( norph > 0 )) && warn "有 $norph 个 sysctl 文件不会开机生效，重启后其中的设置会丢失" || true

  if [[ -f "$ADAPT_TIMER_FILE" ]]; then
    local a_rate a_ceil
    a_rate=$(sed -n 's/^CUR_KBIT=\([0-9]*\)/\1/p' "$ADAPT_STATE_FILE" 2>/dev/null || true); a_rate=${a_rate:-0}
    a_ceil=$(sed -n 's/^CEIL_KBIT=\([0-9]*\)/\1/p' "$ADAPT_STATE_FILE" 2>/dev/null || true); a_ceil=${a_ceil:-0}
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active "$ADAPT_TIMER_NAME" >/dev/null 2>&1; then
      printf '  %-18s %s\n' "自适应整形" "运行中：当前 $(( a_rate / 1000 )) Mbps / 上限 $(( a_ceil / 1000 )) Mbps"
    else
      warn "自适应整形单元存在但 timer 未运行"
    fi
  fi

  [[ -f "$CONFIG_FILE" ]] && ok "已安装 $CONFIG_FILE" || info "尚未安装本工具配置"
  return 0
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; return 0 ;;
      -V|--version) show_version; return 0 ;;
    esac
  done
  if [[ "${1:-}" == version ]]; then show_version; return 0; fi
  if [[ "${1:-}" == switch ]]; then
    load_link_settings || die "switch 需要先完成一次 apply/wizard，以保存链路参数"
    load_tuning_settings
    for arg in "$@"; do
      case "$arg" in --rtt-ms|--rtt-host|--rtt-line) RTT_MS=""; RTT_SOURCE=manual; break ;; esac
    done
  fi
  parse_args "$@"
  if [[ -n "$DIAG_PORT" ]]; then
    [[ "$ACTION" == diagnose ]] || die "--test-port 仅用于 diagnose"
  fi
  if (( DRY_RUN )); then
    case "$ACTION" in preview|apply|switch|quick|setup|install|wizard) ;; *) die "--dry-run 仅用于方案预览或安装预览" ;; esac
  fi
  resolve_rtt_args
  require_linux
  [[ -n "$MEMORY_MIB" ]] || MEMORY_MIB=$(detect_memory_mib)
  case "$ACTION" in
    quick|setup) quick_setup ;;
    install)
      if (( DRY_RUN )) || confirm "安装 / 更新 tcp-tune 命令？（不修改网络）"; then install_cli; else info "已取消"; fi
      ;;
    wizard) wizard ;;
    rtt)
      [[ -z "$RTT_MS" ]] || die "rtt 操作用于测量延迟，请使用 --rtt-line 或 --rtt-host"
      if [[ -n "$RTT_HOST" ]]; then
        measure_rtt "$RTT_HOST" || die "RTT 测试失败；可以更换线路/目标，或在 preview/apply 中使用 --rtt-ms"
      elif [[ -t 0 ]]; then
        choose_rtt || return 0
      else
        die "非交互 RTT 测试需要 --rtt-line mobile|telecom 或 --rtt-host IP或域名"
      fi
      say "$RTT_MS"
      ;;
    preview|apply|switch)
      [[ -n "$LOCAL_MBPS" && -n "$SERVER_MBPS" ]] || die "preview/apply 需要 --local-mbps 和 --server-mbps；或使用 wizard"
      if [[ -n "$RTT_HOST" ]]; then
        measure_rtt "$RTT_HOST" || die "RTT 测试失败；请更换目标或使用 --rtt-ms 手动设置"
      elif [[ -z "$RTT_MS" && -t 0 ]]; then
        choose_rtt || return 0
      fi
      [[ -n "$RTT_MS" ]] || die "preview/apply 需要 RTT 参数（--rtt-ms、--rtt-host 或 --rtt-line）；交互终端可直接选择"
      validate_inputs; detect_interface; calculate
      audit_sysctl_sources; find_conflicts; collect_orphans
      preview_config
      if [[ "$ACTION" == apply || "$ACTION" == switch ]]; then
        if (( DRY_RUN )); then info "预览结束，未作修改"
        elif confirm "确认应用？"; then apply_config; else info "已取消"; fi
      fi
      ;;
    status) status ;;
    diagnose) diagnose ;;
    restore) restore_latest ;;
    uninstall) uninstall_config ;;
    "") if [[ -t 0 ]]; then main_menu; else usage; fi ;;
    help|-h|--help) usage ;;
    *) die "未知操作：$ACTION（使用 --help 查看帮助）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
