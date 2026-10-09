#!/usr/bin/env bash
# TCP Tune v3.4.0 - 通用代理服务器 TCP / qdisc 调优
# Derived from https://github.com/poiiwe/shells/blob/main/tcp-tune/tcp-tune_v3.3.0.sh
# License: MIT (same as upstream).
#
# 3.4.0: 默认 FQ / 不整形；能力检测；保留 mq；最小 sysctl 修改；事务备份。
# 不安装或更换内核。BBR 的名称不用于推断 BBR 版本。提速需同端点 A/B 验证。
# 自适应整形为实验性显式选项：需要实际 RTT 目标，满载 + RTT 膨胀 + 连续
# 重传样本才降速；全局 TCP 统计仍不能精确归因到某个客户端或容器。

set -Eeuo pipefail
IFS=$'\n\t'
VERSION=3.4.0
CONFIG_FILE=/etc/sysctl.d/99-tcp-tune.conf
MODULE_FILE=/etc/modules-load.d/99-tcp-tune.conf
ENGINE_FILE=/usr/local/libexec/tcp-tune-engine
QDISC_RUNTIME_FILE=/usr/local/libexec/tcp-tune-qdisc
QDISC_SERVICE_NAME=tcp-tune-qdisc.service
ADAPT_SERVICE_NAME=tcp-tune-adapt.service
ADAPT_TIMER_NAME=tcp-tune-adapt.timer
QDISC_SERVICE_FILE=/etc/systemd/system/$QDISC_SERVICE_NAME
ADAPT_SERVICE_FILE=/etc/systemd/system/$ADAPT_SERVICE_NAME
ADAPT_TIMER_FILE=/etc/systemd/system/$ADAPT_TIMER_NAME
ADAPT_RUNTIME_FILE=/usr/local/libexec/tcp-tune-adapt
LEGACY_RUNTIME_FILE=/usr/local/libexec/tcp-tune-runtime
LEGACY_SERVICE_FILE=/etc/systemd/system/tcp-tune-runtime.service
STATE_DIR=/var/lib/tcp-tune
PLAN_FILE=$STATE_DIR/plan
ADAPT_STATE_FILE=$STATE_DIR/adapt.state
BACKUP_ROOT=/var/backups/tcp-tune
PROC_ROOT=/proc
SYS_ROOT=/sys
CGROUP_ROOT=/sys/fs/cgroup
ACTION='' LOCAL_MBPS='' SERVER_MBPS='' RTT_MS='' RTT_HOST='' MEMORY_MIB=''
PROFILE=streaming QDISC_REQUEST=auto QDISC='' CC_REQUEST=auto CC='' ROLE=host
IFACE=auto TUNE_RPS=keep NIC_TUNE=0 SHAPE_REQUEST=off CAKE_RATE_MBPS=
ADAPT=0 CAKE_RATE_KBIT='' SHAPE_MBPS='' CURVE='' CURVE_SEEN=0
BUFFER_MAX_MIB='' NETDEV_BACKLOG='' NETDEV_BUDGET='' NETDEV_BUDGET_USECS=''
TCP_OUTPUT_BYTES='' TCP_MEM_REQUEST='' FQ_PIE_FLOWS_REQUEST=auto
ASSUME_YES=0 RESOLVE_CONFLICTS=0 ABSORB_ORPHANS=0 VERBOSE=0
TXN_ACTIVE=0 TXN_DIR='' KEEP_MQ=0 IFACE_MAC='' RPS_MASK=''
PERSISTENCE_AVAILABLE=0 CC_EXPLICIT=0
QDISC_ARGS=() MQ_PARENTS=() CONFLICT_FILES=() CARRY_LINES=() SYSCTL_KEYS=()
SELF_PATH=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")

say() { printf '%s\n' "$*"; }
info() { printf 'ℹ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
is_uint() { [[ ${1:-} =~ ^[0-9]{1,12}$ ]] && ((10#$1 > 0)); }
norm_uint() { printf '%s' "$((10#$1))"; }
clamp() { local n=$1 lo=$2 hi=$3; ((lo <= hi)) || return 1; ((n < lo)) && n=$lo; ((n > hi)) && n=$hi; printf '%s' "$n"; }
min() { if (($1 < $2)); then printf '%s' "$1"; else printf '%s' "$2"; fi; }
human_bytes() { awk -v n="$1" 'BEGIN {printf "%.2f MiB", n/1048576}'; }
require_root() { ((EUID == 0)) || die "需要 root：sudo bash $0 $ACTION ..."; }
has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
try_module() {
  if command -v modprobe >/dev/null 2>&1; then modprobe "$1" 2>/dev/null || true; fi
}
confirm() {
  local answer
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "非交互应用需显式添加 --yes"
  read -r -p "$1 [y/N]: " answer
  [[ $answer =~ ^[Yy]$ ]]
}

usage() {
  cat <<'EOF'
TCP Tune v3.4.0 — 默认 FQ + 可用的 BBR，不整形，不更换内核

用法：
  sudo bash tcp-tune_v3.4.0.sh                # 交互向导
  bash tcp-tune_v3.4.0.sh preview [参数]       # 只读，不加载模块/写参数
  sudo bash tcp-tune_v3.4.0.sh apply [参数]
  bash tcp-tune_v3.4.0.sh status
  bash tcp-tune_v3.4.0.sh rtt --rtt-host IP或域名
  sudo bash tcp-tune_v3.4.0.sh restore        # 恢复上次修改前的状态
  sudo bash tcp-tune_v3.4.0.sh uninstall      # 恢复首次使用本版本前的状态

链路参数（preview/apply 必填，硬件资源自动检测）：
  --local-mbps N         当前测试方向的本地有效带宽，Mbps
  --server-mbps N        当前测试方向的服务器有效带宽，Mbps
  --rtt-ms N             实际业务路径 RTT，ms
  --rtt-host HOST        测量指定客户端/业务目标 RTT；不要填无关测速地址

策略：
  --profile NAME        streaming | balanced | latency | bulk
  --qdisc NAME          auto | fq | fq_codel | fq_pie | cake
                        host 默认 fq，router 默认 fq_codel；无整形时保留 mq
  --cc NAME             auto | bbr | cubic | keep
                        auto 尝试 BBR，不可用则保留当前算法；显式 bbr 不支持则报错
  --shape MODE          off（默认）| auto | N(Mbps) | adapt（实验）
                        auto 按 min(local,server) 固定整形；不会按 CPU 核数限速
                        adapt 需 --rtt-host，连续满载/RTT 膨胀/重传才降低速率
  --cake-rate-mbps N    显式 CAKE 总出口速率，与 --shape 只选一个
  --interface NAME      默认路由网卡；多出口/策略路由请显式指定
  --role NAME           host（默认）| router
  --memory-mib N        可用内存预算，仅可收紧自动检测到的内存上限
  --buffer-max-mib N    socket 最大值上限，仅可收紧自动计算值
  --rps MODE            keep（默认）| auto | on | off
                        keep 保留原值；auto 仅在单 RX 队列且多核时设置
  --nic-tune            显式尝试开启 GRO/GSO/TSO；默认保留 offload 原值
  --fq-pie-flows N      auto（保留算法默认值）或 256-65536

高级选项（默认均保留内核当前值）：
  --netdev-backlog N       --netdev-budget N
  --netdev-budget-usecs N  --tcp-output-bytes N
  --tcp-mem 'min pressure max'    单位为内核页；实际页大小自动检测

配置与输出：
  --resolve-conflicts   备份并注释重复的键，保留文件中的其他内容
  --absorb-orphans      合并未被开机加载的 /etc/sysctl.conf 中非托管键
  --curve N             兼容旧命令；仅提示，不再通过“积极度”修改内核预算
  --yes                 非交互确认
  --verbose             显示具体参数与队列计划
  --no-color            兼容选项，输出本来就不使用 ANSI 颜色

示例（带宽/RTT 数字需替换为实际值）：
  bash tcp-tune_v3.4.0.sh preview --local-mbps 1000 --server-mbps 1000 --rtt-ms 50 --verbose
  sudo bash tcp-tune_v3.4.0.sh apply --local-mbps 1000 --server-mbps 1000 --rtt-ms 50

旧版升级：本版不再管理的旧 sysctl 从本工具配置中移除；已生效的旧值
无法凭空推断为内核默认值，重启后由内核和其他配置重新初始化。
Docker 桥接容器的拥塞控制需在容器内检查；本工具只作用于当前网络命名空间。
EOF
}

parse_args() {
  ACTION=${1:-}; (($# == 0)) || shift
  while (($#)); do
    case $1 in
      --local-mbps|--server-mbps|--rtt-ms|--rtt-host|--memory-mib|--profile|--qdisc|--cc|--role|--interface|--rps|--shape|--cake-rate-mbps|--buffer-max-mib|--netdev-backlog|--netdev-budget|--netdev-budget-usecs|--tcp-output-bytes|--tcp-mem|--fq-pie-flows|--curve)
        (($# >= 2)) || die "$1 缺少参数"
        case $1 in
          --local-mbps) LOCAL_MBPS=$2;; --server-mbps) SERVER_MBPS=$2;;
          --rtt-ms) RTT_MS=$2;; --rtt-host) RTT_HOST=$2;; --memory-mib) MEMORY_MIB=$2;;
          --profile) PROFILE=$2;; --qdisc) QDISC_REQUEST=$2;; --cc) CC_REQUEST=$2;;
          --role) ROLE=$2;; --interface) IFACE=$2;; --rps) TUNE_RPS=$2;;
          --shape) SHAPE_REQUEST=$2;; --cake-rate-mbps) CAKE_RATE_MBPS=$2;;
          --buffer-max-mib) BUFFER_MAX_MIB=$2;; --netdev-backlog) NETDEV_BACKLOG=$2;;
          --netdev-budget) NETDEV_BUDGET=$2;; --netdev-budget-usecs) NETDEV_BUDGET_USECS=$2;;
          --tcp-output-bytes) TCP_OUTPUT_BYTES=$2;; --tcp-mem) TCP_MEM_REQUEST=$2;;
          --fq-pie-flows) FQ_PIE_FLOWS_REQUEST=$2;; --curve) CURVE=$2; CURVE_SEEN=1;;
        esac
        shift 2;;
      --adapt) SHAPE_REQUEST=adapt; shift;;
      --nic-tune) NIC_TUNE=1; shift;;
      --resolve-conflicts) RESOLVE_CONFLICTS=1; shift;;
      --absorb-orphans) ABSORB_ORPHANS=1; shift;;
      --yes|-y) ASSUME_YES=1; shift;;
      --verbose) VERBOSE=1; shift;; --no-color) shift;;
      --help|-h) usage; exit 0;; --version) say "$VERSION"; exit 0;;
      *) die "未知参数：$1";;
    esac
  done
}

detect_memory_mib() {
  # 查询进程所属 cgroup 以及所有父级限制；不以宿主机 MemTotal 冒充容器预算。
  local bytes limit rel dir mount suffix
  bytes=$(awk '/^MemTotal:/{printf "%.0f", $2*1024; exit}' "$PROC_ROOT/meminfo")
  is_uint "$bytes" || die "无法读取 MemTotal"
  rel=$(awk -F: '$1=="0" && $2=="" {print $3; exit}' "$PROC_ROOT/self/cgroup" 2>/dev/null || true)
  if [[ -n $rel && $rel != *..* ]]; then
    mount=$CGROUP_ROOT; dir=$mount${rel%/}
    while [[ $dir == "$mount" || $dir == "$mount/"* ]]; do
      if [[ -r $dir/memory.max ]]; then
        limit=$(<"$dir/memory.max")
        if [[ $limit =~ ^[0-9]+$ ]] && awk -v a="$limit" -v b="$bytes" 'BEGIN{exit !(a>0 && a<b)}'; then bytes=$limit; fi
      fi
      [[ $dir != "$mount" ]] || break
      dir=${dir%/*}
    done
  fi
  rel=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3; exit}' "$PROC_ROOT/self/cgroup" 2>/dev/null || true)
  if [[ -n $rel && $rel != *..* ]]; then
    for suffix in memory ''; do
      mount=$CGROUP_ROOT${suffix:+/$suffix}; dir=$mount${rel%/}
      while [[ $dir == "$mount" || $dir == "$mount/"* ]]; do
        if [[ -r $dir/memory.limit_in_bytes ]]; then
          limit=$(<"$dir/memory.limit_in_bytes")
          if [[ $limit =~ ^[0-9]+$ ]] && awk -v a="$limit" -v b="$bytes" 'BEGIN{exit !(a>0 && a<b)}'; then bytes=$limit; fi
        fi
        [[ $dir != "$mount" ]] || break
        dir=${dir%/*}
      done
    done
  fi
  awk -v n="$bytes" 'BEGIN{printf "%d", n/1048576}'
}

sample_rtt() {
  local target=$1 output
  [[ $target != -* && $target =~ ^[a-zA-Z0-9._:%-]+$ ]] || return 1
  command -v ping >/dev/null 2>&1 || return 1
  output=$(LC_ALL=C ping -n -c 5 -W 2 -- "$target" 2>&1 || true)
  awk '{for(i=1;i<=NF;i++) if($i ~ /^time[=<][0-9.]+/) {v=$i; sub(/^time[=<]/,"",v); sum+=v; n++}}
    END{if(n>=3) printf "%d", int(sum/n+0.999); else exit 1}' <<< "$output"
}
measure_rtt() {
  RTT_MS=$(sample_rtt "$RTT_HOST") || die "无法可靠测量 RTT（需至少 3/5 个响应）；请指定真实目标或 --rtt-ms"
  ((RTT_MS > 0)) || RTT_MS=1
  info "目标 $RTT_HOST，平均 RTT 约 ${RTT_MS}ms"
}

validate_inputs() {
  local name value actual p0 p1 p2 extra
  for name in LOCAL_MBPS SERVER_MBPS RTT_MS; do
    value=${!name}; is_uint "$value" || die "$name 必须为正整数"
    printf -v "$name" '%s' "$(norm_uint "$value")"
  done
  ((LOCAL_MBPS<=100000 && SERVER_MBPS<=100000 && RTT_MS<=10000)) || die "带宽最大 100000 Mbps，RTT 最大 10000ms"
  actual=$(detect_memory_mib); is_uint "$actual" || die "有效内存不足 1 MiB"
  if [[ -n $MEMORY_MIB ]]; then
    is_uint "$MEMORY_MIB" || die "memory-mib 必须为正整数"
    MEMORY_MIB=$(norm_uint "$MEMORY_MIB")
    ((MEMORY_MIB <= actual)) || { warn "内存预算超出实际限制，收紧到 $actual MiB"; MEMORY_MIB=$actual; }
  else MEMORY_MIB=$actual; fi
  for name in BUFFER_MAX_MIB NETDEV_BACKLOG NETDEV_BUDGET NETDEV_BUDGET_USECS TCP_OUTPUT_BYTES CAKE_RATE_MBPS; do
    value=${!name}; [[ -n $value ]] || continue
    is_uint "$value" || die "$name 必须为正整数"
    value=$(norm_uint "$value"); ((value<=2147483647)) || die "$name 过大"
    printf -v "$name" '%s' "$value"
  done
  case $PROFILE in streaming|balanced|latency|bulk) ;; *) die "未知 profile";; esac
  case $QDISC_REQUEST in auto|fq|fq_codel|fq_pie|cake) ;; *) die "未知 qdisc";; esac
  case $CC_REQUEST in auto|bbr|cubic|keep) ;; *) die "未知拥塞控制";; esac
  case $ROLE in host|router) ;; *) die "未知角色";; esac
  case $TUNE_RPS in keep|auto|on|off) ;; *) die "未知 RPS 模式";; esac
  case $SHAPE_REQUEST in off|auto|adapt) ;; *)
    is_uint "$SHAPE_REQUEST" || die "shape 必须为 off/auto/adapt/正整数"
    SHAPE_REQUEST=$(norm_uint "$SHAPE_REQUEST"); ((SHAPE_REQUEST<=100000)) || die "整形速率过大";; esac
  [[ -z $CAKE_RATE_MBPS || $SHAPE_REQUEST == off ]] || die "--cake-rate-mbps 与 --shape 不能同时指定"
  [[ -z $CAKE_RATE_MBPS ]] || ((CAKE_RATE_MBPS<=100000)) || die "整形速率过大"
  if [[ $SHAPE_REQUEST == adapt ]]; then
    [[ -n $RTT_HOST ]] || die "实验自适应整形必须指定 --rtt-host 实际业务目标"
    has_systemd || die "自适应整形需要 systemd；请改用固定整形"
  fi
  [[ $IFACE == auto || $IFACE =~ ^[a-zA-Z0-9_.:@-]+$ ]] || die "网卡名称无效"
  if [[ $FQ_PIE_FLOWS_REQUEST != auto ]]; then
    is_uint "$FQ_PIE_FLOWS_REQUEST" || die "fq-pie-flows 必须为整数"
    FQ_PIE_FLOWS_REQUEST=$(norm_uint "$FQ_PIE_FLOWS_REQUEST")
    ((FQ_PIE_FLOWS_REQUEST>=256 && FQ_PIE_FLOWS_REQUEST<=65536)) || die "flows 范围 256-65536"
  fi
  if [[ -n $TCP_MEM_REQUEST ]]; then
    IFS=' ' read -r p0 p1 p2 extra <<< "$TCP_MEM_REQUEST"
    if [[ -n $extra ]] || ! is_uint "$p0" || ! is_uint "$p1" || ! is_uint "$p2"; then die "tcp-mem 需三个正整数（页）"; fi
    p0=$(norm_uint "$p0"); p1=$(norm_uint "$p1"); p2=$(norm_uint "$p2")
    ((p0<=p1 && p1<=p2 && p2<=MEMORY_MIB*1048576/PAGE_SIZE)) || die "tcp-mem 水位顺序或内存预算无效"
    TCP_MEM_REQUEST="$p0 $p1 $p2"
  fi
  if ((CURVE_SEEN)); then
    [[ $CURVE =~ ^(0\.[0-9]{1,2}|1(\.0{1,2})?|[2-9]|10)$ ]] || die "旧 curve 参数格式无效"
    awk -v c="$CURVE" 'BEGIN{exit !(c>=0.1 && c<=10)}' || die '旧 curve 参数超出范围'
    warn "--curve 仅作命令兼容，不调整 BBR、队列或处理预算"
  fi
}

detect_interface() {
  local queue
  if [[ $IFACE == auto ]]; then
    IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n $IFACE ]] || IFACE=$(ip -6 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  fi
  [[ -n $IFACE && -d $SYS_ROOT/class/net/$IFACE ]] || die "找不到出口网卡；请显式 --interface"
  MTU=$(<"$SYS_ROOT/class/net/$IFACE/mtu"); is_uint "$MTU" || die "无法读取 MTU"
  IFACE_MAC=$(cat "$SYS_ROOT/class/net/$IFACE/address" 2>/dev/null || true)
  CPU_COUNT=$(getconf _NPROCESSORS_ONLN); is_uint "$CPU_COUNT" || CPU_COUNT=1
  RX_QUEUES=0; TX_QUEUES=0
  for queue in "$SYS_ROOT/class/net/$IFACE/queues"/rx-*; do [[ ! -d $queue ]] || RX_QUEUES=$((RX_QUEUES+1)); done
  for queue in "$SYS_ROOT/class/net/$IFACE/queues"/tx-*; do [[ ! -d $queue ]] || TX_QUEUES=$((TX_QUEUES+1)); done
  ((RX_QUEUES>0)) || RX_QUEUES=1; ((TX_QUEUES>0)) || TX_QUEUES=1
  PAGE_SIZE=$(getconf PAGESIZE); is_uint "$PAGE_SIZE" || die "无法读取内核页大小"
}

cc_available() { local a; a=$(sysctl -n net.ipv4.tcp_available_congestion_control); [[ " $a " == *" $1 "* ]]; }
select_congestion_control() {
  local current
  current=$(sysctl -n net.ipv4.tcp_congestion_control)
  [[ $current =~ ^[a-zA-Z0-9_]+$ ]] || die "无法读取当前拥塞控制"
  CC=$current; CC_EXPLICIT=0
  case $CC_REQUEST in
    keep) return 0;;
    bbr|cubic) CC=$CC_REQUEST; CC_EXPLICIT=1;;
    auto)
      if cc_available bbr; then CC=bbr
      elif command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then CC=bbr
      fi;;
  esac
}

calculate() {
  local bottleneck factor mem_cap candidate current_r current_w
  bottleneck=$(min "$LOCAL_MBPS" "$SERVER_MBPS")
  BDP_BYTES=$((bottleneck*RTT_MS*125))
  case $PROFILE in latency) factor=2;; bulk) factor=4;; *) factor=3;; esac
  # Ceiling is lazy allocation, not reservation. At most 1/32 of effective memory,
  # capped at 64 MiB. Warn if a large BDP cannot fit; never increase the RAM budget.
  mem_cap=$((MEMORY_MIB*1048576/32)); ((mem_cap>=65536)) || die "有效内存过小"
  mem_cap=$(min "$mem_cap" 67108864)
  if [[ -n $BUFFER_MAX_MIB ]]; then mem_cap=$(min "$mem_cap" "$((BUFFER_MAX_MIB*1048576))"); fi
  candidate=$(clamp "$((BDP_BYTES*factor))" "$(min 4194304 "$mem_cap")" "$mem_cap")
  current_r=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
  current_w=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')
  # Preserve larger existing valid maxima unless explicit caps or safety budget require shrinking.
  if [[ -z $BUFFER_MAX_MIB ]]; then
    if is_uint "$current_r" && ((current_r>candidate)); then candidate=$(min "$current_r" "$mem_cap"); fi
    if is_uint "$current_w" && ((current_w>candidate)); then candidate=$(min "$current_w" "$mem_cap"); fi
  fi
  BUFFER_BYTES=$candidate
  ((BUFFER_BYTES>=BDP_BYTES*2)) || warn "内存预算限制了缓冲区：BDP $(human_bytes "$BDP_BYTES")，socket 上限 $(human_bytes "$BUFFER_BYTES")；峰值可能受窗口限制"
  ADAPT=0; CAKE_RATE_KBIT=''; SHAPE_MBPS=''
  case $SHAPE_REQUEST in off) ;; auto|adapt) SHAPE_MBPS=$bottleneck;; *) SHAPE_MBPS=$SHAPE_REQUEST;; esac
  [[ -z $CAKE_RATE_MBPS ]] || SHAPE_MBPS=$CAKE_RATE_MBPS
  [[ -z $SHAPE_MBPS ]] || CAKE_RATE_KBIT=$((SHAPE_MBPS*1000))
  [[ $SHAPE_REQUEST != adapt ]] || ADAPT=1
  if [[ -n $CAKE_RATE_KBIT ]]; then QDISC=cake
  elif [[ $QDISC_REQUEST != auto ]]; then QDISC=$QDISC_REQUEST
  elif [[ $ROLE == router ]]; then QDISC=fq_codel
  else QDISC=fq; fi
  FQ_PIE_FLOWS=$FQ_PIE_FLOWS_REQUEST
}

build_qdisc_args() {
  case $QDISC in
    fq) QDISC_ARGS=(fq pacing);;
    fq_codel) QDISC_ARGS=(fq_codel);;
    fq_pie) QDISC_ARGS=(fq_pie); [[ $FQ_PIE_FLOWS == auto ]] || QDISC_ARGS+=(flows "$FQ_PIE_FLOWS");;
    cake)
      QDISC_ARGS=(cake)
      [[ -z $CAKE_RATE_KBIT ]] || QDISC_ARGS+=(bandwidth "${CAKE_RATE_KBIT}Kbit")
      QDISC_ARGS+=(besteffort flows nonat nowash no-ack-filter rtt "${RTT_MS}ms");;
    *) return 1;;
  esac
}

emit_setting() {
  local key=$1
  if [[ -e $PROC_ROOT/sys/${key//./\/} ]]; then printf '%s = %s\n' "$key" "$2"
  else warn "当前内核不提供 $key，跳过"; fi
}
emit_config() {
  local rdef wdef rmin wmin
  rmin=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $1}')
  wmin=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $1}')
  rdef=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')
  wdef=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $2}')
  rmin=$(min "$rmin" "$BUFFER_BYTES"); wmin=$(min "$wmin" "$BUFFER_BYTES")
  rdef=$(clamp "$rdef" "$rmin" "$BUFFER_BYTES"); wdef=$(clamp "$wdef" "$wmin" "$BUFFER_BYTES")
  say "# Managed by tcp-tune.sh v$VERSION"
  say "# local=${LOCAL_MBPS}Mbps server=${SERVER_MBPS}Mbps RTT=${RTT_MS}ms memory=${MEMORY_MIB}MiB page=${PAGE_SIZE}"
  emit_setting net.core.default_qdisc "$QDISC"
  [[ $CC_REQUEST == keep ]] || emit_setting net.ipv4.tcp_congestion_control "$CC"
  emit_setting net.core.rmem_max "$BUFFER_BYTES"
  emit_setting net.core.wmem_max "$BUFFER_BYTES"
  emit_setting net.ipv4.tcp_rmem "$rmin $rdef $BUFFER_BYTES"
  emit_setting net.ipv4.tcp_wmem "$wmin $wdef $BUFFER_BYTES"
  emit_setting net.ipv4.tcp_moderate_rcvbuf 1
  emit_setting net.ipv4.tcp_window_scaling 1
  [[ -z $NETDEV_BACKLOG ]] || emit_setting net.core.netdev_max_backlog "$NETDEV_BACKLOG"
  [[ -z $NETDEV_BUDGET ]] || emit_setting net.core.netdev_budget "$NETDEV_BUDGET"
  [[ -z $NETDEV_BUDGET_USECS ]] || emit_setting net.core.netdev_budget_usecs "$NETDEV_BUDGET_USECS"
  [[ -z $TCP_OUTPUT_BYTES ]] || emit_setting net.ipv4.tcp_limit_output_bytes "$TCP_OUTPUT_BYTES"
  [[ -z $TCP_MEM_REQUEST ]] || emit_setting net.ipv4.tcp_mem "$TCP_MEM_REQUEST"
  if [[ -n $RPS_MASK && $RPS_MASK != 0 ]]; then emit_setting net.core.rps_sock_flow_entries "$RPS_ENTRIES"; fi
  if ((${#CARRY_LINES[@]})); then say '# Preserved unmanaged settings'; printf '%s\n' "${CARRY_LINES[@]}"; fi
  return 0
}

preview_config() {
  build_qdisc_args
  say "TCP Tune $VERSION：$CC + $QDISC"
  say "链路：$(min "$LOCAL_MBPS" "$SERVER_MBPS") Mbps / ${RTT_MS}ms；BDP $(human_bytes "$BDP_BYTES")"
  say "资源：$CPU_COUNT 核 / ${MEMORY_MIB} MiB 有效预算 / ${PAGE_SIZE} 字节页 / RX:$RX_QUEUES TX:$TX_QUEUES"
  say "socket 上限：$(human_bytes "$BUFFER_BYTES")（按需增长；全局 tcp_mem 默认保留）"
  if [[ -n $CAKE_RATE_KBIT ]]; then
    say "整形：$SHAPE_REQUEST，${SHAPE_MBPS} Mbps；不会按核心数自动限速"
    ((ADAPT==0)) || warn "实验自适应：需同一实际目标；不能区分各连接的丢包原因，谨慎使用"
  else say '整形：关闭'; fi
  say "出口：$IFACE；RPS:$TUNE_RPS；offload:$([[ $NIC_TUNE == 1 ]] && printf '显式尝试开启' || printf '保留')"
  info "mq 将在应用时检测并保留；不支持的队列会在应用阶段尝试兼容降级"
  if ((VERBOSE)); then
    printf '队列选项：'; printf '%q ' "${QDISC_ARGS[@]}"; printf '\n'
    emit_config
  fi
}

# sysctl.d 同名文件按目录优先级选择，再按文件名排序。
sysctl_files() {
  local d f b; local -A selected=()
  for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    for f in "$d"/*.conf; do
      [[ -e $f || -L $f ]] || continue
      b=${f##*/}; [[ -v selected[$b] ]] || selected[$b]=$f
    done
  done
  for b in "${!selected[@]}"; do printf '%s\t%s\n' "$b" "${selected[$b]}"; done | sort | cut -f2-
}
managed_key() {
  case $1 in
    net.core.default_qdisc|net.ipv4.tcp_congestion_control|net.core.rmem_max|net.core.wmem_max|net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.ipv4.tcp_moderate_rcvbuf|net.ipv4.tcp_window_scaling|net.core.netdev_max_backlog|net.core.netdev_budget|net.core.netdev_budget_usecs|net.ipv4.tcp_limit_output_bytes|net.ipv4.tcp_mem|net.core.rps_sock_flow_entries) return 0;;
    # v3.3 旧托管键，不再默认继承。
    net.core.optmem_max|net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|net.ipv4.tcp_mtu_probing|net.ipv4.tcp_fastopen|net.ipv4.tcp_keepalive_time|net.ipv4.tcp_keepalive_intvl|net.ipv4.tcp_keepalive_probes|net.ipv4.tcp_fin_timeout|net.ipv4.tcp_slow_start_after_idle) return 0;;
    *) return 1;;
  esac
}
collect_carry_lines() {
  local f line key real orphan=1; local sources=()
  CARRY_LINES=()
  if [[ -e $CONFIG_FILE ]]; then
    [[ ! -L $CONFIG_FILE ]] || die "本工具配置不能是符号链接"
    grep -q '^# Managed by tcp-tune.sh' "$CONFIG_FILE" || die "$CONFIG_FILE 已存在且不属于本工具，拒绝覆盖"
    sources+=("$CONFIG_FILE")
  fi
  if ((ABSORB_ORPHANS)) && [[ -f /etc/sysctl.conf ]]; then
    real=$(readlink -f /etc/sysctl.conf)
    while IFS= read -r f; do [[ $(readlink -f "$f") != "$real" ]] || orphan=0; done < <(sysctl_files)
    ((orphan==0)) || sources+=(/etc/sysctl.conf)
  fi
  for f in "${sources[@]}"; do
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*([a-zA-Z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      key=${BASH_REMATCH[1]}; managed_key "$key" && continue
      case $key in vm.panic_on_oom|vm.overcommit_memory) warn "不自动合并 $key"; continue;; esac
      if [[ -e $PROC_ROOT/sys/${key//./\/} ]]; then
        local value=${BASH_REMATCH[2]}; value=${value%%#*}; value=${value%%;*}
        CARRY_LINES+=("$key = $value")
      else warn "非托管键 $key 在当前内核不存在，保留为注释"; CARRY_LINES+=("# unsupported: $line"); fi
    done < "$f"
  done
}
find_conflicts() {
  local f real line key own; local -A seen=() keys=()
  CONFLICT_FILES=(); own=$(readlink -m "$CONFIG_FILE")
  for key in "${SYSCTL_KEYS[@]}"; do keys[$key]=1; done
  while IFS= read -r f; do
    [[ -f $f ]] || continue; real=$(readlink -f "$f")
    [[ $real != "$own" && ! -v seen[$real] ]] || continue; seen[$real]=1
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*([a-zA-Z0-9_.]+)[[:space:]]*= ]] || continue
      key=${BASH_REMATCH[1]}; [[ -v keys[$key] ]] || continue
      if [[ $real == /etc/* ]]; then CONFLICT_FILES+=("$real"); break
      else warn "系统配置 $f 也设置 $key，请检查文件名排序后的最终值"; fi
    done < "$f"
  done < <({ sysctl_files; [[ ! -f /etc/sysctl.conf ]] || printf '%s\n' /etc/sysctl.conf; })
}
comment_conflicts() {
  local f tmp keyfile
  ((${#CONFLICT_FILES[@]})) || return 0
  if ((RESOLVE_CONFLICTS==0)); then
    warn "检测到重复键；请先处理，或添加 --resolve-conflicts 仅注释重复行"
    printf '  %s\n' "${CONFLICT_FILES[@]}" >&2
    return 1
  fi
  keyfile=$TXN_DIR/keys; printf '%s\n' "${SYSCTL_KEYS[@]}" > "$keyfile"
  for f in "${CONFLICT_FILES[@]}"; do
    backup_file "$f" "$TXN_DIR"
    tmp=$(mktemp "${f}.tcp-tune.XXXXXX")
    awk 'NR==FNR{k[$0]=1;next} {a=$0; sub(/^[ \t]*/,"",a); split(a,b,/[ \t]*=/); if(a!~/^#/ && b[1] in k) print "# tcp-tune disabled duplicate: " $0; else print $0}' "$keyfile" "$f" > "$tmp"
    chmod --reference="$f" "$tmp"; chown --reference="$f" "$tmp"; mv -f -- "$tmp" "$f"
  done
}

# 保存可以无歧义重放的简单 qdisc；自定义 class/filter 树在修改前拒绝接管。
decode_qdisc_line() {
  local line=$1 token value i=4 location='' handle kind; local words=()
  IFS=' ' read -r -a words <<< "$line"
  [[ ${words[0]:-} == qdisc && ${#words[@]} -ge 4 ]] || return 1
  kind=${words[1]}; handle=${words[2]}
  [[ $handle =~ ^[0-9a-fA-F]+:$ ]] || return 1
  case ${words[3]} in
    root) location=root;; parent) location=${words[4]:-}; i=5;; *) return 1;;
  esac
  [[ $location == root || $location =~ ^[0-9a-fA-F]*:[0-9a-fA-F]+$ ]] || return 1
  RESTORE_KIND=$kind; RESTORE_HANDLE=$handle; RESTORE_PARENT=$location; RESTORE_ARGS=()
  case $kind in mq|noqueue) ;; pfifo_fast) [[ " $line " == *' bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 '* ]] || return 1;;
    fq|fq_codel|fq_pie|cake|pfifo|bfifo) ;; *) return 1;; esac
  while ((i < ${#words[@]})); do
    token=${words[$i]}; i=$((i+1))
    case $token in
      refcnt) ((i<${#words[@]})) || return 1; i=$((i+1)); continue;;
      bands|priomap) [[ $kind == pfifo_fast ]] && break; return 1;;
    esac
    case $kind:$token in
      fq:pacing|fq:nopacing|fq:horizon_drop|fq:horizon_cap|fq_codel:ecn|fq_codel:noecn|fq_pie:ecn|fq_pie:noecn|fq_pie:bytemode|fq_pie:nobytemode|fq_pie:dq_rate_estimator|fq_pie:nodq_rate_estimator|cake:besteffort|cake:diffserv3|cake:diffserv4|cake:diffserv8|cake:flowblind|cake:flows|cake:srchost|cake:dsthost|cake:hosts|cake:dual-srchost|cake:dual-dsthost|cake:triple-isolate|cake:nat|cake:nonat|cake:wash|cake:nowash|cake:ack-filter|cake:ack-filter-aggressive|cake:no-ack-filter|cake:split-gso|cake:no-split-gso|cake:raw|cake:atm|cake:ptm|cake:noatm|cake:ingress|cake:egress|cake:autorate-ingress)
        RESTORE_ARGS+=("$token");;
      fq:limit|fq:flow_limit|fq:quantum|fq:initial_quantum|fq:buckets|fq:orphan_mask|fq:maxrate|fq:low_rate_threshold|fq:refill_delay|fq:ce_threshold|fq:timer_slack|fq:horizon|fq_codel:limit|fq_codel:flows|fq_codel:quantum|fq_codel:target|fq_codel:interval|fq_codel:memory_limit|fq_codel:drop_batch|fq_codel:ce_threshold|fq_codel:ce_threshold_selector|fq_pie:limit|fq_pie:flows|fq_pie:quantum|fq_pie:target|fq_pie:tupdate|fq_pie:alpha|fq_pie:beta|fq_pie:memory_limit|cake:bandwidth|cake:rtt|cake:overhead|cake:mpu|cake:memlimit|cake:fwmark|pfifo:limit|bfifo:limit)
        ((i<${#words[@]})) || return 1; value=${words[$i]}; i=$((i+1))
        [[ $value =~ ^[a-zA-Z0-9.:/_+-]+$ ]] || return 1
        case $token in limit|flow_limit) [[ $kind == bfifo ]] || value=${value%p};; esac
        if [[ $kind:$token:$value == cake:bandwidth:unlimited ]]; then RESTORE_ARGS+=(unlimited)
        else RESTORE_ARGS+=("$token" "$value"); fi;;
      *) return 1;;
    esac
  done
}

remember_live_qdisc() {
  local backup=$1 line roots=0 rootkind='' roothandle='' parent; local args=()
  tc -d qdisc show dev "$IFACE" > "$backup/qdisc.before"
  tc class show dev "$IFACE" > "$backup/classes.before"
  tc filter show dev "$IFACE" root > "$backup/filters.before"
  [[ ! -s $backup/filters.before ]] || die "存在自定义 root filter，未修改；请单独管理此队列树"
  printf '#!/usr/bin/env bash\nset -e\n' > "$backup/qdisc.restore"
  MQ_PARENTS=(); KEEP_MQ=0
  while IFS= read -r line; do
    [[ $line != 'qdisc ingress '* && $line != 'qdisc clsact '* ]] || continue
    decode_qdisc_line "$line" || die "无法可靠备份该队列，未修改：$line"
    [[ $RESTORE_PARENT == root ]] || continue
    roots=$((roots+1)); rootkind=$RESTORE_KIND; roothandle=$RESTORE_HANDLE
    args=(tc qdisc replace dev "$IFACE" root)
    if [[ $RESTORE_HANDLE == 0: && ( $RESTORE_KIND == mq || $RESTORE_KIND == noqueue || $RESTORE_KIND == pfifo_fast ) ]]; then
      printf 'tc qdisc del dev %q root 2>/dev/null || true\n' "$IFACE" >> "$backup/qdisc.restore"
    else
      [[ $RESTORE_HANDLE == 0: ]] || args+=(handle "$RESTORE_HANDLE")
      args+=("$RESTORE_KIND" "${RESTORE_ARGS[@]}")
      printf '%q ' "${args[@]}" >> "$backup/qdisc.restore"; printf '\n' >> "$backup/qdisc.restore"
    fi
  done < "$backup/qdisc.before"
  ((roots==1)) || die "无法识别唯一根队列；未修改"
  if [[ -s $backup/classes.before ]]; then
    if [[ $rootkind != mq ]] || awk '$1!="class" || $2!="mq" {bad=1} END{exit !bad}' "$backup/classes.before"; then die "存在自定义 class，未修改"; fi
  fi
  while IFS= read -r line; do
    [[ $line != 'qdisc ingress '* && $line != 'qdisc clsact '* ]] || continue
    decode_qdisc_line "$line" || die "队列快照解析失败"
    [[ $RESTORE_PARENT != root ]] || continue
    [[ $rootkind == mq ]] || die "不支持自动接管多级队列树；未修改"
    parent=$RESTORE_PARENT
    local prefix=${parent%%:*}
    [[ ${prefix:-0}: == "$roothandle" ]] || die "无法识别 mq 子队列父级"
    MQ_PARENTS+=("$parent")
    args=(tc qdisc replace dev "$IFACE" parent "$parent")
    [[ $RESTORE_HANDLE == 0: ]] || args+=(handle "$RESTORE_HANDLE")
    args+=("$RESTORE_KIND" "${RESTORE_ARGS[@]}")
    printf '%q ' "${args[@]}" >> "$backup/qdisc.restore"; printf '\n' >> "$backup/qdisc.restore"
  done < "$backup/qdisc.before"
  if [[ $rootkind == mq && -z $CAKE_RATE_KBIT && $QDISC != cake ]] && ((${#MQ_PARENTS[@]})); then KEEP_MQ=1; fi
  printf '%s\n' "$IFACE" > "$backup/qdisc.iface"
  chmod 0600 "$backup/qdisc.restore"
}

try_qdisc() {
  local parent
  build_qdisc_args
  if ((KEEP_MQ)); then
    for parent in "${MQ_PARENTS[@]}"; do tc qdisc replace dev "$IFACE" parent "$parent" "${QDISC_ARGS[@]}" || return 1; done
  else tc qdisc replace dev "$IFACE" root "${QDISC_ARGS[@]}" || return 1; fi
}
apply_live_qdisc() {
  local requested=$QDISC fallback
  try_module "sch_$QDISC"
  if try_qdisc; then return 0; fi
  if [[ -n $CAKE_RATE_KBIT ]]; then
    # 固定速率是显式意图，失败不能静默变成无限速。
    warn "CAKE 整形未成功挂载，将回滚；不静默取消用户指定的速率"
    return 1
  fi
  for fallback in fq fq_codel; do
    [[ $fallback != "$requested" ]] || continue
    QDISC=$fallback; CAKE_RATE_KBIT=''; SHAPE_MBPS=''; ADAPT=0
    try_module "sch_$QDISC"
    if try_qdisc; then warn "$requested 不可用，实际使用 $QDISC（无整形）"; return 0; fi
  done
  return 1
}

cpu_mask() {
  # 取 online 与进程允许 CPU 的交集，兼容稀疏 CPU / cpuset。
  local online allowed part start end cpu grp bit high=0 g; local -a groups=(); local parts=()
  local -A allowed_set=()
  online=$(cat "$SYS_ROOT/devices/system/cpu/online" 2>/dev/null || true)
  [[ $online =~ ^[0-9,-]+$ ]] || return 1
  allowed=$(awk '/^Cpus_allowed_list:/{print $2;exit}' "$PROC_ROOT/self/status" 2>/dev/null || true)
  if [[ $allowed =~ ^[0-9,-]+$ ]]; then
    IFS=, read -r -a parts <<< "$allowed"
    for part in "${parts[@]}"; do
      start=${part%-*}; end=${part#*-}; [[ $part == *-* ]] || end=$start
      for ((cpu=start;cpu<=end;cpu++)); do allowed_set[$cpu]=1; done
    done
  fi
  IFS=, read -r -a parts <<< "$online"
  for part in "${parts[@]}"; do
    start=${part%-*}; end=${part#*-}; [[ $part == *-* ]] || end=$start
    for ((cpu=start;cpu<=end;cpu++)); do
      if ((${#allowed_set[@]})) && [[ ! -v allowed_set[$cpu] ]]; then continue; fi
      grp=$((cpu/32)); bit=$((cpu%32)); groups[grp]=$(( ${groups[grp]:-0} | (1<<bit) )); ((grp<=high)) || high=$grp
    done
  done
  printf '%x' "${groups[$high]:-0}"
  for ((g=high-1;g>=0;g--)); do printf ',%08x' "${groups[$g]:-0}"; done
}
prepare_rps() {
  RPS_MASK=''
  RPS_ENTRIES=32768; RPS_FLOW_PER_QUEUE=$((RPS_ENTRIES/RX_QUEUES))
  case $TUNE_RPS in keep) return 0;; off) RPS_MASK=0;;
    on) RPS_MASK=$(cpu_mask) || die "无法确定 online CPU";;
    auto) if ((CPU_COUNT>1 && RX_QUEUES==1)); then RPS_MASK=$(cpu_mask) || die "无法确定 online CPU"; fi;; esac
}
apply_rps() {
  local q
  [[ -n $RPS_MASK ]] || return 0
  for q in "$SYS_ROOT/class/net/$IFACE/queues"/rx-*; do
    [[ -w $q/rps_cpus ]] || { warn "$q 不支持 RPS，跳过"; continue; }
    printf '%s' "$RPS_MASK" > "$q/rps_cpus"
    if [[ -w $q/rps_flow_cnt ]]; then
      if [[ $RPS_MASK == 0 ]]; then printf 0 > "$q/rps_flow_cnt"; else printf '%s' "$RPS_FLOW_PER_QUEUE" > "$q/rps_flow_cnt"; fi
    fi
  done
}
snapshot_nic() {
  local backup=$1 q f features name alias value fixed; local names=(generic-receive-offload generic-segmentation-offload tcp-segmentation-offload)
  : > "$backup/rps.before"; : > "$backup/offloads.before"
  [[ -z $RPS_MASK ]] || for q in "$SYS_ROOT/class/net/$IFACE/queues"/rx-*; do
    for f in rps_cpus rps_flow_cnt; do [[ ! -r $q/$f ]] || printf '%s\t%s\n' "$q/$f" "$(<"$q/$f")" >> "$backup/rps.before"; done
  done
  if ((NIC_TUNE)) && command -v ethtool >/dev/null 2>&1; then
    features=$(ethtool -k "$IFACE") || { warn "无法读取 offload，取消本次 offload 调整"; NIC_TUNE=0; return 0; }
    for name in "${names[@]}"; do
      IFS=' ' read -r value fixed <<< "$(awk -v n="$name:" '$1==n{print $2,$3;exit}' <<< "$features")"
      [[ $value == on || $value == off ]] || continue
      [[ $fixed != '[fixed]' ]] || continue
      case $name in generic-receive-offload) alias=gro;; generic-segmentation-offload) alias=gso;; *) alias=tso;; esac
      printf '%s\t%s\n' "$alias" "$value" >> "$backup/offloads.before"
    done
  fi
}
tune_nic_offloads() {
  local option
  ((NIC_TUNE)) || return 0
  command -v ethtool >/dev/null 2>&1 || { warn "缺少 ethtool，保留 offload"; return 0; }
  for option in gro gso tso; do ethtool -K "$IFACE" "$option" on || warn "$option 不支持变更，保留驱动状态"; done
}

managed_paths() {
  printf '%s\n' "$CONFIG_FILE" "$MODULE_FILE" "$ENGINE_FILE" "$PLAN_FILE" "$QDISC_RUNTIME_FILE" "$QDISC_SERVICE_FILE" "$ADAPT_RUNTIME_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE" "$ADAPT_STATE_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE"
}
backup_file() {
  local source=$1 backup=$2
  [[ $source == /* && $source != *$'\n'* ]] || return 1
  [[ -e $backup$source || -L $backup$source ]] && return 0
  [[ -e $source || -L $source ]] || return 0
  mkdir -p "$(dirname "$backup$source")"; cp -a -- "$source" "$backup$source"
}
lock_mutation() {
  require_root
  command -v flock >/dev/null 2>&1 || die "需要 util-linux 的 flock"
  [[ ! -L $BACKUP_ROOT ]] || die "备份目录不能为符号链接"
  install -d -m 0700 "$BACKUP_ROOT"
  exec 9> "$BACKUP_ROOT/.lock"
  flock -n 9 || die "另一个应用/恢复/自适应任务正在执行"
}
snapshot_services() {
  local service enabled active
  : > "$TXN_DIR/services.before"
  has_systemd || return 0
  for service in "$QDISC_SERVICE_NAME" "$ADAPT_SERVICE_NAME" "$ADAPT_TIMER_NAME" tcp-tune-runtime.service; do
    enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
    active=$(systemctl is-active "$service" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$service" "${enabled:-not-found}" "${active:-inactive}" >> "$TXN_DIR/services.before"
  done
}
stop_managed_services() {
  has_systemd || return 0
  local service
  for service in "$ADAPT_TIMER_NAME" "$ADAPT_SERVICE_NAME" "$QDISC_SERVICE_NAME" tcp-tune-runtime.service; do
    if systemctl cat "$service" >/dev/null 2>&1; then
      systemctl stop "$service" || return 1
    fi
  done
}

restore_from() {
  local backup=$1 path key value option iface service enabled active failure=0
  [[ -f $backup/manifest && -f $backup/sysctl.before ]] || { warn "该备份不是 v3.4 的完整事务快照"; return 1; }
  stop_managed_services || failure=1
  while IFS= read -r path; do
    [[ $path == /* && $path != *'/../'* ]] || { failure=1; continue; }
    if [[ -e $backup$path || -L $backup$path ]]; then
      mkdir -p "$(dirname "$path")" || { failure=1; continue; }
      cp -a --remove-destination -- "$backup$path" "$path" || failure=1
    else rm -f -- "$path" || failure=1; fi
  done < "$backup/manifest"
  while IFS=$'\t' read -r key value; do
    [[ -n $key ]] || continue
    sysctl -q -w "$key=$value" || { warn "无法恢复 $key"; failure=1; }
  done < "$backup/sysctl.before"
  if [[ -r $backup/rps.before ]]; then
    while IFS=$'\t' read -r path value; do
      if [[ ! -w $path ]]; then warn "无法恢复 $path"; failure=1
      else printf '%s' "$value" > "$path" || { warn "无法恢复 $path"; failure=1; }; fi
    done < "$backup/rps.before"
  fi
  iface=$(cat "$backup/qdisc.iface" 2>/dev/null || true)
  if [[ -r $backup/offloads.before ]]; then
    while IFS=$'\t' read -r option value; do ethtool -K "$iface" "$option" "$value" || failure=1; done < "$backup/offloads.before"
  fi
  if has_systemd; then
    systemctl daemon-reload || failure=1
    while IFS=$'\t' read -r service enabled active; do
      case $enabled in enabled|enabled-runtime) systemctl enable "$service" >/dev/null || failure=1;;
        *) systemctl disable "$service" >/dev/null 2>&1 || true;; esac
      # Timer starts last, after restoring actual queues.
      # oneshot 队列已按运行快照恢复，不重跑服务覆盖快照或竞争事务锁。
      # 启用状态已恢复；下一次启动仍正常重放。
    done < "$backup/services.before"
  fi
  if [[ -r $backup/qdisc.restore ]]; then bash "$backup/qdisc.restore" || { warn "队列重放失败，快照保留在 $backup"; failure=1; }; fi
  if has_systemd; then
    while IFS=$'\t' read -r service enabled active; do
      [[ $service != "$ADAPT_TIMER_NAME" || $active != active ]] || systemctl start "$service" || failure=1
    done < "$backup/services.before"
  fi
  ((failure==0))
}
rollback_on_exit() {
  local rc=$?
  if ((TXN_ACTIVE)); then
    TXN_ACTIVE=0; set +e
    warn "应用未完成，正在恢复修改前状态"
    if restore_from "$TXN_DIR"; then warn "已回滚；快照：$TXN_DIR"
    else warn "自动恢复有失败项，请查看上方错误和快照：$TXN_DIR"; fi
    if [[ -r $TXN_DIR/previous.latest ]]; then cp "$TXN_DIR/previous.latest" "$BACKUP_ROOT/latest"
    else rm -f "$BACKUP_ROOT/latest"; fi
    if [[ -r $BACKUP_ROOT/initial-v3.4 && $(cat "$BACKUP_ROOT/initial-v3.4") == "$TXN_DIR" ]]; then rm -f "$BACKUP_ROOT/initial-v3.4"; fi
    ((rc!=0)) || rc=1
  fi
  exit "$rc"
}

write_plan() {
  local name tmp; tmp=$(mktemp "$STATE_DIR/plan.XXXXXX")
  for name in IFACE IFACE_MAC QDISC KEEP_MQ TUNE_RPS RPS_MASK RPS_ENTRIES RPS_FLOW_PER_QUEUE NIC_TUNE ADAPT CAKE_RATE_KBIT RTT_MS RTT_HOST; do printf '%s=%q\n' "$name" "${!name}"; done > "$tmp"
  {
    printf 'QDISC_ARGS=('; printf '%q ' "${QDISC_ARGS[@]}"; printf ')\nMQ_PARENTS=('
    if ((${#MQ_PARENTS[@]})); then printf '%q ' "${MQ_PARENTS[@]}"; fi
    printf ')\n'
  } >> "$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$PLAN_FILE"
}
load_plan() {
  local attempt
  [[ -f $PLAN_FILE && ! -L $PLAN_FILE && $(stat -c %u "$PLAN_FILE") == 0 && $(stat -c %a "$PLAN_FILE") == 600 ]] || die "计划文件不存在或所有权/权限不正确"
  # Root-owned, mode 0600, written only by write_plan.
  # shellcheck source=/dev/null
  source "$PLAN_FILE"
  if [[ ${1:-} == wait ]]; then
    for ((attempt=0;attempt<30;attempt++)); do
      [[ ! -d $SYS_ROOT/class/net/$IFACE ]] || break
      sleep 1
    done
  fi
  [[ -d $SYS_ROOT/class/net/$IFACE ]] || die "计划网卡不存在：$IFACE"
  [[ -z $IFACE_MAC || $(cat "$SYS_ROOT/class/net/$IFACE/address") == "$IFACE_MAC" ]] || die "网卡身份改变，拒绝重放旧策略"
}
replay() {
  local parent current handle
  require_root; lock_mutation; load_plan wait
  try_module "sch_$QDISC"
  if ((KEEP_MQ)); then
    current=$(tc qdisc show dev "$IFACE" | awk '$4=="root"{print $2;exit}')
    [[ $current == mq ]] || die "原 mq 结构已改变，请重新生成计划"
    handle=$(tc qdisc show dev "$IFACE" | awk '$4=="root"{print $3;exit}')
    for parent in "${MQ_PARENTS[@]}"; do
      tc qdisc replace dev "$IFACE" parent "${handle%:}:${parent#*:}" "${QDISC_ARGS[@]}"
    done
  else tc qdisc replace dev "$IFACE" root "${QDISC_ARGS[@]}"; fi
  apply_rps; tune_nic_offloads
  if ((ADAPT)); then reset_adapt_state; fi
}
reset_adapt_state() {
  # Boot replay and stored controller state must use the same initial rate.
  local ceiling=$CAKE_RATE_KBIT floor tmp
  floor=$((ceiling*2/5)); ((floor>=1)) || floor=1
  tmp=$(mktemp "$STATE_DIR/adapt.XXXXXX")
  printf 'CUR_KBIT=%s\nCEIL_KBIT=%s\nFLOOR_KBIT=%s\nLAST_BYTES=0\nLAST_OUT=0\nLAST_RETR=0\nLAST_TS=0\nBAD_COUNT=0\nGOOD_COUNT=0\n' "$ceiling" "$ceiling" "$floor" > "$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$ADAPT_STATE_FILE"
}

install_persistence() {
  [[ -r $SELF_PATH && -f $SELF_PATH ]] || die "请先下载为本地文件再运行，不能用进程替换安装持久化"
  install -d -m 0755 "$(dirname "$ENGINE_FILE")"
  if [[ $(readlink -f "$SELF_PATH") != $(readlink -m "$ENGINE_FILE") ]]; then install -m 0755 "$SELF_PATH" "$ENGINE_FILE"; fi
  write_plan
  install -d -m 0755 "$(dirname "$QDISC_SERVICE_FILE")"
  cat > "$QDISC_SERVICE_FILE" <<EOF
[Unit]
Description=TCP Tune qdisc replay
Wants=network-online.target
After=network-online.target
ConditionPathExists=$PLAN_FILE
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ENGINE_FILE replay
[Install]
WantedBy=multi-user.target
EOF
  if has_systemd; then systemctl disable tcp-tune-runtime.service "$ADAPT_SERVICE_NAME" >/dev/null 2>&1 || true; fi
  rm -f "$QDISC_RUNTIME_FILE" "$ADAPT_RUNTIME_FILE" "$LEGACY_RUNTIME_FILE" "$LEGACY_SERVICE_FILE"
  if ((ADAPT)); then
    reset_adapt_state
    cat > "$ADAPT_SERVICE_FILE" <<EOF
[Unit]
Description=TCP Tune experimental adaptive shaping
After=network-online.target
ConditionPathExists=$PLAN_FILE
[Service]
Type=oneshot
ExecStart=$ENGINE_FILE adaptive
EOF
    cat > "$ADAPT_TIMER_FILE" <<EOF
[Unit]
Description=TCP Tune experimental shaping sampler
[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  else rm -f "$ADAPT_STATE_FILE" "$ADAPT_SERVICE_FILE" "$ADAPT_TIMER_FILE"; fi
  PERSISTENCE_AVAILABLE=0
  if has_systemd; then
    systemctl daemon-reload
    systemctl enable "$QDISC_SERVICE_NAME"
    if ((ADAPT)); then systemctl enable "$ADAPT_TIMER_NAME"; else systemctl disable "$ADAPT_TIMER_NAME" >/dev/null 2>&1 || true; fi
    PERSISTENCE_AVAILABLE=1
  else warn "没有运行中的 systemd：qdisc/RPS/offload 仅本次生效，sysctl 配置已保存"; fi
}

adaptive() {
  local bytes out retr now db do_count dr seconds load rtt inflated ratio next reason='' current line tmp
  require_root; lock_mutation; load_plan; ((ADAPT)) || return 0
  [[ -f $ADAPT_STATE_FILE && ! -L $ADAPT_STATE_FILE && $(stat -c %u "$ADAPT_STATE_FILE") == 0 && $(stat -c %a "$ADAPT_STATE_FILE") == 600 ]] || die "自适应状态文件不可信"
  # shellcheck source=/dev/null
  source "$ADAPT_STATE_FILE"
  line=$(tc qdisc show dev "$IFACE" | awk '$4=="root"{print;exit}')
  [[ $line == 'qdisc cake '* ]] || { info "队列已改变，不调整"; return 0; }
  current=$(awk '{for(i=1;i<=NF;i++)if($i=="bandwidth"){print $(i+1);exit}}' <<< "$line")
  bytes=$(<"$SYS_ROOT/class/net/$IFACE/statistics/tx_bytes")
  IFS=' ' read -r out retr < <(awk '$1=="Tcp:" && !seen++ {for(i=2;i<=NF;i++)c[$i]=i;next} $1=="Tcp:" {print $(c["OutSegs"]),$(c["RetransSegs"]);exit}' "$PROC_ROOT/net/snmp")
  [[ $bytes =~ ^[0-9]+$ && $out =~ ^[0-9]+$ && $retr =~ ^[0-9]+$ ]] || die "统计计数不可用"
  now=$(date +%s); next=$CUR_KBIT
  if ((LAST_TS>0 && bytes>=LAST_BYTES && out>=LAST_OUT && retr>=LAST_RETR && now>LAST_TS)); then
    db=$((bytes-LAST_BYTES)); do_count=$((out-LAST_OUT)); dr=$((retr-LAST_RETR)); seconds=$((now-LAST_TS))
    load=$((db*8*100/(seconds*CUR_KBIT*1000)))
    if ((load>=70 && do_count>=2000)); then
      rtt=$(sample_rtt "$RTT_HOST" || true)
      if is_uint "$rtt"; then
        ratio=$((dr*1000000/do_count)); inflated=$((RTT_MS+15)); ((inflated>=RTT_MS*3/2)) || inflated=$((RTT_MS*3/2))
        if ((ratio>20000 && rtt>inflated)); then
          BAD_COUNT=$((BAD_COUNT+1)); GOOD_COUNT=0
          if ((BAD_COUNT>=3)); then next=$((CUR_KBIT*95/100)); reason='连续满载、RTT 膨胀和重传'; BAD_COUNT=0; fi
        elif ((ratio<=3000 && rtt<=inflated)); then
          GOOD_COUNT=$((GOOD_COUNT+1)); BAD_COUNT=0
          if ((GOOD_COUNT>=3)); then next=$((CUR_KBIT+CEIL_KBIT/100)); reason='连续满载且干净'; GOOD_COUNT=0; fi
        else BAD_COUNT=0; GOOD_COUNT=0; fi
      else BAD_COUNT=0; GOOD_COUNT=0; fi
    else BAD_COUNT=0; GOOD_COUNT=0; fi
  else BAD_COUNT=0; GOOD_COUNT=0; fi
  next=$(clamp "$next" "$FLOOR_KBIT" "$CEIL_KBIT")
  # tc 显示单位会自动变化；控制器只在实际速率与自己的状态一致时动作。
  local displayed
  displayed=$(awk -v v="$current" 'BEGIN {if(v~/^[0-9.]+[KMG]?bit$/){s=v;sub(/[KMG]?bit$/,"",s);if(v~/Gbit$/)s*=1000000;else if(v~/Mbit$/)s*=1000;else if(v!~/Kbit$/)s/=1000;printf "%.0f",s}}')
  [[ $displayed == "$CUR_KBIT" ]] || { warn "实际限速已被其他操作改变，控制器停止本轮调整；请重新应用策略"; return 0; }
  if ((next!=CUR_KBIT)); then
    tc qdisc change dev "$IFACE" root cake bandwidth "${next}Kbit"
    info "${CUR_KBIT} → ${next} Kbit：$reason"; CUR_KBIT=$next
  fi
  tmp=$(mktemp "$STATE_DIR/adapt.XXXXXX")
  printf 'CUR_KBIT=%s\nCEIL_KBIT=%s\nFLOOR_KBIT=%s\nLAST_BYTES=%s\nLAST_OUT=%s\nLAST_RETR=%s\nLAST_TS=%s\nBAD_COUNT=%s\nGOOD_COUNT=%s\n' "$CUR_KBIT" "$CEIL_KBIT" "$FLOOR_KBIT" "$bytes" "$out" "$retr" "$now" "$BAD_COUNT" "$GOOD_COUNT" > "$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$ADAPT_STATE_FILE"
}

verify_sysctl() {
  local line key value actual
  while IFS= read -r line; do
    [[ $line =~ ^([a-zA-Z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    value=${value%%#*}; value=${value%%;*}
    value=$(awk '{$1=$1;print}' <<< "$value"); actual=$(sysctl -n "$key" | awk '{$1=$1;print}')
    [[ $value == "$actual" ]] || { warn "$key 实际值与计划不一致"; return 1; }
  done < "$CONFIG_FILE"
}
verify_qdisc() {
  local lines parent observed
  lines=$(tc qdisc show dev "$IFACE")
  if ((KEEP_MQ)); then
    [[ $(awk '$4=="root"{print $2;exit}' <<< "$lines") == mq ]] || return 1
    for parent in "${MQ_PARENTS[@]}"; do
      observed=$(awk -v p="$parent" '$4=="parent"&&$5==p{print $2;exit}' <<< "$lines")
      [[ $observed == "$QDISC" ]] || return 1
    done
  else [[ $(awk '$4=="root"{print $2;exit}' <<< "$lines") == "$QDISC" ]] || return 1; fi
}

apply_config() {
  local path key value tmp
  lock_mutation
  [[ -r $SELF_PATH && -f $SELF_PATH ]] || die "请保存为本地脚本后运行"
  [[ ! -L $STATE_DIR ]] || die "状态目录不能是符号链接"
  TXN_DIR=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).XXXXXX")
  printf 'v%s\n' "$VERSION" > "$TXN_DIR/version"
  managed_paths > "$TXN_DIR/manifest"
  while IFS= read -r path; do backup_file "$path" "$TXN_DIR"; done < "$TXN_DIR/manifest"
  snapshot_services
  prepare_rps
  remember_live_qdisc "$TXN_DIR"; snapshot_nic "$TXN_DIR"
  collect_carry_lines
  tmp=$TXN_DIR/config.new; emit_config > "$tmp"
  mapfile -t SYSCTL_KEYS < <(awk -F= '/^[a-zA-Z0-9_.]+[[:space:]]*=/{gsub(/[[:space:]]/,"",$1);print $1}' "$tmp")
  : > "$TXN_DIR/sysctl.before"
  for key in "${SYSCTL_KEYS[@]}"; do value=$(sysctl -n "$key"); printf '%s\t%s\n' "$key" "$value" >> "$TXN_DIR/sysctl.before"; done
  find_conflicts
  if ((${#CONFLICT_FILES[@]})) && ((RESOLVE_CONFLICTS==0)); then die "发现重复配置，请用 --resolve-conflicts 仅注释重复行：${CONFLICT_FILES[*]}"; fi
  for path in "${CONFLICT_FILES[@]}"; do
    printf '%s\n' "$path" >> "$TXN_DIR/manifest"; backup_file "$path" "$TXN_DIR"
  done
  [[ ! -r $BACKUP_ROOT/latest ]] || cp "$BACKUP_ROOT/latest" "$TXN_DIR/previous.latest"
  TXN_ACTIVE=1
  trap rollback_on_exit EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM
  stop_managed_services
  if [[ $CC_REQUEST != keep && $CC == bbr ]]; then
    if ! cc_available bbr; then try_module tcp_bbr; fi
    if ! cc_available bbr; then
      ((CC_EXPLICIT==0)) || die "当前内核无法加载 BBR"
      CC=$(sysctl -n net.ipv4.tcp_congestion_control); warn "BBR 不可用，保留 $CC"
    fi
  elif [[ $CC_REQUEST != keep ]] && ! cc_available "$CC"; then die "拥塞控制 $CC 不可用"; fi
  comment_conflicts
  apply_live_qdisc || die "队列应用失败"
  emit_config > "$tmp"
  install -D -m 0644 "$tmp" "$CONFIG_FILE"
  # 逐键验证：内核明确拒绝时回滚，不把“文件写成功”当作已生效。
  while IFS= read -r path; do
    [[ $path =~ ^([a-zA-Z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    value=${value%%#*}; value=${value%%;*}
    sysctl -q -w "$key=$value"
  done < "$CONFIG_FILE"
  apply_rps; tune_nic_offloads
  install -d -m 0755 "$(dirname "$MODULE_FILE")"
  { [[ $CC != bbr ]] || printf '%s\n' tcp_bbr; printf 'sch_%s\n' "$QDISC"; } > "$MODULE_FILE"
  install -d -m 0700 "$STATE_DIR"
  install_persistence
  verify_sysctl || die "sysctl 实际值验证失败"
  verify_qdisc || die "队列实际值验证失败"
  if ((ADAPT && PERSISTENCE_AVAILABLE)); then
    # flock 由本次应用持有；timer 即使立即触发也不会并发修改。
    systemctl start "$ADAPT_TIMER_NAME"
  fi
  printf '%s\n' "$TXN_DIR" > "$BACKUP_ROOT/latest"
  [[ -r $BACKUP_ROOT/initial-v3.4 ]] || printf '%s\n' "$TXN_DIR" > "$BACKUP_ROOT/initial-v3.4"
  TXN_ACTIVE=0; trap - EXIT INT TERM
  ok "已应用：$CC + $QDISC；整形 ${SHAPE_MBPS:-关闭}${SHAPE_MBPS:+ Mbps}；mq:$KEEP_MQ"
  say "备份：$TXN_DIR"
  info "新建连接后再测试；被动连接可能继承旧监听 socket 的拥塞控制，需重启相应服务后用 ss -tin 确认"
  info "旧版已生效但本版不再管理的参数会保持运行值，重启后重新初始化"
}

restore_latest() {
  local backup
  lock_mutation
  [[ -r $BACKUP_ROOT/latest ]] || die "没有本版本的最近备份"
  backup=$(<"$BACKUP_ROOT/latest")
  [[ $backup == "$BACKUP_ROOT/"* && -d $backup ]] || die "备份记录无效"
  if ! confirm "恢复上次应用前的运行值、队列和配置？"; then return 0; fi
  restore_from "$backup" || die "恢复有失败项，请检查上方输出"
  if [[ -r $backup/previous.latest ]]; then cp "$backup/previous.latest" "$BACKUP_ROOT/latest"; else rm -f "$BACKUP_ROOT/latest"; fi
  ok "已恢复修改前状态"
}
uninstall_config() {
  local backup
  lock_mutation
  [[ -r $BACKUP_ROOT/initial-v3.4 ]] || die "没有 v3.4 初始快照，不执行不完整卸载"
  backup=$(<"$BACKUP_ROOT/initial-v3.4")
  [[ $backup == "$BACKUP_ROOT/"* && -d $backup ]] || die "初始快照无效"
  if ! confirm "恢复首次使用 v3.4 前的完整状态？"; then return 0; fi
  restore_from "$backup" || die "卸载恢复有失败项"
  rm -f "$BACKUP_ROOT/latest" "$BACKUP_ROOT/initial-v3.4"
  ok "已恢复首次使用本版本前的状态，备份保留"
}

status() {
  local key
  say "TCP Tune $VERSION / $(uname -r) / $(getconf _NPROCESSORS_ONLN) CPU / $(detect_memory_mib) MiB effective"
  for key in net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem net.ipv4.tcp_limit_output_bytes; do
    printf '%s: %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || printf unsupported)"
  done
  if command -v tc >/dev/null 2>&1; then tc -s -d qdisc show; fi
  if has_systemd; then systemctl is-enabled "$QDISC_SERVICE_NAME" "$ADAPT_TIMER_NAME" 2>/dev/null || true; fi
  if [[ -r $ADAPT_STATE_FILE ]]; then grep -E '^(CUR_KBIT|CEIL_KBIT|FLOOR_KBIT)=' "$ADAPT_STATE_FILE"; fi
  info "以上算法默认值不能证明已有连接的算法；测速期间用 ss -tin 检查实际连接"
}
prompt_default() { local answer; read -r -p "$1 [$2]: " answer; printf '%s' "${answer:-$2}"; }
main_menu() {
  local choice
  say "TCP Tune $VERSION：通用代理服务器调优"
  say '1) 交互优化  2) 当前状态  3) 恢复上次修改  4) 卸载本版本  5) 帮助  0) 退出'
  choice=$(prompt_default '请选择' 1)
  case $choice in
    1) wizard;; 2) status;; 3) restore_latest;; 4) uninstall_config;;
    5) usage;; 0) info '已退出';; *) die '无效选项';;
  esac
}
wizard() {
  require_root
  say "TCP Tune $VERSION：通用代理服务器向导"
  info "默认 FQ / 不整形；请填实际方向的有效带宽和业务 RTT"
  LOCAL_MBPS=$(prompt_default '本地有效带宽 Mbps' 1000)
  SERVER_MBPS=$(prompt_default '服务器有效带宽 Mbps' 1000)
  RTT_HOST=$(prompt_default '实际客户端/业务 RTT 目标（留空改为手动输入）' '')
  if [[ -n $RTT_HOST ]]; then measure_rtt; else RTT_MS=$(prompt_default '实际业务 RTT ms' 50); fi
  IFACE=$(prompt_default '出口网卡' auto)
  QDISC_REQUEST=$(prompt_default '队列 auto/fq/fq_codel/fq_pie/cake' auto)
  SHAPE_REQUEST=$(prompt_default '整形 off/auto/固定Mbps/adapt（实验）' off)
  TUNE_RPS=$(prompt_default 'RPS keep/auto/on/off' keep)
  RESOLVE_CONFLICTS=1
  detect_interface; validate_inputs; select_congestion_control; calculate; prepare_rps; preview_config
  if ! confirm '应用以上策略（重复配置只注释对应键）？'; then info '已取消'; return 0; fi
  apply_config
}
main() {
  parse_args "$@"
  case $ACTION in help|-h|--help) usage; return 0;; --version|version) say "$VERSION"; return 0;; esac
  [[ $(uname -s) == Linux ]] || die "仅支持 Linux"
  case $ACTION in
    preview|apply)
      if ! command -v ip >/dev/null 2>&1 || ! command -v sysctl >/dev/null 2>&1; then die "需要 iproute2 和 procps"; fi
      [[ -z $RTT_HOST ]] || measure_rtt
      detect_interface; validate_inputs; select_congestion_control; calculate; prepare_rps; preview_config
      if [[ $ACTION == apply ]]; then
        command -v tc >/dev/null 2>&1 || die "需要 iproute2 的 tc"
        if ! confirm '确认应用？'; then info '已取消'; return 0; fi
        apply_config
      fi;;
    wizard) wizard;;
    '') if [[ -t 0 ]]; then main_menu; else usage; fi;;
    status) status;; rtt) [[ -n $RTT_HOST ]] || die "需 --rtt-host"; measure_rtt;;
    restore) restore_latest;; uninstall) uninstall_config;;
    replay) replay;; adaptive) adaptive;; *) die "未知操作：$ACTION";;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
