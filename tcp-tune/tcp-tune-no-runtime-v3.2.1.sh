#!/usr/bin/env bash
# tcp-tune.sh - throughput-oriented Linux TCP/qdisc tuning assistant
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.2.1"
CONFIG_FILE="/etc/sysctl.d/99-tcp-tune.conf"
MODULE_FILE="/etc/modules-load.d/99-tcp-tune.conf"
LEGACY_RUNTIME_FILE="/usr/local/libexec/tcp-tune-runtime"
LEGACY_SERVICE_FILE="/etc/systemd/system/tcp-tune-runtime.service"
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
ASSUME_YES=0
RESOLVE_CONFLICTS=0
NO_COLOR=0

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
  --rps MODE            auto | on | off
  --nic-tune            尝试开启 GRO/GSO/TSO 等吞吐型 offload
  --resolve-conflicts   备份并删除包含冲突参数的整个旧配置文件
  --yes                 跳过确认
  --no-color            禁用颜色
  -h, --help            显示帮助

示例：
  sudo bash tcp-tune.sh apply --local-mbps 1000 --server-mbps 500 \
    --rtt-ms 180 --profile streaming --qdisc fq --curve 0.8
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
clamp() { local n=$1 lo=$2 hi=$3; ((n < lo)) && n=$lo; ((n > hi)) && n=$hi; printf '%s' "$n"; }
min() { (( $1 < $2 )) && printf '%s' "$1" || printf '%s' "$2"; }

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
      --rps)             [[ $# -ge 2 ]] || die "$1 缺少模式"; TUNE_RPS=$2; shift 2 ;;
      --nic-tune)        NIC_TUNE=1; shift ;;
      --resolve-conflicts) RESOLVE_CONFLICTS=1; shift ;;
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
  [[ -z "$CAKE_RATE_MBPS" ]] || is_uint "$CAKE_RATE_MBPS" || die "cake-rate-mbps 必须是正整数"
  [[ "$IFACE" == auto || "$IFACE" =~ ^[a-zA-Z0-9_.:@-]+$ ]] || die "网卡名称含有非法字符"
}

normalize_curve() {
  case "$CURVE" in
    0.[1-9]) CURVE_STEP=${CURVE#0.} ;;
    1.0|1)   CURVE_STEP=10; CURVE="1.0" ;;
    [1-9])   CURVE_STEP=$CURVE; CURVE="0.$CURVE" ;;
    10)      CURVE_STEP=10; CURVE="1.0" ;;
    *) die "curve 必须是 0.1-1.0（也兼容旧写法 1-10）" ;;
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
  say "直接按回车即可采用推荐值；带宽请填写长期可用值而不是瞬时峰值。"
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
  if [[ "$QDISC_REQUEST" != auto ]]; then
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
  local bottleneck factor mem_cap hard_cap profile_backlog
  bottleneck=$(min "$LOCAL_MBPS" "$SERVER_MBPS")
  BDP_BYTES=$((bottleneck * RTT_MS * 125))

  case "$PROFILE" in
    balanced)  factor=$((220 + CURVE_STEP * 18)); profile_backlog=8 ;;
    streaming) factor=$((280 + CURVE_STEP * 24)); profile_backlog=12 ;;
    latency)   factor=$((180 + CURVE_STEP * 12)); profile_backlog=6 ;;
    bulk)      factor=$((350 + CURVE_STEP * 30)); profile_backlog=18 ;;
  esac

  BUFFER_BYTES=$((BDP_BYTES * factor / 100))
  mem_cap=$((MEMORY_MIB * 1024 * 1024 / 8))
  hard_cap=$((1024 * 1024 * 1024))
  ((mem_cap > hard_cap)) && mem_cap=$hard_cap
  ((mem_cap < 4 * 1024 * 1024)) && mem_cap=$((4 * 1024 * 1024))
  BUFFER_BYTES=$(clamp "$BUFFER_BYTES" $((4 * 1024 * 1024)) "$mem_cap")

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
  PIE_TARGET_MS=$(clamp "$((RTT_MS * (5 + CURVE_STEP) / 100))" 5 30)
  QDISC_MEMORY=$((BUFFER_BYTES / 2))
  QDISC_MEMORY=$(clamp "$QDISC_MEMORY" $((16 * 1024 * 1024)) $((128 * 1024 * 1024)))
  if [[ -n "$CAKE_RATE_MBPS" ]]; then
    CAKE_RATE_KBIT=$((CAKE_RATE_MBPS * 1000))
  else
    CAKE_RATE_KBIT=$((bottleneck * (940 + CURVE_STEP * 6)))
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
      # "flows" is intentionally omitted: the kernel only accepts it when a
      # new FQ-PIE instance is created, not when an existing one is replaced.
      QDISC_ARGS=(fq_pie limit "$FQ_LIMIT" target "${PIE_TARGET_MS}ms" tupdate "${PIE_TARGET_MS}ms" quantum "$MTU" memory_limit "$QDISC_MEMORY" ecn dq_rate_estimator)
      ;;
    cake)
      QDISC_ARGS=(cake bandwidth "${CAKE_RATE_KBIT}Kbit" besteffort flows nonat nowash no-ack-filter rtt "${RTT_MS}ms")
      if ((CAKE_RATE_KBIT >= 10000000)); then QDISC_ARGS+=(no-split-gso); fi
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
  say "  缓冲上限  : $(human_bytes "$BUFFER_BYTES")（受内存上限保护）"
  say "  网卡/队列  : $IFACE（MTU $MTU，RX $RX_QUEUES，TX $TX_QUEUES）"
  say "  CPU/内存   : $CPU_COUNT 核 / ${MEMORY_MIB} MiB"
  say "  拥塞控制   : $CC"
  say "  qdisc      : $QDISC"
  say "  场景/曲线  : $PROFILE / $CURVE"
  say "  首轮调度量 : $(human_bytes "$FQ_INITIAL_QUANTUM")"
  should_enable_rps && say "  RPS/RFS     : 启用（$RPS_ENTRIES 流）" || say "  RPS/RFS     : 不启用"
  [[ "$QDISC" == cake ]] && say "  CAKE 速率   : $CAKE_RATE_KBIT Kbit/s"
  say
  say "${C_BOLD}当前网卡将执行${C_RESET}"
  print_qdisc_command
  [[ "$QDISC" == cake && "$CAKE_RATE_KBIT" -ge 1000000 ]] && warn "CAKE 会消耗更多单核 CPU；高速 VPS 追求绝对吞吐通常优先 fq。"
  say
  emit_config
}

generated_keys() { emit_config | awk -F= '/^[a-z0-9_.]+[[:space:]]*=/ {gsub(/[[:space:]]/,"",$1); print $1}'; }

find_conflicts() {
  local key file line
  CONFLICTS=()
  while IFS= read -r key; do
    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
      [[ -f "$file" && "$file" != "$CONFIG_FILE" ]] || continue
      while IFS= read -r line; do
        [[ -n "$line" ]] && CONFLICTS+=("$file:$line")
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
  local backup_dir=$1 entry file deleted_count
  declare -A touched=()
  for entry in "${CONFLICTS[@]}"; do touched["${entry%%:*}"]=1; done
  deleted_count=${#touched[@]}
  for file in "${!touched[@]}"; do
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
  if ! tc qdisc replace dev "$IFACE" root "${QDISC_ARGS[@]}"; then
    warn "qdisc $QDISC 无法挂载；可能是内核不支持或参数与当前版本不兼容"
    return 1
  fi
  ok "已将 $QDISC 实际挂载到 $IFACE"
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
    restore_from "$backup_dir"
    die "qdisc 应用失败；系统已回滚"
  fi
  apply_rps
  tune_nic_offloads
  remove_legacy_runtime
  printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/latest"
  ok "配置已应用：$CONFIG_FILE"
  info "当前算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)，qdisc：$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  info "无 runtime 模式：sysctl 与模块配置持久化；qdisc 高级参数、RPS 和 offload 仅立即应用"
}

restore_from() {
  local backup_dir=$1 path old_iface old_kind
  for path in "$CONFIG_FILE" "$MODULE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE"; do
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
  [[ -e "$CONFIG_FILE" || -e "$MODULE_FILE" || -e "$LEGACY_RUNTIME_FILE" || -e "$LEGACY_SERVICE_FILE" ]] || { info "未发现本工具配置"; return; }
  confirm "删除本工具生成的配置？旧的冲突配置不会自动恢复。" || { info "已取消"; return; }
  if command -v systemctl >/dev/null 2>&1; then systemctl disable --now tcp-tune-runtime.service >/dev/null 2>&1 || true; fi
  rm -f "$CONFIG_FILE" "$MODULE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE"
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
  if command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1; then
    local status_iface
    status_iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$status_iface" ]] && printf '  %-18s %s\n' "实际 qdisc" "$(tc qdisc show dev "$status_iface" 2>/dev/null | awk '$0 ~ / root / {print; exit}')"
  fi
  [[ -f "$CONFIG_FILE" ]] && ok "已安装 $CONFIG_FILE" || info "尚未安装本工具配置"
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
