#!/usr/bin/env bash
# tcp-tune.sh - throughput-oriented Linux TCP/qdisc tuning assistant
# License: MIT
#
# ── 本地维护版 3.2.2 相对上游 v3.2.1 的改动摘要 ──────────────────────────────
# 出口整形
#   · 新增 --shape auto|off|N（默认 auto = 按瓶颈带宽 min(local,server) 用 cake 整形）
#   · 实测 Debian 6.1 上 `tc qdisc fq maxrate` 被接受但不执行，整形只能用 cake
#   · CPU 感知：auto 模式上限 = 核数 × 500 Mbps（实测 cake ≈0.8~1 核/Gbps），
#     超出自动下调；显式 --shape N 只告警不降速
#   · cake 无法挂载时自动降级为不整形并重写配置（旧版会整体失败 + 回滚）
#   · --shape off 时 cake 不传 bandwidth（真正不限速；旧版会偷偷按 bottleneck×0.98 限速）
#   · 显示一律使用"实际生效值"，并标注来源（auto / adapt / --shape N / --cake-rate-mbps N）
#   · 新增 --shape adapt / --adapt：自适应整形，systemd timer 每 30s 按实测重传率升降速率
#     （重传率 >1% 降 15%；<0.1% 连续 3 次升 5%；区间 [上限的 20%, 上限]）
#   · 默认整形模式由 auto 改为 adapt（自适应）；--shape auto 可退回固定速率
# 内存模型
#   · 新增 net.ipv4.tcp_mem / net.core.optmem_max，单 socket 上限收紧到全局 high 的 1/4
#     （旧版 rmem_max 可大于 tcp_mem high，自相矛盾；实测出现过 rmem_max 124MiB > high 116MiB）
# 生效源审计
#   · 识别"存在但开机不生效"的 sysctl 文件（systemd-sysctl 不读 /etc/sysctl.conf）
#   · 新增 --absorb-orphans 把旧文件并入本工具配置；吸收的键跨 apply 自动保留
#   · 内置拒绝表：vm.panic_on_oom / vm.overcommit_memory 不自动继承
#   · 扩展冲突扫描到 /run、/usr/local/lib、/usr/lib 的 sysctl.d（只报告，不删包文件）
# 输入解析
#   · 统一 10# 归一化，修掉 --rtt-ms 0100 被当八进制 64 的静默错算
#   · --curve 支持两位小数（0.75）
# fq_pie
#   · flows 可配置（--fq-pie-flows，auto 按连接容量推算）；replace 失败自动 del+add 重建
# qdisc 持久化
#   · 新增 tcp-tune-qdisc.service（oneshot）重启后重放 qdisc/整形/RPS/offload
# status
#   · 新增重传率、重传又丢/超时、乱序、qdisc 丢弃/超限、conntrack 使用率、
#     MSS<1200 连接数、持久化单元状态、开机生效文件计数
# 向导
#   · 新增出口整形提问（auto / 不整形 / 自定义速率）；带宽提示改为"填实测干净吞吐"
# ────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.2.4"
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

ACTION=""
LOCAL_MBPS=""
SERVER_MBPS=""
RTT_MS=""
MEMORY_MIB=""
PROFILE="streaming"
CURVE="0.7"
CURVE_STEP=7
QDISC_REQUEST="auto"
QDISC=""
CC_REQUEST="auto"
CC=""
ROLE="host"
IFACE="auto"
TUNE_RPS="auto"
NIC_TUNE=0
CAKE_RATE_MBPS=""
SHAPE_REQUEST="adapt"
SHAPE_MBPS=""
SHAPE_KBIT=""
SHAPE_GOODPUT_MBPS=0
SHAPE_CPU_X10=0
SHAPE_SOURCE=""
ADAPT=0
FQ_PIE_FLOWS_REQUEST="auto"
FQ_PIE_FLOWS=""
ASSUME_YES=0
RESOLVE_CONFLICTS=0
ABSORB_ORPHANS=0
NO_COLOR=0
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
info() { printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
tcp-tune.sh - 交互式 Linux TCP 调优工具

用法：
  sudo bash tcp-tune.sh              # 推荐：打开交互式主菜单
  sudo bash tcp-tune.sh wizard
  bash tcp-tune.sh preview [参数]
  sudo bash tcp-tune.sh apply [参数]
  sudo bash tcp-tune.sh restore [--yes]
  sudo bash tcp-tune.sh uninstall [--yes]
  bash tcp-tune.sh status

参数：
  --local-mbps N        本地接入带宽（Mbps）
  --server-mbps N       服务器端口带宽（Mbps）
  --rtt-ms N            典型往返延迟（ms）
  --memory-mib N        用于计算的内存；默认自动检测
  --profile NAME        balanced | streaming | latency | bulk
  --qdisc NAME          auto | fq | fq_pie | cake
  --cc NAME             auto | bbr | cubic
  --role NAME           host（代理/VPS）| router（转发设备）
  --interface NAME      出口网卡；默认自动检测
  --curve N             爬升积极度 0.1-1.0；默认 0.7
  --cake-rate-mbps N    CAKE 的显式整形速率
  --shape MODE          出口整形：adapt（默认，自适应）| auto（固定）| off | N(Mbps)
                        adapt = 以瓶颈带宽为上限，按实测重传率自动升降速
                                （晚高峰自动降速保干净、平峰自动升回上限；需 systemd）
                        auto  = 按瓶颈带宽 min(local,server) 定速，不自动调整
                        off   = cake 不传 bandwidth（真正不限速）
                        整形把重传/抖动压到近 0，代价是峰值吞吐约 -14%（见下方实测）
  --adapt               等价于 --shape adapt（已是默认）
  --fq-pie-flows N      FQ-PIE 流表大小；auto=按连接容量推算（默认），范围 256-65536
  --rps MODE            auto | on | off
  --nic-tune            尝试开启 GRO/GSO/TSO 等吞吐型 offload
  --resolve-conflicts   备份并删除包含冲突参数的整个旧配置文件
  --absorb-orphans      把“存在但开机不会生效”的 sysctl 文件（如 systemd 不读的
                        /etc/sysctl.conf）中的键并入本工具配置，配合
                        --resolve-conflicts 即可真正做到只留一个文件
  --yes                 跳过确认
  --no-color            禁用颜色
  -h, --help            显示帮助

示例：
  sudo bash tcp-tune.sh apply --local-mbps 1000 --server-mbps 500 \
    --rtt-ms 180 --profile streaming --qdisc fq --curve 0.8
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
# 归一化：把可带前导零的十进制串转成规范十进制，避免 bash 算术把 0100 当八进制(64)
norm_uint() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$(( 10#$1 ))"; else printf '%s' "$1"; fi; }
clamp() { local n=$1 lo=$2 hi=$3; ((n < lo)) && n=$lo; ((n > hi)) && n=$hi; printf '%s' "$n"; }
min() { local a b; a=$(norm_uint "$1"); b=$(norm_uint "$2"); (( a < b )) && printf '%s' "$a" || printf '%s' "$b"; }

parse_args() {
  ACTION="${1:-}"
  [[ $# -gt 0 ]] && shift
  while (($#)); do
    case "$1" in
      --local-mbps)      [[ $# -ge 2 ]] || die "$1 缺少数值"; LOCAL_MBPS=$2; shift 2 ;;
      --server-mbps)     [[ $# -ge 2 ]] || die "$1 缺少数值"; SERVER_MBPS=$2; shift 2 ;;
      --rtt-ms)          [[ $# -ge 2 ]] || die "$1 缺少数值"; RTT_MS=$2; shift 2 ;;
      --memory-mib)      [[ $# -ge 2 ]] || die "$1 缺少数值"; MEMORY_MIB=$2; shift 2 ;;
      --profile)         [[ $# -ge 2 ]] || die "$1 缺少名称"; PROFILE=$2; shift 2 ;;
      --qdisc)           [[ $# -ge 2 ]] || die "$1 缺少名称"; QDISC_REQUEST=$2; shift 2 ;;
      --cc)              [[ $# -ge 2 ]] || die "$1 缺少名称"; CC_REQUEST=$2; shift 2 ;;
      --role)            [[ $# -ge 2 ]] || die "$1 缺少名称"; ROLE=$2; shift 2 ;;
      --interface)       [[ $# -ge 2 ]] || die "$1 缺少名称"; IFACE=$2; shift 2 ;;
      --curve)           [[ $# -ge 2 ]] || die "$1 缺少数值"; CURVE=$2; shift 2 ;;
      --cake-rate-mbps)  [[ $# -ge 2 ]] || die "$1 缺少数值"; CAKE_RATE_MBPS=$2; shift 2 ;;
      --shape)           [[ $# -ge 2 ]] || die "$1 缺少数值"; SHAPE_REQUEST=$2; shift 2 ;;
      --adapt)           ADAPT=1; shift ;;
      --fq-pie-flows)    [[ $# -ge 2 ]] || die "$1 缺少数值"; FQ_PIE_FLOWS_REQUEST=$2; shift 2 ;;
      --rps)             [[ $# -ge 2 ]] || die "$1 缺少模式"; TUNE_RPS=$2; shift 2 ;;
      --nic-tune)        NIC_TUNE=1; shift ;;
      --resolve-conflicts) RESOLVE_CONFLICTS=1; shift ;;
      --absorb-orphans)  ABSORB_ORPHANS=1; shift ;;
      --yes|-y)          ASSUME_YES=1; shift ;;
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
  normalize_curve
  case "$PROFILE" in balanced|streaming|latency|bulk) ;; *) die "未知场景：$PROFILE" ;; esac
  case "$QDISC_REQUEST" in auto|fq|fq_pie|cake) ;; *) die "未知 qdisc：$QDISC_REQUEST" ;; esac
  case "$CC_REQUEST" in auto|bbr|cubic) ;; *) die "未知拥塞控制：$CC_REQUEST" ;; esac
  case "$ROLE" in host|router) ;; *) die "role 必须是 host 或 router" ;; esac
  case "$TUNE_RPS" in auto|on|off) ;; *) die "rps 必须是 auto、on 或 off" ;; esac
  if [[ -n "$CAKE_RATE_MBPS" ]]; then
    is_uint "$CAKE_RATE_MBPS" || die "cake-rate-mbps 必须是正整数"
    CAKE_RATE_MBPS=$(norm_uint "$CAKE_RATE_MBPS")
  fi
  case "$SHAPE_REQUEST" in
    auto|adapt|off) ;;
    *)
      is_uint "$SHAPE_REQUEST" || die "shape 必须是 auto、off 或正整数 Mbps（当前：${SHAPE_REQUEST:-空}）"
      SHAPE_REQUEST=$(norm_uint "$SHAPE_REQUEST")
      ;;
  esac
  case "$FQ_PIE_FLOWS_REQUEST" in
    auto) ;;
    *)
      is_uint "$FQ_PIE_FLOWS_REQUEST" || die "fq-pie-flows 必须是 auto 或正整数（当前：${FQ_PIE_FLOWS_REQUEST:-空}）"
      FQ_PIE_FLOWS_REQUEST=$(norm_uint "$FQ_PIE_FLOWS_REQUEST")
      ;;
  esac
  [[ "$IFACE" == auto || "$IFACE" =~ ^[a-zA-Z0-9_.:@-]+$ ]] || die "网卡名称含有非法字符"
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
    IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$IFACE" ]] || IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  fi
  [[ -n "$IFACE" && -d "/sys/class/net/$IFACE" ]] || die "无法找到出口网卡：${IFACE:-空}"
  MTU=$(<"/sys/class/net/$IFACE/mtu")
  is_uint "$MTU" || MTU=1500
  CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || say 1)
  is_uint "$CPU_COUNT" || CPU_COUNT=1
  RX_QUEUES=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l)
  TX_QUEUES=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)
  ((RX_QUEUES > 0)) || RX_QUEUES=1
  ((TX_QUEUES > 0)) || TX_QUEUES=1
}

prompt_default() {
  local prompt=$1 default=$2 answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
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
    read -r -p "请选择 [$default_index]: " answer
    answer=${answer:-$default_index}
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      option=${options[$((answer - 1))]}
      printf -v "$target" '%s' "${option%%|*}"
      return 0
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
  say "${C_BOLD}TCP 自适应调优向导 v${VERSION}${C_RESET}"
  say "直接按回车即可采用推荐值。"
  say "带宽请填【实测的干净吞吐】而不是套餐带宽：实测干净容量常明显低于端口速率，"
  say "填高了自动整形就会偏高、高峰仍会丢包（可用 iperf3 -P 16/32 快速找拐点）。"
  say
  LOCAL_MBPS=$(prompt_default "本地宽带（Mbps）" "1000")
  SERVER_MBPS=$(prompt_default "服务器端口（Mbps）" "1000")
  RTT_MS=$(prompt_default "本地到服务器 RTT（ms）" "150")
  MEMORY_MIB=$(prompt_default "服务器内存（MiB，0=自动检测）" "0")
  [[ "$MEMORY_MIB" == "0" ]] && MEMORY_MIB=$(detect_memory_mib)
  choose_option PROFILE "使用场景" 1 \
    'streaming|代理、视频与高吞吐（推荐）' \
    'balanced|综合均衡' \
    'latency|游戏与低延迟' \
    'bulk|大文件传输与多连接下载'
  choose_option ROLE "机器角色" 1 \
    'host|VPS、代理服务器或普通主机（推荐）' \
    'router|路由器、网关或转发设备'
  choose_option QDISC_REQUEST "队列算法" 1 \
    'auto|自动按场景选择（推荐）' \
    'fq|FQ：BBR 与单线程吞吐优先' \
    'fq_pie|FQ-PIE：兼顾吞吐、丢包和延迟' \
    'cake|CAKE：整形、公平与抗 bufferbloat'
  choose_option CC_REQUEST "拥塞控制算法" 1 \
    'auto|自动选择 BBR，失败时使用 Cubic（推荐）' \
    'bbr|强制 BBR' \
    'cubic|使用内核 Cubic'
  choose_option SHAPE_REQUEST "出口整形（实测：重传 9万→0、负载抖动 18.9ms→0.8ms，代价是峰值吞吐约 -14%）" 1 \
    'adapt|自适应整形（推荐/默认）：以瓶颈带宽为上限，按实测重传率自动升降速' \
    'auto|固定整形：按瓶颈带宽 min(local,server) 定速，不自动调整' \
    'off|不整形（追求峰值吞吐，但高峰时段丢包/抖动明显）' \
    'custom|自定义固定速率（手动输入 Mbps）'
  if [[ "$SHAPE_REQUEST" == custom ]]; then
    local shape_hint=1000
    if is_uint "$LOCAL_MBPS" && is_uint "$SERVER_MBPS"; then shape_hint=$(min "$LOCAL_MBPS" "$SERVER_MBPS"); fi
    SHAPE_REQUEST=$(prompt_default "整形速率（Mbps）" "$shape_hint")
  fi
  CURVE=$(prompt_default "爬升积极度 0.1-1.0" "0.7")
  IFACE=$(prompt_default "出口网卡（auto=自动）" "auto")
  choose_option TUNE_RPS "多核网络处理 RPS/RFS（仅当前开机有效）" 1 \
    'auto|单 RX 队列且多核时自动开启（推荐，仅立即应用）' \
    'on|强制开启（仅立即应用）' \
    'off|关闭'
  choose_yes_no NIC_TUNE "立即开启 GRO/GSO/TSO 等吞吐型网卡 offload？" yes
  choose_yes_no RESOLVE_CONFLICTS "备份并删除包含冲突参数的整个旧 sysctl 文件？" yes
  if [[ "$QDISC_REQUEST" == cake || ( "$QDISC_REQUEST" == auto && "$ROLE" == router ) ]]; then
    CAKE_RATE_MBPS=$(prompt_default "CAKE 整形速率（Mbps，0=自动计算）" "0")
    [[ "$CAKE_RATE_MBPS" == 0 ]] && CAKE_RATE_MBPS=""
  fi
  validate_inputs
  detect_interface
  calculate
  audit_sysctl_sources
  collect_orphans
  preview_config
  say
  if confirm "写入并立即应用以上配置？"; then
    ACTION=apply
    apply_config
  else
    info "未修改系统"
  fi
}

main_menu() {
  local choice
  say "${C_BOLD}TCP 性能优化工具 v${VERSION}${C_RESET}"
  say "纯 Bash · BBR · FQ/FQ-PIE/CAKE · 自动备份与回滚"
  say
  say "  1) 开始交互式优化"
  say "  2) 查看当前网络状态"
  say "  3) 恢复最近一次备份"
  say "  4) 卸载本工具配置"
  say "  5) 显示命令行帮助"
  say "  0) 退出"
  say
  read -r -p "请选择 [1]: " choice
  choice=${choice:-1}
  case "$choice" in
    1) wizard ;;
    2) status ;;
    3) ACTION=restore; restore_latest ;;
    4) ACTION=uninstall; uninstall_config ;;
    5) usage ;;
    0) info "已退出" ;;
    *) die "无效选项：$choice" ;;
  esac
}

confirm() {
  local prompt=$1 answer
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "非交互执行需明确添加 --yes"
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
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
  bottleneck=$(min "$LOCAL_MBPS" "$SERVER_MBPS")
  BDP_BYTES=$((bottleneck * RTT_MS * 125))

  case "$PROFILE" in
    balanced)  factor=$((220 + CURVE_STEP * 18)); profile_backlog=8 ;;
    streaming) factor=$((280 + CURVE_STEP * 24)); profile_backlog=12 ;;
    latency)   factor=$((180 + CURVE_STEP * 12)); profile_backlog=6 ;;
    bulk)      factor=$((350 + CURVE_STEP * 30)); profile_backlog=18 ;;
  esac

  BUFFER_BYTES=$((BDP_BYTES * factor / 100))
  # ── 内存模型 ──────────────────────────────────────────────
  # 全局 TCP 内存预算 = 内存的 1/8；tcp_mem 三级水位按内核同构关系推导：
  #   low = max/2,  high = max*2/3,  max = 预算
  # 单 socket 上限再收紧到 high 的 1/4。旧版只限了单 socket 却从不设 tcp_mem，
  # 实测出现过 rmem_max 124MiB > 实测 tcp_mem high 116MiB 的矛盾。
  TCP_MEM_MAX_BYTES=$((MEMORY_MIB * 1048576 / 8))
  (( TCP_MEM_MAX_BYTES < 8 * 1048576 )) && TCP_MEM_MAX_BYTES=$((8 * 1048576))
  TCP_MEM_HIGH_BYTES=$((TCP_MEM_MAX_BYTES * 2 / 3))
  TCP_MEM_LOW_BYTES=$((TCP_MEM_MAX_BYTES / 2))
  TCP_MEM_PAGES="$((TCP_MEM_LOW_BYTES / 4096)) $((TCP_MEM_HIGH_BYTES / 4096)) $((TCP_MEM_MAX_BYTES / 4096))"
  mem_cap=$((TCP_MEM_HIGH_BYTES / 4))
  (( mem_cap < 4 * 1048576 )) && mem_cap=$((4 * 1048576))
  BUFFER_BYTES=$(clamp "$BUFFER_BYTES" $((4 * 1048576)) "$mem_cap")
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
  QDISC_MEMORY=$(clamp "$QDISC_MEMORY" $((16 * 1024 * 1024)) $((128 * 1024 * 1024)))
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
      QDISC_ARGS=(fq limit "$FQ_LIMIT" flow_limit "$FQ_FLOW_LIMIT" quantum "$FQ_QUANTUM" initial_quantum "$FQ_INITIAL_QUANTUM" pacing)
      ;;
    fq_pie)
      # flows 无法用 replace 修改（实测报 "Number of flows cannot be changed"），
      # 因此 apply 时先试 replace，失败再 del+add 重建。
      QDISC_ARGS=(fq_pie limit "$FQ_LIMIT" flows "$FQ_PIE_FLOWS" target "${PIE_TARGET_MS}ms" tupdate "${PIE_TARGET_MS}ms" quantum "$MTU" memory_limit "$QDISC_MEMORY" ecn dq_rate_estimator)
      ;;
    cake)
      # CAKE_RATE_KBIT 为空 = 不传 bandwidth = cake 不限速（--shape off 时）
      QDISC_ARGS=(cake)
      if [[ -n "$CAKE_RATE_KBIT" ]]; then
        QDISC_ARGS+=(bandwidth "${CAKE_RATE_KBIT}Kbit")
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
# Profile: ${PROFILE}; climb=${CURVE}; qdisc=${QDISC}; calculated BDP=${BDP_BYTES} bytes

# Queue discipline and congestion control
EOF
  emit_setting net.core.default_qdisc "$QDISC"
  emit_setting net.ipv4.tcp_congestion_control "$CC"
  say
  say "# BDP-aware socket ceilings; TCP receive auto-tuning remains enabled"
  emit_setting net.core.rmem_max "$BUFFER_BYTES"
  emit_setting net.core.wmem_max "$BUFFER_BYTES"
  emit_setting net.ipv4.tcp_rmem "4096 131072 $BUFFER_BYTES"
  emit_setting net.ipv4.tcp_wmem "4096 16384 $BUFFER_BYTES"
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
  if should_enable_rps; then
    emit_setting net.core.rps_sock_flow_entries "$RPS_ENTRIES"
  fi
  say
  say "# Resilience for tunnels, proxies and long-lived connections"
  emit_setting net.ipv4.tcp_mtu_probing 1
  emit_setting net.ipv4.tcp_fastopen 3
  emit_setting net.ipv4.tcp_keepalive_time 600
  emit_setting net.ipv4.tcp_keepalive_intvl 30
  emit_setting net.ipv4.tcp_keepalive_probes 5
  emit_setting net.ipv4.tcp_fin_timeout 30
  if [[ "$PROFILE" == streaming || "$PROFILE" == bulk ]]; then
    emit_setting net.ipv4.tcp_slow_start_after_idle 0
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
  say
  say "${C_BOLD}计算结果${C_RESET}"
  say "  瓶颈带宽 : $(min "$LOCAL_MBPS" "$SERVER_MBPS") Mbps"
  say "  单流 BDP  : $(human_bytes "$BDP_BYTES")"
  say "  缓冲上限  : $(human_bytes "$BUFFER_BYTES")/socket（≤ 全局 high 的 1/4）"
  say "  全局水位  : low $(human_bytes "$TCP_MEM_LOW_BYTES") / high $(human_bytes "$TCP_MEM_HIGH_BYTES") / max $(human_bytes "$TCP_MEM_MAX_BYTES")"
  say "  网卡/队列  : $IFACE（MTU $MTU，RX $RX_QUEUES，TX $TX_QUEUES）"
  say "  CPU/内存   : $CPU_COUNT 核 / ${MEMORY_MIB} MiB"
  say "  拥塞控制   : $CC"
  say "  qdisc      : $QDISC"
  [[ "$QDISC" == fq_pie ]] && say "  FQ-PIE 流表 : $FQ_PIE_FLOWS"
  say "  场景/曲线  : $PROFILE / $CURVE"
  say "  首轮调度量 : $(human_bytes "$FQ_INITIAL_QUANTUM")"
  should_enable_rps && say "  RPS/RFS     : 启用（$RPS_ENTRIES 流）" || say "  RPS/RFS     : 不启用"
  if [[ "$QDISC" != cake ]]; then
    say "  出口整形   : 不适用（当前 qdisc 是 $QDISC，不做整形）"
  elif [[ -n "$CAKE_RATE_KBIT" ]]; then
    say "  CAKE 速率   : $CAKE_RATE_KBIT Kbit/s（实际生效值）"
    say "  出口整形   : 开，$(( CAKE_RATE_KBIT / 1000 )) Mbps → 预期有效吞吐 ≈ ${SHAPE_GOODPUT_MBPS} Mbps"
    say "  整形来源   : ${SHAPE_SOURCE}"
    say "  预期收益   : 重传≈0、负载抖动≈0.8~1.0ms（实测：不整形 18.9ms / 整形 0.8~1.0ms）"
  else
    say "  出口整形   : 关（cake 不传 bandwidth = 不限速；降重传/抖动用 --shape auto）"
  fi
  say
  say "${C_BOLD}当前网卡将执行${C_RESET}"
  print_qdisc_command
  if [[ -n "$CAKE_RATE_KBIT" ]]; then
    if (( SHAPE_CPU_X10 > CPU_COUNT * 5 )); then
      warn "cake 在 $(( CAKE_RATE_KBIT / 1000 )) Mbps 下约需 $((SHAPE_CPU_X10 / 10)).$((SHAPE_CPU_X10 % 10)) 核，超过本机 ${CPU_COUNT} 核的一半，代理自身可能被 CPU 拖慢：可降低 --shape"
    fi
    if (( CAKE_RATE_KBIT >= 1000000 )); then
      warn "CAKE 会消耗更多单核 CPU；追求绝对峰值吞吐可用 --shape off。"
    fi
  fi
  say
  emit_config
}

generated_keys() { emit_config | awk -F= '/^[a-z0-9_.]+[[:space:]]*=/ {gsub(/[[:space:]]/,"",$1); print $1}'; }

# 列出开机真正会加载的 sysctl 文件。
# 实测：systemd-sysctl（systemd 252/257）只读 4 个目录，**不读 /etc/sysctl.conf**，
# 而 procps 的 `sysctl --system` 会读 —— 所以 /etc/sysctl.conf 属于“手动应用才活、
# 重启就丢”的陷阱文件。
applied_sysctl_files() {
  local f
  if [[ -d /run/systemd/system ]] && command -v systemd-sysctl >/dev/null 2>&1 \
     && systemd-sysctl --cat-config >/dev/null 2>&1; then
    systemd-sysctl --cat-config 2>/dev/null | sed -n 's|^# \(/.*\)$|\1|p' | while IFS= read -r f; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  elif [[ -d /run/systemd/system ]]; then
    for f in /usr/lib/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /run/sysctl.d/*.conf /etc/sysctl.d/*.conf; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  else
    for f in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /etc/sysctl.conf; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  fi
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
    for f in "${APPLIED_FILES[@]}"; do [[ "$f" == "$cand" ]] && continue 2; done
    ORPHAN_FILES+=("$cand")
  done
  say "${C_BOLD}生效源审计${C_RESET}"
  say "  开机实际加载 : ${#APPLIED_FILES[@]} 个文件"
  for f in "${APPLIED_FILES[@]}"; do say "    - $f"; done
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
    warn "系统目录（/usr/lib、/run、/usr/local）中有 ${#READONLY_CONFLICTS[@]} 条同类键：本工具文件优先级更高，且不会删除包自带文件"
  fi
}

# 把孤儿文件中“不归本工具管理”的键收集起来（--absorb-orphans）
collect_orphans() {
  ORPHAN_LINES=()
  local srcs=("${CARRY_FILES[@]}")
  ((ABSORB_ORPHANS)) && srcs+=("${ORPHAN_FILES[@]}")
  ((${#srcs[@]})) || return 0
  local f line k keys
  keys="|$(generated_keys | tr '\n' '|')"
  for f in "${srcs[@]}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    while IFS= read -r line; do
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
      ORPHAN_LINES+=("$line"); keys="${keys}${k}|"
    done < "$f"
  done
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
  while IFS= read -r line; do
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

backup_file() {
  local source=$1 backup_dir=$2 destination
  [[ -e "$source" ]] || return 0
  destination="$backup_dir$source"
  mkdir -p "$(dirname "$destination")"
  cp -a "$source" "$destination"
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
      warn "$file 中以下键不归本工具管理，将随文件一起消失（想保留请加 --absorb-orphans）："
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

remember_live_qdisc() {
  local backup_dir=$1 previous
  command -v tc >/dev/null 2>&1 || return 0
  previous=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}')
  printf '%s\n' "$IFACE" > "$backup_dir/qdisc.iface"
  printf '%s\n' "${previous:-unknown}" > "$backup_dir/qdisc.kind"
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

apply_rps() {
  should_enable_rps || return 0
  local mask queue failures=0
  mask=$(cpu_mask)
  for queue in "/sys/class/net/$IFACE/queues"/rx-*; do
    [[ -d "$queue" ]] || continue
    printf '%s' "$mask" > "$queue/rps_cpus" 2>/dev/null || failures=$((failures + 1))
    [[ -w "$queue/rps_flow_cnt" ]] && printf '%s' "$RPS_FLOW_PER_QUEUE" > "$queue/rps_flow_cnt" 2>/dev/null || true
  done
  ((failures == 0)) && ok "已配置 RPS/RFS CPU 并行处理" || warn "部分 RPS 队列不允许修改，已跳过"
}

tune_nic_offloads() {
  ((NIC_TUNE)) || return 0
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
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  ((found)) && ok "已移除旧版本 runtime 和 systemd 服务" || true
}

# 把 qdisc/整形/RPS/offload 落成一个 oneshot 单元，重启后自动重放。
# （sysctl 部分由 systemd-sysctl 读 /etc/sysctl.d 负责，无需在此处理）
install_qdisc_persistence() {
  command -v tc >/dev/null 2>&1 || return 0
  local ethtool_path
  ethtool_path=$(command -v ethtool 2>/dev/null || true)
  build_qdisc_args
  install -d -m 0755 "$(dirname "$QDISC_RUNTIME_FILE")"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Managed by tcp-tune.sh — 重启后重放 qdisc/整形/RPS/offload'
    printf '# 输入：iface=%s qdisc=%s shape=%s\n' "$IFACE" "$QDISC" "${SHAPE_MBPS:-off}"
    printf '%s\n' 'set -u'
    printf 'IFACE=%q\n' "$IFACE"
    printf '%s\n' 'for _i in $(seq 1 30); do [ -d "/sys/class/net/$IFACE" ] && break; sleep 1; done'
    printf '%s\n' '[ -d "/sys/class/net/$IFACE" ] || exit 0'
    printf '%s\n' 'command -v tc >/dev/null 2>&1 || exit 0'
    if [[ "$QDISC" == fq_pie ]]; then
      printf '%s\n' 'tc qdisc del dev "$IFACE" root 2>/dev/null || true'
      printf 'tc qdisc add dev "$IFACE" root %s || true\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
    else
      printf 'tc qdisc replace dev "$IFACE" root %s || true\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
    fi
    if should_enable_rps; then
      printf '%s\n' 'for q in /sys/class/net/"$IFACE"/queues/rx-*; do'
      printf '%s\n' '  [ -d "$q" ] || continue'
      printf '  printf %%s %q > "$q/rps_cpus" 2>/dev/null || true\n' "$(cpu_mask)"
      printf '  printf %%s %q > "$q/rps_flow_cnt" 2>/dev/null || true\n' "$RPS_FLOW_PER_QUEUE"
      printf '%s\n' 'done'
    fi
    if ((NIC_TUNE)) && [[ -n "$ethtool_path" ]]; then
      printf '%q -K "$IFACE" gro on gso on tso on rx on tx on >/dev/null 2>&1 || true\n' "$ethtool_path"
    fi
  } > "$QDISC_RUNTIME_FILE"
  chmod 0755 "$QDISC_RUNTIME_FILE"

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    cat > "$QDISC_SERVICE_FILE" <<EOF
[Unit]
Description=Re-apply tcp-tune qdisc/shaping settings
Documentation=man:tc(8)
Wants=network-online.target
After=network-online.target
ConditionPathExists=$QDISC_RUNTIME_FILE

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_RUNTIME_FILE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable "$QDISC_SERVICE_NAME" >/dev/null 2>&1; then
      ok "已安装开机重放单元 $QDISC_SERVICE_NAME（qdisc/整形/RPS/offload 重启后保留）"
    else
      warn "systemctl enable 失败；qdisc 参数重启后会丢失"
    fi
  else
    warn "未检测到 systemd；qdisc/整形参数仅当前生效，重启后只保留 sysctl 部分"
  fi
}

# 自适应整形：装一个 systemd timer + 控制器脚本，每 30 秒按实测重传率升降
# cake 的 bandwidth，跟踪随时段变化的路径干净容量。ADAPT=0 时顺手清理已装单元。
install_adaptive_shaping() {
  if (( ADAPT == 0 )); then
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      systemctl disable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE"
    return 0
  fi
  command -v tc >/dev/null 2>&1 || return 0
  [[ -n "$CAKE_RATE_KBIT" ]] || { warn "自适应整形需要 cake 速率；已跳过"; ADAPT=0; return 0; }
  install -d -m 0755 "$(dirname "$ADAPT_RUNTIME_FILE")" "$ADAPT_STATE_DIR"

  cat > "$ADAPT_RUNTIME_FILE" <<'ADAPT_EOF'
#!/bin/bash
# Managed by tcp-tune.sh — 自适应整形控制器
# 由 tcp-tune-adapt.timer 周期调用：按实测重传率升降 cake 的 bandwidth，
# 跟踪随时段变化的路径干净容量（晚高峰自动降速保干净、平峰自动升回上限）
set -u
STATE=/var/lib/tcp-tune/adapt.state
[ -r "$STATE" ] || exit 0
. "$STATE"
command -v tc >/dev/null 2>&1 || exit 0
[ -d "/sys/class/net/$IFACE" ] || exit 0

# 只在自家挂的 cake 上动作，避免与运维手工改动打架
cur_q=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}')
[ "$cur_q" = cake ] || { echo "当前 qdisc 是 $cur_q，非 cake，跳过"; exit 0; }

read -r out retr < <(nstat -az 2>/dev/null | awk '
  /^TcpOutSegs/{o=$2} /^TcpRetransSegs/{r=$2} END{print o+0, r+0}')
[ -n "${out:-}" ] || exit 0
now=$(date +%s)

# 首次运行 / 计数器回绕 / 重启：只记基线
if (( LAST_OUT == 0 )) || (( out < LAST_OUT )) || (( retr < LAST_RETR )); then
  sed -i "s/^LAST_OUT=.*/LAST_OUT=$out/; s/^LAST_RETR=.*/LAST_RETR=$retr/; s/^LAST_TS=.*/LAST_TS=$now/" "$STATE"
  echo "基线建立：out=$out retr=$retr"
  exit 0
fi
d_out=$(( out - LAST_OUT )); d_retr=$(( retr - LAST_RETR )); d_sec=$(( now - LAST_TS ))
sed -i "s/^LAST_OUT=.*/LAST_OUT=$out/; s/^LAST_RETR=.*/LAST_RETR=$retr/; s/^LAST_TS=.*/LAST_TS=$now/" "$STATE"

if (( d_out < 2000 )); then
  echo "样本不足（${d_sec}s 内 ${d_out} 段），保持 ${CUR_KBIT} Kbit"
  exit 0
fi

ratio_ppm=$(( d_retr * 1000000 / d_out ))
old=$CUR_KBIT
if (( ratio_ppm > 10000 )); then
  CUR_KBIT=$(( CUR_KBIT * 85 / 100 )); OK_COUNT=0
elif (( ratio_ppm < 1000 )); then
  OK_COUNT=$(( OK_COUNT + 1 ))
  if (( OK_COUNT >= 3 )); then
    CUR_KBIT=$(( CUR_KBIT * 105 / 100 )); OK_COUNT=0
  fi
else
  OK_COUNT=0
fi
(( CUR_KBIT > CEIL_KBIT )) && CUR_KBIT=$CEIL_KBIT
(( CUR_KBIT < FLOOR_KBIT )) && CUR_KBIT=$FLOOR_KBIT

if (( CUR_KBIT != old )); then
  new_args=(); skip=0
  for a in "${ARGS[@]}"; do
    if (( skip )); then new_args+=("${CUR_KBIT}Kbit"); skip=0; continue; fi
    [ "$a" = bandwidth ] && skip=1
    new_args+=("$a")
  done
  if tc qdisc replace dev "$IFACE" root "${new_args[@]}"; then
    awk -v o="$old" -v n="$CUR_KBIT" -v r="$d_retr" -v t="$d_out" -v s="$d_sec" \
      'BEGIN{printf "整形 %d -> %d Kbit（%d s 内重传 %d/%d = %.3f%%）\n", o, n, s, r, t, r*100/t}'
  else
    echo "tc 调整失败，保持 $old Kbit"; CUR_KBIT=$old
  fi
fi
sed -i "s/^CUR_KBIT=.*/CUR_KBIT=$CUR_KBIT/; s/^OK_COUNT=.*/OK_COUNT=$OK_COUNT/" "$STATE"
ADAPT_EOF
  chmod 0755 "$ADAPT_RUNTIME_FILE"

  {
    printf 'IFACE=%q\n' "$IFACE"
    printf 'CEIL_KBIT=%s\n' "$CAKE_RATE_KBIT"
    printf 'FLOOR_KBIT=%s\n' "$(clamp "$(( CAKE_RATE_KBIT / 5 ))" 50000 100000000)"
    printf 'CUR_KBIT=%s\n' "$CAKE_RATE_KBIT"
    printf 'OK_COUNT=0\nLAST_OUT=0\nLAST_RETR=0\nLAST_TS=0\n'
    printf 'ARGS=(%s)\n' "$(printf '%q ' "${QDISC_ARGS[@]}")"
  } > "$ADAPT_STATE_FILE"
  chmod 0644 "$ADAPT_STATE_FILE"

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
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
      ok "已启用自适应整形：$ADAPT_TIMER_NAME（每 30s 调，上限 $((CAKE_RATE_KBIT/1000)) Mbps，下限 $((CAKE_RATE_KBIT/5000)) Mbps）"
    else
      warn "自适应整形单元启用失败；整形仍按固定速率运行"
    fi
  else
    warn "自适应整形需要 systemd；已跳过（整形仍按固定速率运行）"
  fi
}

apply_config() {
  require_root
  command -v sysctl >/dev/null 2>&1 || die "缺少 sysctl（通常由 procps/procps-ng 提供）"
  command -v tc >/dev/null 2>&1 || die "缺少 tc；请安装 iproute2"

  detect_interface
  calculate
  load_network_modules
  select_congestion_control
  calculate
  adapt_netdev_budget_usecs
  find_conflicts

  local timestamp backup_dir tmp
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="$BACKUP_ROOT/$timestamp"
  mkdir -p "$backup_dir"
  backup_file "$CONFIG_FILE" "$backup_dir"
  backup_file "$MODULE_FILE" "$backup_dir"
  backup_file "$LEGACY_RUNTIME_FILE" "$backup_dir"
  backup_file "$LEGACY_SERVICE_FILE" "$backup_dir"
  backup_file "$QDISC_RUNTIME_FILE" "$backup_dir"
  backup_file "$QDISC_SERVICE_FILE" "$backup_dir"
  backup_file "$ADAPT_RUNTIME_FILE" "$backup_dir"
  backup_file "$ADAPT_SERVICE_FILE" "$backup_dir"
  backup_file "$ADAPT_TIMER_FILE" "$backup_dir"
  remember_live_qdisc "$backup_dir"

  if ((${#CONFLICTS[@]})); then
    warn "发现 ${#CONFLICTS[@]} 条旧配置与本工具重复："
    printf '  %s\n' "${CONFLICTS[@]}" >&2
    if ((RESOLVE_CONFLICTS)); then
      remove_conflict_files "$backup_dir"
    else
      warn "暂不改动旧文件；若 /etc/sysctl.conf 中存在重复项，它可能覆盖本配置。"
      warn "可重新执行并添加 --resolve-conflicts。"
    fi
  fi

  tmp=$(mktemp)
  emit_config > "$tmp"
  install -D -m 0644 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
  install -d -m 0755 "$(dirname "$MODULE_FILE")"
  : > "$MODULE_FILE"
  if [[ "$CC" == bbr ]]; then
    printf '%s\n' tcp_bbr > "$MODULE_FILE"
  fi
  printf '%s\n' "sch_$QDISC" >> "$MODULE_FILE"

  if ! sysctl -p "$CONFIG_FILE"; then
    warn "应用失败，正在恢复本次修改前的配置"
    restore_from "$backup_dir"
    die "内核拒绝了部分参数；系统已回滚"
  fi
  if ! apply_live_qdisc; then
    # 可用性兜底：默认的 --shape auto 依赖 cake。若本机内核没有 cake
    # （老内核 / OpenVZ / 精简系统），不要整体失败，而是自动降级为不整形，
    # 并**重写已落盘的配置**，避免 default_qdisc=cake 在重启后失效。
    if [[ "$QDISC" == cake ]]; then
      warn "cake 无法挂载（内核可能没有 sch_cake），自动降级为不整形并重写配置"
      SHAPE_KBIT=""; SHAPE_MBPS=""; SHAPE_GOODPUT_MBPS=0; SHAPE_CPU_X10=0
      QDISC_REQUEST=auto
      select_qdisc
      build_qdisc_args
      tmp=$(mktemp)
      emit_config > "$tmp"
      install -D -m 0644 "$tmp" "$CONFIG_FILE"
      rm -f "$tmp"
      sysctl -p "$CONFIG_FILE" >/dev/null 2>&1 || true
      if ! apply_live_qdisc; then
        restore_from "$backup_dir"
        die "降级后的 qdisc 仍无法挂载；系统已回滚"
      fi
      warn "已降级运行（qdisc=$QDISC，无整形）；如需要整形请先让内核支持 sch_cake 后重新 apply"
    else
      restore_from "$backup_dir"
      die "qdisc 应用失败；系统已回滚"
    fi
  fi
  apply_rps
  tune_nic_offloads
  remove_legacy_runtime
  install_qdisc_persistence
  install_adaptive_shaping
  printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/latest"
  ok "配置已应用：$CONFIG_FILE"
  info "当前算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)；网卡上实际 qdisc：$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 || true)"
}

restore_from() {
  local backup_dir=$1 path old_iface old_kind
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$QDISC_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true
  fi
  for path in "$CONFIG_FILE" "$MODULE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE" "$QDISC_RUNTIME_FILE" "$QDISC_SERVICE_FILE" "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE"; do
    if [[ -e "$backup_dir$path" ]]; then
      cp -a "$backup_dir$path" "$path"
    else
      rm -f "$path"
    fi
  done
  if [[ -d "$backup_dir/etc" ]]; then
    while IFS= read -r -d '' path; do
      [[ "$path" == "$backup_dir$CONFIG_FILE" || "$path" == "$backup_dir$MODULE_FILE" ]] && continue
      cp -a "$path" "${path#"$backup_dir"}"
    done < <(find "$backup_dir/etc" -type f -print0)
  fi
  if [[ -r "$backup_dir/qdisc.iface" && -r "$backup_dir/qdisc.kind" ]] && command -v tc >/dev/null 2>&1; then
    old_iface=$(<"$backup_dir/qdisc.iface")
    old_kind=$(<"$backup_dir/qdisc.kind")
    if [[ -d "/sys/class/net/$old_iface" ]]; then
      if [[ "$old_kind" == noqueue || "$old_kind" == unknown ]]; then
        tc qdisc del dev "$old_iface" root 2>/dev/null || true
      else
        tc qdisc replace dev "$old_iface" root "$old_kind" 2>/dev/null || true
      fi
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  sysctl --system >/dev/null || true
}

restore_latest() {
  require_root
  [[ -r "$BACKUP_ROOT/latest" ]] || die "没有可恢复的备份记录"
  local backup_dir
  backup_dir=$(<"$BACKUP_ROOT/latest")
  [[ -d "$backup_dir" && "$backup_dir" == "$BACKUP_ROOT"/* ]] || die "备份记录无效"
  confirm "恢复备份 $backup_dir？" || { info "已取消"; return; }
  restore_from "$backup_dir"
  ok "已恢复：$backup_dir"
}

uninstall_config() {
  require_root
  [[ -e "$CONFIG_FILE" || -e "$MODULE_FILE" || -e "$LEGACY_RUNTIME_FILE" || -e "$LEGACY_SERVICE_FILE" || -e "$QDISC_RUNTIME_FILE" || -e "$QDISC_SERVICE_FILE" || -e "$ADAPT_RUNTIME_FILE" || -e "$ADAPT_SERVICE_FILE" || -e "$ADAPT_TIMER_FILE" ]] || { info "未发现本工具配置"; return; }
  confirm "删除本工具生成的配置？旧的冲突配置不会自动恢复。" || { info "已取消"; return; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now tcp-tune-runtime.service >/dev/null 2>&1 || true
    systemctl disable --now "$QDISC_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable --now "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$CONFIG_FILE" "$MODULE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE" "$QDISC_RUNTIME_FILE" "$QDISC_SERVICE_FILE" "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  sysctl --system >/dev/null || true
  ok "已删除本工具配置；备份仍保留在 $BACKUP_ROOT"
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

  local status_iface=""
  command -v ip >/dev/null 2>&1 && status_iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  if [[ -n "$status_iface" ]] && command -v tc >/dev/null 2>&1; then
    local qline qstat
    qline=$(tc qdisc show dev "$status_iface" 2>/dev/null | awk '$0 ~ / root / {print; exit}')
    printf '  %-18s %s\n' "实际 qdisc" "$qline"
    if [[ "$qline" == *cake* ]]; then
      [[ "$qline" == *bandwidth* ]] && ok "整形已生效（cake bandwidth）" || warn "cake 未设 bandwidth = 实际没有整形"
    fi
    qstat=$(tc -s qdisc show dev "$status_iface" 2>/dev/null | grep -m1 'dropped')
    [[ -n "$qstat" ]] && printf '  %-18s %s\n' "qdisc 丢/超限" "$(sed -n 's/.*(dropped \([0-9]*\), overlimits \([0-9]*\).*/\1 \/ \2/p' <<<"$qstat")"
  fi

  if command -v nstat >/dev/null 2>&1; then
    local out ret lr tmo ofo
    # 注意：脚本顶部 IFS 不含空格，这里必须显式指定按空格拆字段
    IFS=' ' read -r out ret lr tmo ofo < <(nstat -az 2>/dev/null | awk '
      /^TcpOutSegs/{o=$2} /^TcpRetransSegs/{r=$2} /^TcpExtTCPLostRetransmit/{l=$2}
      /^TcpExtTCPTimeouts/{t=$2} /^TcpExtTCPOFOQueue/{f=$2}
      END{print o+0, r+0, l+0, t+0, f+0}')
    if (( ${out:-0} > 0 )); then
      printf '  %-18s %s\n' "重传率(累计)" "$(awk -v r="$ret" -v o="$out" 'BEGIN{ printf "%.3f%%  (%d/%d)", r*100/o, r, o }')"
      printf '  %-18s %s\n' "重传又丢/超时" "$lr / $tmo"
      printf '  %-18s %s\n' "乱序入队" "$ofo"
    fi
  fi

  local ccmax cccur
  ccmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
  cccur=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || true)
  if [[ -n "$ccmax" && -n "$cccur" && "$ccmax" -gt 0 ]]; then
    printf '  %-18s %s\n' "conntrack" "$cccur / $ccmax ($(( cccur * 100 / ccmax ))%)"
    (( cccur * 100 / ccmax > 80 )) && warn "conntrack 已用超 80%：高峰可能丢包或建连失败" || true
  fi

  if command -v ss >/dev/null 2>&1; then
    local tot small
    tot=$(ss -tin state established 2>/dev/null | grep -c 'mss:' || true)
    small=$(ss -tin state established 2>/dev/null | grep -o 'mss:[0-9]*' | awk -F: '$2 < 1200' | wc -l || true)
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
  napp=$(applied_sysctl_files 2>/dev/null | wc -l); norph=0
  for cand in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [[ -f "$cand" ]] || continue
    for f in $(applied_sysctl_files 2>/dev/null); do [[ "$f" == "$cand" ]] && continue 2; done
    norph=$(( norph + 1 ))
  done
  printf '  %-18s %s\n' "开机生效文件" "$napp 个（另有 $norph 个不生效）"
  (( norph > 0 )) && warn "有 $norph 个 sysctl 文件不会开机生效，重启后其中的设置会丢失" || true

  if [[ -f "$ADAPT_TIMER_FILE" ]]; then
    local a_rate a_ceil
    a_rate=$(sed -n 's/^CUR_KBIT=\([0-9]*\)/\1/p' "$ADAPT_STATE_FILE" 2>/dev/null); a_rate=${a_rate:-0}
    a_ceil=$(sed -n 's/^CEIL_KBIT=\([0-9]*\)/\1/p' "$ADAPT_STATE_FILE" 2>/dev/null); a_ceil=${a_ceil:-0}
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
  parse_args "$@"
  require_linux
  [[ -n "$MEMORY_MIB" ]] || MEMORY_MIB=$(detect_memory_mib)
  case "$ACTION" in
    wizard) wizard ;;
    preview|apply)
      [[ -n "$LOCAL_MBPS" && -n "$SERVER_MBPS" && -n "$RTT_MS" ]] || die "preview/apply 需要带宽与 RTT 参数；或使用 wizard"
      validate_inputs; detect_interface; calculate
      audit_sysctl_sources; collect_orphans
      [[ "$ACTION" == preview ]] && preview_config || { preview_config; confirm "确认应用？" && apply_config || info "已取消"; }
      ;;
    status) status ;;
    restore) restore_latest ;;
    uninstall) uninstall_config ;;
    "") [[ -t 0 ]] && main_menu || usage ;;
    help|-h|--help) usage ;;
    *) die "未知操作：$ACTION（使用 --help 查看帮助）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
