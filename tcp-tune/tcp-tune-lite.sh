#!/usr/bin/env bash
# tcp-tune-lite v1.2.0 — BBR + FQ/FQ-PIE + BDP-based TCP buffer ceilings
# Based on poiiwe/shells tcp-tune_v3.6.2.sh. License: MIT.
# Changes only six sysctl keys; keeps initial TCP buffers and tcp_mem unchanged.
set -Eeuo pipefail

VERSION=1.2.0
CONFIG=/etc/sysctl.d/99-tcp-tune-lite.conf
RUNTIME=/usr/local/libexec/tcp-tune-lite-qdisc
UNIT=/etc/systemd/system/tcp-tune-lite-qdisc.service
SERVICE=tcp-tune-lite-qdisc.service
STATE=/var/lib/tcp-tune-lite/settings.conf
BACKUPS=/var/backups/tcp-tune-lite
LOCK=/run/lock/tcp-tune-lite.lock
SYS_NET=/sys/class/net
KEYS=(net.ipv4.tcp_congestion_control net.core.default_qdisc
      net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem)
ACTION=menu QDISC=fq IFACE=auto LOCAL_MBPS= SERVER_MBPS= RTT_MS= MEMORY_MIB=
BUFFER_PROFILE=aggressive DIAG_PORT= SAMPLE_SECONDS=10 DIAG_OPTIONS=0
RTT_HOST= RTT_LINE= RTT_SOURCE=manual RTT_EXPLICIT=0
RTT_MOBILE_HOST=120.222.50.77 RTT_TELECOM_HOST=60.235.1.202
RTT_AVG_MS= RTT_JITTER_MS= RTT_RECEIVED= RTT_LOSS_PCT=
YES=0 DRY_RUN=0 ACTIVE=0 SNAPSHOT=

say() { printf '%s\n' "$*"; }
fail() {
  say "错误：$*" >&2
  if ((ACTIVE)); then rollback 1; fi
  exit 1
}
usage() {
  cat <<'EOF'
tcp-tune-lite — 仅 BBR、FQ/FQ-PIE 和 TCP 缓冲上限

sudo bash tcp-tune-lite.sh                  # 完整菜单
bash tcp-tune-lite.sh preview --mbps 500 --rtt-ms 260
sudo bash tcp-tune-lite.sh apply --mbps 500 --rtt-ms 260 --qdisc fq
sudo bash tcp-tune-lite.sh apply --mbps 1000 --rtt-line telecom --yes
sudo bash tcp-tune-lite.sh switch --qdisc fq_pie --yes
bash tcp-tune-lite.sh status
bash tcp-tune-lite.sh rtt --rtt-line mobile
bash tcp-tune-lite.sh diagnose --test-port 5858 --sample-seconds 10
sudo bash tcp-tune-lite.sh switch --buffer-profile balanced  # 对照旧缓冲策略
sudo bash tcp-tune-lite.sh restore          # 撤销最近一次应用
sudo bash tcp-tune-lite.sh uninstall        # 恢复首次应用前的设置

--mbps N            本地/服务器带宽都设为 N Mbps
--local-mbps N      本地带宽；与 --server-mbps 配合，取两者较小值
--server-mbps N     服务器带宽
--rtt-ms N          手动设置实际业务路径 RTT；跳过 ping
--rtt-line LINE     mobile（移动）| telecom（电信）；自动 ping 5 次
--rtt-host HOST     自定义 IP/域名；与 --rtt-ms / --rtt-line 三选一
--qdisc fq|fq_pie   默认 fq；拥塞算法固定为 BBR
--interface NAME   默认检测出口网卡
--memory-mib N     缓冲预算内存；默认 MemTotal，不能超过实际内存
--buffer-profile P aggressive（默认）| balanced（上一版的缓冲策略）
--test-port N      diagnose 专用：只看本机源/目标端口 N
--sample-seconds N diagnose 专用：采样 1–60 秒，默认 10
--yes              跳过应用/恢复确认
--dry-run          只预览，不修改任何配置
--version          显示版本
--help             显示帮助

BDP = min(本地,服务器) × RTT × 125 字节。
aggressive：6×BDP，上限 min(预算内存/8, 256 MiB)。
balanced：4×BDP，上限 min(预算内存/16, 256 MiB)。
向上取整到 MiB，通常至少 1 MiB；初始缓冲保持原值。
这是上限，不是预分配内存，也不是保证达到的接收窗口或速度。
扩大上限主要消除缓冲瓶颈，不改变 BBR 发送增益，也不保证重传降低。
diagnose 只读本机发送统计，不自动限速或改参数；可配合 restore 对照。
已有上限可能被调低；将按该规则统一设置，并保留原值备份。
带宽请填可信链路容量，不要把当前低单流速度当作容量上限。
交互回车采用默认值：首次 1000 Mbps、移动 RTT、aggressive、FQ、自动出口。
RTT 测试：移动 120.222.50.77 / 电信 60.235.1.202；平均值向上取整到 10 ms。
测试目标用于估计 RTT，不会切换出口线路；最好使用实际客户端地址。
ICMP 无响应时可换目标或手动输入；不会静默使用猜测值。
switch 未指定 RTT 时复用已保存结果，不重复 ping。
如果旧版 tcp-tune 仍在管理配置，请先用旧版 uninstall 完成迁移。
应用后请新建连接；旧监听 socket 仍用旧算法时需重启相应服务。
EOF
}
uint() {
  local value=$1 maximum=$2
  [[ "$value" =~ ^[0-9]{1,9}$ ]] || return 1
  value=$((10#$value))
  ((value > 0 && value <= maximum)) || return 1
  printf '%s' "$value"
}
load_settings() {
  [[ -r "$STATE" ]] || return 1
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      LOCAL_MBPS|SERVER_MBPS|RTT_MS|QDISC|IFACE|BUFFER_PROFILE|RTT_HOST|RTT_LINE) printf -v "$key" '%s' "$value" ;;
    esac
  done < "$STATE"
  RTT_SOURCE=saved
}
parse() {
  local rtt_option=
  RTT_EXPLICIT=0
  if (($#)) && [[ "$1" != --* ]]; then ACTION=$1; shift; fi
  if [[ "$ACTION" == switch ]]; then load_settings || fail "请先 apply，再使用 switch"; fi
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --version|-V) say "tcp-tune-lite v$VERSION"; exit 0 ;;
      --yes|-y) YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --mbps|--local-mbps|--server-mbps|--rtt-ms|--rtt-host|--rtt-line|--qdisc|--interface|--memory-mib|--buffer-profile|--test-port|--sample-seconds)
        (($# >= 2)) || fail "$1 缺少参数"
        case "$1" in --rtt-ms|--rtt-host|--rtt-line)
          [[ -z "$rtt_option" || "$rtt_option" == "$1" ]] || fail "--rtt-ms / --rtt-host / --rtt-line 只能选择一个"
          rtt_option=$1
          RTT_EXPLICIT=1; RTT_MS=; RTT_HOST=; RTT_LINE=; RTT_SOURCE=manual ;;
        esac
        case "$1" in
          --mbps) LOCAL_MBPS=$2; SERVER_MBPS=$2 ;;
          --local-mbps) LOCAL_MBPS=$2 ;;
          --server-mbps) SERVER_MBPS=$2 ;;
          --rtt-ms) RTT_MS=$2 ;;
          --rtt-host) RTT_HOST=$2 ;;
          --rtt-line) RTT_LINE=$2 ;;
          --qdisc) QDISC=$2 ;;
          --interface) IFACE=$2 ;;
          --memory-mib) MEMORY_MIB=$2 ;;
          --buffer-profile) BUFFER_PROFILE=$2 ;;
          --test-port) DIAG_PORT=$(uint "$2" 65535) || fail "端口必须是 1–65535 的整数"; DIAG_OPTIONS=1 ;;
          --sample-seconds) SAMPLE_SECONDS=$(uint "$2" 60) || fail "采样时间必须是 1–60 的整数"; DIAG_OPTIONS=1 ;;
        esac
        shift 2 ;;
      *) fail "未知参数：$1" ;;
    esac
  done
  case "$ACTION" in menu|preview|apply|switch|status|rtt|diagnose|restore|uninstall) ;; *) fail "未知操作：$ACTION" ;; esac
  if ((RTT_EXPLICIT)); then
    case "$ACTION" in menu|preview|apply|switch|rtt) ;; *) fail "RTT 参数只适用于 menu/preview/apply/switch/rtt" ;; esac
  fi
  case "$RTT_LINE" in
    "") ;;
    mobile) RTT_HOST=$RTT_MOBILE_HOST ;;
    telecom) RTT_HOST=$RTT_TELECOM_HOST ;;
    *) fail "--rtt-line 只支持 mobile 或 telecom" ;;
  esac
  [[ "$ACTION" != rtt || -z "$RTT_MS" ]] || fail "rtt 操作用于测量，请使用 --rtt-line 或 --rtt-host"
  if ((DIAG_OPTIONS)) && [[ "$ACTION" != diagnose ]]; then
    fail "--test-port / --sample-seconds 仅用于 diagnose"
  fi
  if ((DRY_RUN)); then
    case "$ACTION" in preview|apply|switch) ;; *) fail "--dry-run 只适用于 preview/apply/switch" ;; esac
  fi
}
detect_interface() {
  if [[ "$IFACE" == auto ]]; then
    IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -z "$IFACE" ]]; then
      IFACE=$(ip -6 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    fi
  fi
  [[ "$IFACE" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.:@-]*$ && -d "$SYS_NET/$IFACE" ]] || fail "出口网卡无效，请指定 --interface"
}
prepare() {
  [[ "$(uname -s)" == Linux ]] || fail "仅支持 Linux"
  LOCAL_MBPS=$(uint "$LOCAL_MBPS" 100000) || fail "本地带宽必须是 1–100000 的整数"
  SERVER_MBPS=$(uint "$SERVER_MBPS" 100000) || fail "服务器带宽必须是 1–100000 的整数"
  RTT_MS=$(uint "$RTT_MS" 10000) || fail "RTT 必须是 1–10000 的整数毫秒"
  [[ "$QDISC" == fq || "$QDISC" == fq_pie ]] || fail "队列只支持 fq 或 fq_pie"
  [[ "$BUFFER_PROFILE" == aggressive || "$BUFFER_PROFILE" == balanced ]] || fail "缓冲策略只支持 aggressive 或 balanced"
  local actual
  actual=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  MEMORY_MIB=$(uint "${MEMORY_MIB:-$actual}" 1048576) || fail "内存预算无效"
  ((MEMORY_MIB >= 64 && MEMORY_MIB <= actual)) || fail "内存预算须至少 64 MiB，且不能大于实际内存"
  read -r RMIN RDEFAULT _ <<< "$(sysctl -n net.ipv4.tcp_rmem)"
  read -r WMIN WDEFAULT _ <<< "$(sysctl -n net.ipv4.tcp_wmem)"
  local value
  for value in "$RMIN" "$RDEFAULT" "$WMIN" "$WDEFAULT"; do
    [[ "$value" =~ ^[0-9]+$ ]] || fail "无法读取 TCP 初始缓冲"
  done
  calculate
  detect_interface
}
calculate() {
  BOTTLENECK=$LOCAL_MBPS
  ((SERVER_MBPS >= BOTTLENECK)) || BOTTLENECK=$SERVER_MBPS
  BDP=$((BOTTLENECK * RTT_MS * 125))
  if [[ "$BUFFER_PROFILE" == aggressive ]]; then BDP_MULT=6; MEMORY_DIV=8
  else BDP_MULT=4; MEMORY_DIV=16; fi
  TARGET=$((BDP * BDP_MULT))
  CAP=$((MEMORY_MIB * 1048576 / MEMORY_DIV))
  ((CAP <= 268435456)) || CAP=268435456
  BUFFER=$(((TARGET + 1048575) / 1048576 * 1048576))
  ((BUFFER >= 1048576)) || BUFFER=1048576
  ((BUFFER <= CAP)) || BUFFER=$CAP
  # Never create a max smaller than a retained minimum/default.
  local initial
  for initial in "$RMIN" "$RDEFAULT" "$WMIN" "$WDEFAULT"; do
    ((initial <= CAP)) || fail "现有初始缓冲超过预算上限，请先检查旧配置"
    ((BUFFER >= initial)) || BUFFER=$initial
  done
}
emit_config() {
  printf '# tcp-tune-lite v%s; %s Mbps; RTT %s ms; BDP %s bytes; buffer=%s\n' "$VERSION" "$BOTTLENECK" "$RTT_MS" "$BDP" "$BUFFER_PROFILE"
  printf 'net.ipv4.tcp_congestion_control = bbr\nnet.core.default_qdisc = %s\n' "$QDISC"
  printf 'net.core.rmem_max = %s\nnet.core.wmem_max = %s\n' "$BUFFER" "$BUFFER"
  printf 'net.ipv4.tcp_rmem = %s %s %s\n' "$RMIN" "$RDEFAULT" "$BUFFER"
  printf 'net.ipv4.tcp_wmem = %s %s %s\n' "$WMIN" "$WDEFAULT" "$BUFFER"
}
preview() {
  say "BBR + $QDISC；不整形；网卡 $IFACE"
  say "瓶颈 $BOTTLENECK Mbps / RTT $RTT_MS ms / 内存预算 $MEMORY_MIB MiB / 缓冲策略 $BUFFER_PROFILE"
  if [[ "$RTT_SOURCE" == ping ]]; then
    say "RTT 来源：${RTT_HOST}；平均 ${RTT_AVG_MS} ms；成功 ${RTT_RECEIVED}/5"
  elif [[ "$RTT_SOURCE" == saved ]]; then say "RTT 来源：复用已保存结果 $RTT_MS ms"
  else say "RTT 来源：手动输入"; fi
  awk -v b="$BDP" -v t="$TARGET" -v c="$CAP" -v n="$BUFFER" -v m="$BDP_MULT" \
    'BEGIN {printf "BDP %.2f MiB；%s×BDP %.2f MiB；预算上限 %.2f MiB；最终缓冲 %.2f MiB\n",b/1048576,m,t/1048576,c/1048576,n/1048576}'
  ((TARGET <= CAP)) || say "提示：缓冲受内存预算限制，不保证满足目标吞吐。"
  emit_config
}
confirm() {
  ((YES)) && return 0
  [[ -t 0 ]] || fail "非交互执行需加 --yes"
  local answer
  read -r -p "$1 [Y/n]：" answer || return 1
  [[ -z "$answer" || "$answer" == y || "$answer" == Y ]]
}
require_root() { ((EUID == 0)) || fail "应用/恢复需要 root，请使用 sudo"; }
systemd_ok() { command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; }
lock_mutations() {
  install -d -m 0755 "$(dirname "$LOCK")"
  exec 9>"$LOCK"
  flock -x 9
}
sysctl_files() {
  local file
  for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
              /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [[ ! -f "$file" ]] || printf '%s\n' "$file"
  done
}
check_conflicts() {
  local file hits name own LC_ALL=C
  own=$(basename "$CONFIG")
  while IFS= read -r file; do
    [[ "$(readlink -f "$file")" != "$(readlink -f "$CONFIG")" ]] || continue
    hits=$(awk -F= '
      /^[[:space:]]*[#;]/ {next}
      NF>=2 {k=$1; gsub(/[[:space:]]/,"",k); sub(/^-/,"",k); gsub(/\//,".",k)
      if(k ~ /^(net\.ipv4\.tcp_congestion_control|net\.core\.(default_qdisc|rmem_max|wmem_max)|net\.ipv4\.tcp_[rw]mem)$/) print k}' "$file")
    [[ -n "$hits" ]] || continue
    name=$(basename "$file")
    # sysctl.d loads filenames lexicographically; /etc masks same-name vendor files.
    # /etc/sysctl.conf can be applied last by procps, so keep that case conservative.
    if [[ "$file" == /etc/sysctl.conf || "$name" > "$own" ]]; then
      fail "$file 包含后置调优参数，请先用原工具卸载或手动整理；lite 不删除其他配置"
    fi
    say "提示：$file 的同名参数将由 lite 配置覆盖。" >&2
  done < <(sysctl_files)
  local legacy
  for legacy in tcp-tune-qdisc.service tcp-tune-runtime.service tcp-tune-adapt.timer; do
    if [[ -e "/etc/systemd/system/$legacy" ]] || { systemd_ok && { systemctl is-enabled "$legacy" >/dev/null 2>&1 || systemctl is-active "$legacy" >/dev/null 2>&1; }; }; then
      fail "发现旧版 $legacy，请先用旧版 tcp-tune uninstall"
    fi
  done
  for file in net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling; do
    [[ "$(sysctl -n "$file")" == 1 ]] || fail "$file 未开启，请先检查旧配置；lite 不接管这个参数"
  done
}
# Fresh nonzero handles avoid deleting handle 0 and retain no old queue options.
fresh_qdisc_handle() {
  local iface=$1 listing handle candidate major
  local -A used=()
  listing=$(tc qdisc show dev "$iface") || return 1
  while read -r handle; do
    [[ "$handle" =~ ^[0-9a-fA-F]{1,4}:$ ]] || return 1
    major=$((16#${handle%:})); used["$major"]=1
  done < <(awk '$1=="qdisc" {print $3}' <<< "$listing")
  for ((candidate=32768; candidate<65535; candidate++)); do
    if [[ ! -v "used[$candidate]" ]]; then printf -v QUEUE_HANDLE '%x:' "$candidate"; return 0; fi
  done
  return 1
}
# Keep mq topology instead of serializing all TX queues.
set_queues() {
  local listing kind handle parent root_kind root_handle target
  listing=$(tc qdisc show dev "$IFACE") || return 1
  root_kind=$(awk '$4=="root" {print $2; exit}' <<< "$listing")
  root_handle=$(awk '$4=="root" {print $3; exit}' <<< "$listing")
  [[ -n "$root_kind" ]] || { printf '%s\n' "无法识别出口根队列" >&2; return 1; }
  local targets=() args=("$QDISC")
  if [[ "$root_kind" == mq ]]; then
    if [[ "$root_handle" == 0: ]]; then
      fresh_qdisc_handle "$IFACE" || return 1
      tc qdisc replace dev "$IFACE" root handle "$QUEUE_HANDLE" mq || return 1
      listing=$(tc qdisc show dev "$IFACE") || return 1
    fi
    while read -r _ kind handle target parent _; do
      if [[ "$target" == parent && "$kind" != ingress && "$kind" != clsact ]]; then
        [[ "$parent" =~ ^[a-fA-F0-9]*:[a-fA-F0-9]+$ ]] || return 1
        targets+=("$parent")
      fi
    done <<< "$listing"
    ((${#targets[@]})) || return 1
  else
    targets=(root)
  fi
  # Explicitly clear FQ's old per-flow maxrate; UINT32_MAX bytes/sec is unlimited.
  [[ "$QDISC" != fq ]] || args+=(pacing maxrate 34359738360bit)
  for target in "${targets[@]}"; do
    fresh_qdisc_handle "$IFACE" || return 1
    if [[ "$target" == root ]]; then
      tc qdisc replace dev "$IFACE" root handle "$QUEUE_HANDLE" "${args[@]}" || return 1
    else
      tc qdisc replace dev "$IFACE" parent "$target" handle "$QUEUE_HANDLE" "${args[@]}" || return 1
    fi
  done
}
qdisc_options() {
  local kind=$1 tail=$2 token value count i
  local words=()
  read -r -a words <<< "$tail"
  REPLAY_ARGS=("$kind")
  while ((${#words[@]})); do
    token=${words[0]}; words=("${words[@]:1}")
    case "$token" in
      refcnt) ((${#words[@]})) || return 1; words=("${words[@]:1}") ;;
      bands)
        [[ "$kind" == fq && ${words[0]:-} == 3 && ${words[1]:-} == priomap ]] || return 1
        ((${#words[@]} >= 18)) || return 1
        REPLAY_ARGS+=(bands 3 priomap)
        for ((i=2;i<18;i++)); do
          [[ "${words[$i]}" =~ ^[0-2]$ ]] || return 1
          REPLAY_ARGS+=("${words[$i]}")
        done
        words=("${words[@]:18}") ;;
      weights)
        [[ "$kind" == fq ]] && ((${#words[@]} >= 3)) || return 1
        REPLAY_ARGS+=(weights)
        for ((i=0;i<3;i++)); do
          [[ "${words[$i]}" =~ ^[0-9]{1,10}$ ]] || return 1
          REPLAY_ARGS+=("${words[$i]}")
        done
        words=("${words[@]:3}") ;;
      limit|flow_limit|buckets|orphan_mask|quantum|initial_quantum|low_rate_threshold|refill_delay|timer_slack|maxrate|horizon|offload_horizon|ce_threshold|flows|target|interval|memory_limit|drop_batch|tupdate|alpha|beta|ecn_prob)
        ((${#words[@]})) || return 1
        value=${words[0]}; words=("${words[@]:1}")
        [[ "$value" =~ ^[a-zA-Z0-9.,/%:-]+$ ]] || return 1
        case "$token" in
          limit|flow_limit) value=${value%p}; [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
          quantum|initial_quantum) value=${value%b}; [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
        esac
        REPLAY_ARGS+=("$token" "$value") ;;
      pacing|nopacing|horizon_drop|horizon_cap|ecn|noecn|bytemode|nobytemode|dq_rate_estimator|no_dq_rate_estimator) REPLAY_ARGS+=("$token") ;;
      *) return 1 ;;
    esac
  done
}
snapshot_qdisc() {
  local directory=$1 line kind handle placement tail location classes filters
  tc qdisc show dev "$IFACE" > "$directory/qdisc.txt"
  classes=$(tc class show dev "$IFACE")
  filters=$(tc filter show dev "$IFACE")
  [[ -z "$filters" && -z "$(awk '$2!="mq" {print}' <<< "$classes")" ]] || fail "现有出口含自定义 class/filter，lite 不接管"
  write_qdisc_replay "$directory"
}
write_qdisc_replay() {
  local directory=$1 line kind handle placement tail location
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    declare -f fresh_qdisc_handle
  } > "$directory/qdisc.restore"
  local roots=0
  while IFS= read -r line; do
    read -r _ kind handle placement tail <<< "$line"
    [[ "$kind" != ingress && "$kind" != clsact ]] || continue
    location=root
    if [[ "$placement" == parent ]]; then read -r location tail <<< "$tail"
    elif [[ "$placement" == root ]]; then roots=$((roots+1))
    else fail "无法回放现有队列：$line"; fi
    case "$kind" in
      noqueue)
        [[ "$location" == root ]] || fail "不支持 noqueue 子队列"
        printf 'h=$(tc qdisc show dev %q | awk '\''$4=="root" {print $3; exit}'\'')\n' "$IFACE" >> "$directory/qdisc.restore"
        printf 'if [[ "$h" != 0: ]]; then tc qdisc del dev %q root; fi\n' "$IFACE" >> "$directory/qdisc.restore"
        continue ;;
      mq|pfifo_fast) REPLAY_ARGS=("$kind") ;;
      fq|fq_pie|fq_codel) qdisc_options "$kind" "$tail" || fail "无法完整恢复现有队列参数：$line" ;;
      *) fail "lite 不接管 $kind 队列，请先用原管理工具恢复普通队列" ;;
    esac
    printf 'fresh_qdisc_handle %q\n' "$IFACE" >> "$directory/qdisc.restore"
    if [[ "$location" == root ]]; then
      printf 'RESTORE_ROOT_HANDLE=$QUEUE_HANDLE\ntc qdisc replace dev %q root handle "$QUEUE_HANDLE" ' "$IFACE" >> "$directory/qdisc.restore"
    else
      [[ "$location" =~ ^[a-fA-F0-9]*:[a-fA-F0-9]+$ ]] || fail "无法验证原子队列标识"
      printf 'tc qdisc replace dev %q parent "${RESTORE_ROOT_HANDLE}%s" handle "$QUEUE_HANDLE" ' "$IFACE" "${location#*:}" >> "$directory/qdisc.restore"
    fi
    printf '%q ' "${REPLAY_ARGS[@]}" >> "$directory/qdisc.restore"
    printf '\n' >> "$directory/qdisc.restore"
  done < <(awk '$4=="root" {print; next} {other=other $0 "\n"} END {printf "%s",other}' "$directory/qdisc.txt")
  ((roots == 1)) || fail "无法识别唯一根队列"
}
managed_files() { printf '%s\n' "$CONFIG" "$RUNTIME" "$UNIT" "$STATE" "$BACKUPS/latest" "$BACKUPS/baseline"; }
capture() {
  install -d -m 0700 "$BACKUPS"
  SNAPSHOT=$(mktemp -d "$BACKUPS/$(date +%Y%m%d-%H%M%S).XXXXXX")
  local file key value
  managed_files > "$SNAPSHOT/files.list"
  while IFS= read -r file; do
    if [[ -e "$file" || -L "$file" ]]; then
      install -d -m 0700 "$(dirname "$SNAPSHOT$file")"
      cp -a -- "$file" "$SNAPSHOT$file"
    fi
  done < "$SNAPSHOT/files.list"
  for key in "${KEYS[@]}"; do
    value=$(sysctl -n "$key") || fail "无法备份 $key"
    [[ -n "$value" ]] || fail "无法备份 $key"
    printf '%s = %s\n' "$key" "$value"
  done > "$SNAPSHOT/sysctl.live"
  if systemd_ok; then
    systemctl is-enabled "$SERVICE" > "$SNAPSHOT/enabled" 2>/dev/null || true
    systemctl is-active "$SERVICE" > "$SNAPSHOT/active" 2>/dev/null || true
  fi
  snapshot_qdisc "$SNAPSHOT"
}
restore_from() {
  local directory=$1 file failed=0 enabled
  # Upgrade existing snapshots using recorded data, including v1.1 mq handle 0.
  [[ ! -r "$directory/qdisc.txt" ]] || write_qdisc_replay "$directory"
  if systemd_ok; then systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true; fi
  while IFS= read -r file; do
    # Backups are private root-owned data; restore only this tool's exact paths.
    managed_files | grep -Fxq -- "$file" || { failed=1; continue; }
    if [[ -e "$directory$file" || -L "$directory$file" ]]; then
      mkdir -p "$(dirname "$file")" && rm -f -- "$file" && cp -a -- "$directory$file" "$file" || failed=1
    else rm -f -- "$file" || failed=1; fi
  done < "$directory/files.list"
  sysctl -p "$directory/sysctl.live" >/dev/null || failed=1
  bash "$directory/qdisc.restore" || failed=1
  if systemd_ok; then
    systemctl daemon-reload || failed=1
    enabled=$(cat "$directory/enabled" 2>/dev/null || true)
    case "$enabled" in
      enabled) systemctl enable "$SERVICE" >/dev/null 2>&1 || failed=1 ;;
      enabled-runtime) systemctl enable --runtime "$SERVICE" >/dev/null 2>&1 || failed=1 ;;
    esac
    if [[ "$(cat "$directory/active" 2>/dev/null || true)" == active ]]; then
      systemctl start "$SERVICE" >/dev/null 2>&1 || failed=1
    fi
  fi
  ((failed == 0))
}
rollback() {
  local result=$1
  trap - ERR INT TERM HUP
  if ((ACTIVE)); then
    ACTIVE=0
    say "应用失败，正在恢复：$SNAPSHOT" >&2
    restore_from "$SNAPSHOT" || say "恢复不完整，请检查备份 $SNAPSHOT 和错误输出" >&2
  fi
  exit "$result"
}
install_persistence() {
  {
    printf '#!/bin/bash\nset -euo pipefail\nIFACE=%q\nQDISC=%q\n' "$IFACE" "$QDISC"
    printf 'exec 9>%q\nflock -n 9 || exit 0\n' "$LOCK"
    declare -f set_queues
    declare -f fresh_qdisc_handle
    printf '\nset_queues\n'
  } > "$RUNTIME"
  chmod 0755 "$RUNTIME"
  if systemd_ok; then
    cat > "$UNIT" <<EOF
[Unit]
Description=Restore tcp-tune-lite FQ/FQ-PIE queues
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RUNTIME
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
  else
    say "提示：未运行 systemd；sysctl 已持久化，队列重启后需手动重新应用。"
  fi
}
verify() {
  local key expected current
  local want=() got=()
  while IFS='=' read -r key expected; do
    [[ "$key" != \#* && -n "$expected" ]] || continue
    key=${key//[[:space:]]/}
    current=$(sysctl -n "$key") || return 1
    read -r -a want <<< "$expected"
    read -r -a got <<< "$current"
    [[ "${want[*]}" == "${got[*]}" ]] || return 1
  done < "$CONFIG"
  tc qdisc show dev "$IFACE" | awk -v q="$QDISC" '
    $2=="ingress" || $2=="clsact" {next}
    $4=="root" {root++; multi=($2=="mq"); if($2!=q && !multi) bad=1}
    $4=="parent" {leaf++; if($2!=q) bad=1}
    END {exit (root!=1 || bad || (multi && !leaf))}'
}
apply() {
  require_root
  command -v tc >/dev/null || fail "缺少 tc，请安装 iproute2"
  lock_mutations
  check_conflicts
  # Re-read under lock, so a waiting apply does not use stale defaults/snapshots.
  prepare
  capture
  ACTIVE=1
  trap 'rollback "$?"' ERR
  trap 'rollback 130' INT
  trap 'rollback 143' TERM
  trap 'rollback 129' HUP
  if command -v modprobe >/dev/null; then
    modprobe tcp_bbr 2>/dev/null || true
    modprobe "sch_$QDISC" 2>/dev/null || true
  fi
  [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]] || fail "BBR 未加载；请检查内核/模块"
  install -d -m 0755 "$(dirname "$CONFIG")" "$(dirname "$RUNTIME")" "$(dirname "$UNIT")" "$(dirname "$STATE")"
  emit_config > "$CONFIG"
  chmod 0644 "$CONFIG"
  sysctl -p "$CONFIG" >/dev/null
  set_queues
  install_persistence
  verify
  printf 'LOCAL_MBPS=%s\nSERVER_MBPS=%s\nRTT_MS=%s\nQDISC=%s\nIFACE=%s\nBUFFER_PROFILE=%s\n' "$LOCAL_MBPS" "$SERVER_MBPS" "$RTT_MS" "$QDISC" "$IFACE" "$BUFFER_PROFILE" > "$STATE"
  printf 'RTT_HOST=%s\nRTT_LINE=%s\n' "$RTT_HOST" "$RTT_LINE" >> "$STATE"
  chmod 0644 "$STATE"
  printf '%s\n' "$SNAPSHOT" > "$BACKUPS/latest"
  [[ -f "$BACKUPS/baseline" ]] || printf '%s\n' "$SNAPSHOT" > "$BACKUPS/baseline"
  ACTIVE=0
  trap - ERR INT TERM HUP
  exec 9>&-
  say "已应用 BBR + $QDISC；缓冲上限 $((BUFFER/1048576)) MiB。备份：$SNAPSHOT"
}
restore_action() {
  require_root
  local pointer directory label=最近一次应用
  pointer=$BACKUPS/latest
  if [[ "$ACTION" == uninstall ]]; then pointer=$BACKUPS/baseline; label=首次应用; fi
  confirm "恢复${label}前的 sysctl、队列和配置？" || return 0
  lock_mutations
  directory=$(realpath -e -- "$(cat "$pointer" 2>/dev/null)" 2>/dev/null) || fail "没有可用备份"
  [[ "$directory" == "$BACKUPS"/* && -f "$directory/files.list" ]] || fail "备份路径无效"
  restore_from "$directory" || fail "部分恢复失败，请检查 $directory"
  exec 9>&-
  say "已恢复：$directory"
}
status() {
  say "tcp-tune-lite v$VERSION / 内核 $(uname -r)"
  local key
  for key in "${KEYS[@]}" net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling; do
    printf '%s = %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || printf unavailable)"
  done
  [[ ! -r "$STATE" ]] || cat "$STATE"
  if [[ "$IFACE" == auto && -r "$STATE" ]]; then
    IFACE=$(sed -n 's/^IFACE=//p' "$STATE")
  fi
  if [[ "$IFACE" == auto ]]; then
    local detected
    detected=$(detect_interface 2>/dev/null; printf '%s' "$IFACE") || detected=
    IFACE=${detected:-auto}
  fi
  if [[ "$IFACE" != auto && "$IFACE" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.:@-]*$ ]] && command -v tc >/dev/null; then
    tc -s qdisc show dev "$IFACE" || true
  fi
  if systemd_ok; then
    say "队列开机恢复：$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  fi
}
# ss counters are cumulative per socket. Keep decimal text intact for subtraction
# in Bash, and use the socket cookie when available to avoid reusing a 4-tuple.
socket_counters() {
  local raw
  if [[ -n "$DIAG_PORT" ]]; then
    raw=$(ss -Htein state established "( sport = :$DIAG_PORT or dport = :$DIAG_PORT )") || return 1
  else raw=$(ss -Htein state established) || return 1; fi
  printf '%s\n' "$raw" | awk '
    $1=="ESTAB" || $1 ~ /^[0-9]+$/ {
      offset=($1=="ESTAB"); key=$(3+offset) ">" $(4+offset)
      for(i=1;i<=NF;i++) if($i ~ /^sk:/) key=key "|" $i
      next
    }
    key!="" {
      sent=""; retr="0"
      for(i=1;i<=NF;i++) {
        split($i,a,":")
        if(a[1]=="bytes_sent") sent=a[2]
        if(a[1]=="bytes_retrans") retr=a[2]
      }
      if(sent ~ /^[0-9]+$/ && retr ~ /^[0-9]+$/) printf "%s\t%s\t%s\n",key,sent,retr
    }'
}
diagnose() {
  command -v ss >/dev/null || fail "缺少 ss，请安装 iproute2"
  local before after started elapsed key old_sent old_retr new_sent new_retr
  local sent=0 retr=0 count=0 delta
  started=$(date +%s)
  before=$(socket_counters) || fail "无法读取 TCP 连接"
  say "采样 $SAMPLE_SECONDS 秒，请保持测速运行；端口：${DIAG_PORT:-全部 TCP 连接}"
  sleep "$SAMPLE_SECONDS"
  after=$(socket_counters) || fail "无法读取 TCP 连接"
  elapsed=$(($(date +%s) - started))
  ((elapsed > 0)) || elapsed=$SAMPLE_SECONDS
  while IFS=$'\t' read -r key old_sent old_retr new_sent new_retr; do
    [[ "$old_sent" =~ ^[0-9]{1,18}$ && "$old_retr" =~ ^[0-9]{1,18}$ && "$new_sent" =~ ^[0-9]{1,18}$ && "$new_retr" =~ ^[0-9]{1,18}$ ]] || continue
    old_sent=$((10#$old_sent)); old_retr=$((10#$old_retr))
    new_sent=$((10#$new_sent)); new_retr=$((10#$new_retr))
    ((new_sent >= old_sent && new_retr >= old_retr)) || continue
    delta=$((new_sent-old_sent))
    ((delta > 0)) || continue
    sent=$((sent+delta)); retr=$((retr+new_retr-old_retr)); count=$((count+1))
  done < <(awk -F '\t' '
    NR==FNR {if(NF==3) {s[$1]=$2; r[$1]=$3}; next}
    NF==3 && ($1 in s) {printf "%s\t%s\t%s\t%s\t%s\n",$1,s[$1],r[$1],$2,$3}' \
    <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  if ((sent == 0)); then
    say "没有可比较的发送样本；请检查端口、保持连接并在发送数据的一端运行。"
    return 0
  fi
  awk -v s="$sent" -v r="$retr" -v t="$elapsed" -v n="$count" 'BEGIN {
    printf "%s 条持续发送连接 / %s 秒；发送 %.2f MiB，重传 %.2f MiB\n",n,t,s/1048576,r/1048576
    printf "发送字节重传占比 %.3f%%；本机发送速率约 %.1f Mbps（含重传）\n",r*100/s,s*8/t/1000000
    if(r*100/s>=3) print "提示：重传占比达到 3%，建议对照 balanced 或 restore 后重测；3% 是复测提示阈值。"
  }'
  ((sent >= 16777216)) || say "提示：发送样本不足 16 MiB，请延长采样后再比较。"
  say "这里只统计两次采样都存在的本机 TCP 发送连接；新建/关闭的短连接可能漏记。"
  say "该占比不是线路丢包率；提高缓冲只有在原缓冲限制吞吐时才可能有效。"
}
prompt_number() {
  local label=$1 default=$2 maximum=$3 answer
  while true; do
    read -r -p "$label [$default]：" answer || return 1
    answer=${answer:-$default}
    if uint "$answer" "$maximum"; then return 0; fi
    say "请输入 1–$maximum 的整数。" >&2
  done
}
measure_rtt() {
  local target=$1 output measured rounded received avg jitter loss ping_cmd=ping
  RTT_MS=; RTT_AVG_MS=; RTT_JITTER_MS=; RTT_RECEIVED=; RTT_LOSS_PCT=; RTT_SOURCE=manual
  if [[ -z "$target" || "$target" == -* || ! "$target" =~ ^[a-zA-Z0-9._:%-]+$ ]]; then
    say "RTT 目标无效：${target:-空}" >&2; return 1
  fi
  if [[ "$target" == *:* ]] && command -v ping6 >/dev/null; then ping_cmd=ping6; fi
  command -v "$ping_cmd" >/dev/null || { say "缺少 $ping_cmd，请安装 iputils-ping 或手动输入 RTT" >&2; return 1; }
  say "正在测试 $target：5 次 ping，单次超时 2 秒，总期限 15 秒。"
  output=$(LC_ALL=C "$ping_cmd" -n -c 5 -W 2 -w 15 "$target" 2>&1 || true)
  measured=$(awk '
    /(icmp_[sr]eq|seq)=/ && !/DUP!/ {
      if (match($0,/time[=<][[:space:]]*[0-9]+([.][0-9]+)?/)) {
        v=substr($0,RSTART,RLENGTH); sub(/^time[=<][[:space:]]*/,"",v)
        sum+=v; squares+=v*v; n++
      }
    }
    END {if(n>0) {
      avg=sum/n; variance=squares/n-avg*avg; if(variance<0) variance=0
      rounded=int(avg/10); if(avg>rounded*10) rounded++; rounded*=10
      if(rounded<10) rounded=10
      loss=(5-n)*20; if(loss<0) loss=0
      printf "%d:%d:%.3f:%.3f:%d",rounded,n,avg,sqrt(variance),loss
    }}' <<< "$output")
  if [[ -z "$measured" ]]; then
    say "$output" >&2; say "未获得 RTT；目标可能不回应 ICMP，也可能是 DNS/网络问题。" >&2; return 1
  fi
  IFS=: read -r rounded received avg jitter loss <<< "$measured"
  RTT_MS=$(uint "$rounded" 10000) || { say "测得 RTT 超出 1–10000 ms" >&2; return 1; }
  RTT_HOST=$target; RTT_SOURCE=ping; RTT_AVG_MS=$avg; RTT_JITTER_MS=$jitter
  RTT_RECEIVED=$received; RTT_LOSS_PCT=$loss
  say "RTT 测量：成功 $received/5，平均 ${avg} ms，抖动 ${jitter} ms，ICMP 丢包 ${loss}%。"
  say "用于缓冲计算：$RTT_MS ms（平均值向上取整到 10 ms）。"
  ((received >= 3)) || say "提示：成功样本少于 3 个，建议重测；ICMP 丢包不是 TCP 重传率。"
}
input_manual_rtt() {
  RTT_MS=$(prompt_number "实际路径 RTT ms（跳过 ping）" "${RTT_MS:-150}" 10000) || return 1
  RTT_HOST=; RTT_LINE=; RTT_SOURCE=manual
}
choose_rtt() {
  local default=1 choice recovery retry=0
  case "$RTT_HOST" in
    "$RTT_TELECOM_HOST") default=2 ;;
    "$RTT_MOBILE_HOST"|"") ;;
    *) default=3 ;;
  esac
  [[ -z "$RTT_MS" || -n "$RTT_HOST" ]] || default=4
  while true; do
    if ((retry == 0)); then
      say "RTT 来源（选择测试目标，不改变出口线路）："
      say "1) 移动：$RTT_MOBILE_HOST    2) 电信：$RTT_TELECOM_HOST"
      say "3) 自定义 IP/域名          4) 手动输入（${RTT_MS:-150} ms）"
      read -r -p "选择 [$default]：" choice || return 1
      choice=${choice:-$default}
      case "$choice" in
        1) RTT_LINE=mobile; RTT_HOST=$RTT_MOBILE_HOST; default=1 ;;
        2) RTT_LINE=telecom; RTT_HOST=$RTT_TELECOM_HOST; default=2 ;;
        3) RTT_LINE=
           read -r -p "RTT 测试目标 [${RTT_HOST:-$RTT_MOBILE_HOST}]：" choice || return 1
           RTT_HOST=${choice:-${RTT_HOST:-$RTT_MOBILE_HOST}}; default=3 ;;
        4) input_manual_rtt; return $? ;;
        *) say "请输入 1–4。"; continue ;;
      esac
    fi
    if measure_rtt "$RTT_HOST"; then return 0; fi
    say "测试失败：1) 更换目标  2) 重试  3) 手动输入  4) 取消"
    read -r -p "选择 [1]：" recovery || return 1
    recovery=${recovery:-1}; retry=0
    case "$recovery" in
      1) ;;
      2) retry=1 ;;
      3) input_manual_rtt; return $? ;;
      4) say "已取消本次操作。"; return 1 ;;
      *) say "请输入 1–4，返回目标选择。" ;;
    esac
  done
}
resolve_rtt() {
  if [[ "$RTT_SOURCE" == saved && -n "$RTT_MS" ]]; then return 0; fi
  if [[ -n "$RTT_HOST" ]]; then
    measure_rtt "$RTT_HOST" || fail "RTT 测试失败，请换目标或用 --rtt-ms 手动设置；未应用配置"
  elif [[ -z "$RTT_MS" ]]; then
    if [[ -t 0 ]]; then choose_rtt || return 1
    else fail "请提供 --rtt-ms、--rtt-line 或 --rtt-host"; fi
  fi
}
wizard() {
  load_settings || true
  local queue=$1 answer
  LOCAL_MBPS=$(prompt_number "本地带宽 Mbps" "${LOCAL_MBPS:-1000}" 100000) || return 1
  SERVER_MBPS=$(prompt_number "服务器带宽 Mbps" "${SERVER_MBPS:-$LOCAL_MBPS}" 100000) || return 1
  choose_rtt || return 1
  while true; do
    read -r -p "缓冲策略 aggressive / balanced [$BUFFER_PROFILE]：" answer || return 1
    answer=${answer:-$BUFFER_PROFILE}
    [[ "$answer" != aggressive && "$answer" != balanced ]] || break
  done
  BUFFER_PROFILE=$answer
  if [[ "$queue" == choose ]]; then
    while true; do
      read -r -p "队列 fq / fq_pie [$QDISC]：" answer || return 1
      answer=${answer:-$QDISC}
      [[ "$answer" != fq && "$answer" != fq_pie ]] || break
    done
    QDISC=$answer
  else QDISC=$queue; fi
  read -r -p "出口网卡 [$IFACE]：" answer || return 1
  IFACE=${answer:-$IFACE}
  prepare
  preview
}
menu() {
  [[ -t 0 ]] || { usage; return 0; }
  local choice
  while true; do
    say ""
    say "TCP Tune Lite — BBR 固定开启"
    say "1) 配置并应用 FQ    2) 配置并应用 FQ-PIE    3) 预览"
    say "4) 状态             5) 撤销最近一次         6) 卸载并恢复首次应用前"
    say "7) 测速期间重传诊断（只读）"
    say "8) 单独测试 RTT（移动/电信/自定义/手动）"
    say "0) 退出"
    read -r -p "选择 [1]：" choice || return 0
    choice=${choice:-1}
    case "$choice" in
      1|2) if [[ "$choice" == 1 ]]; then
             if wizard fq && confirm "应用以上配置？"; then apply; fi
           else
             if wizard fq_pie && confirm "应用以上配置？"; then apply; fi
           fi ;;
      3) if wizard choose; then :; fi ;;
      4) status ;;
      5) ACTION=restore; restore_action ;;
      6) ACTION=uninstall; restore_action ;;
      7) read -r -p "测速端口（留空统计全部）：" DIAG_PORT
         if [[ -n "$DIAG_PORT" ]]; then DIAG_PORT=$(uint "$DIAG_PORT" 65535) || fail "端口无效"; fi
         diagnose ;;
      8) load_settings || true; if choose_rtt; then :; fi ;;
      0) return 0 ;;
      *) say "请输入菜单中的数字。" ;;
    esac
  done
}
main() {
  parse "$@"
  case "$ACTION" in
    menu) menu ;;
    preview|apply|switch)
      resolve_rtt || return 0
      prepare; preview
      if [[ "$ACTION" != preview ]] && ((DRY_RUN == 0)); then
        if confirm "应用以上配置？"; then apply; fi
      fi ;;
    status) status ;;
    rtt)
      if [[ -n "$RTT_HOST" ]]; then measure_rtt "$RTT_HOST" || fail "RTT 测试失败，请更换目标"
      elif [[ -t 0 ]]; then if choose_rtt; then :; fi
      else fail "非交互 RTT 测试需 --rtt-line 或 --rtt-host"; fi ;;
    diagnose) diagnose ;;
    restore|uninstall) restore_action ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
