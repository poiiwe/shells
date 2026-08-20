#!/usr/bin/env bash
# VLESS/TCP node tuning — safe adaptive edition
# Version: 3.1.0

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.1.0"
CONF_FILE="${TCP_TUNE_CONF:-/etc/sysctl.d/99-z-vless-tcp-tune.conf}"
STATE_DIR="${TCP_TUNE_STATE_DIR:-/var/lib/tcp-tune}"
ASSUME_YES=0
DRY_RUN=0
NO_COLOR=0
[[ "${TCP_TUNE_YES:-0}" == 1 ]] && ASSUME_YES=1
[[ "${TCP_TUNE_DRY_RUN:-0}" == 1 ]] && DRY_RUN=1
[[ "${TCP_TUNE_NO_COLOR:-0}" == 1 ]] && NO_COLOR=1
ROLLBACK=0
PROFILE="${TCP_TUNE_PROFILE:-auto}"
BANDWIDTH_MBPS="${TCP_TUNE_BANDWIDTH_MBPS:-}"
RTT_MS="${TCP_TUNE_RTT_MS:-}"

usage() {
  cat <<'EOF'
tcp-tune-v3.sh — VLESS 代理节点 TCP 调优

用法：
  bash tcp-tune-v3.sh [选项]

选项：
  -y, --yes                 无人值守，跳过确认
  -d, --dry-run             只检测和预览，绝不写入或加载模块
  -n, --no-color            禁用颜色
  -p, --profile PROFILE     auto|balanced|throughput（默认 auto）
      --bandwidth MBPS      节点出口带宽，用于按 BDP 计算缓冲区
      --rtt MS              典型客户端 RTT，用于按 BDP 计算缓冲区
      --rollback            恢复本脚本上一次安装前的配置
  -h, --help                显示帮助

推荐：
  bash tcp-tune-v3.sh --bandwidth 1000 --rtt 180
  bash tcp-tune-v3.sh --profile throughput --bandwidth 500 --rtt 220 -y

说明：
  不删除其他 sysctl 文件，不清空 /etc/sysctl.conf，不修改 conntrack、
  swappiness、tcp_mem 或 RPS/XPS。带宽/RTT 未指定时采用保守自适应值。
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }

while (($#)); do
  case "$1" in
    -y|--yes|--assume-yes) ASSUME_YES=1 ;;
    -d|--dry-run) DRY_RUN=1 ;;
    -n|--no-color) NO_COLOR=1 ;;
    --rollback) ROLLBACK=1 ;;
    -p|--profile)
      (($# >= 2)) || { echo "缺少 --profile 参数" >&2; exit 2; }
      PROFILE="$2"; shift ;;
    --bandwidth)
      (($# >= 2)) || { echo "缺少 --bandwidth 参数" >&2; exit 2; }
      BANDWIDTH_MBPS="$2"; shift ;;
    --rtt)
      (($# >= 2)) || { echo "缺少 --rtt 参数" >&2; exit 2; }
      RTT_MS="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$PROFILE" in auto|balanced|throughput) ;; *) echo "无效 profile：$PROFILE" >&2; exit 2 ;; esac
[[ -z "$BANDWIDTH_MBPS" ]] || is_uint "$BANDWIDTH_MBPS" || { echo "带宽必须是正整数 Mbps" >&2; exit 2; }
[[ -z "$RTT_MS" ]] || is_uint "$RTT_MS" || { echo "RTT 必须是正整数 ms" >&2; exit 2; }

if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
  BOLD=''; DIM=''; RESET=''
fi
info() { printf ' %s◆%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()   { printf ' %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf ' %s▲%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf ' %s✘%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
banner() {
  printf '\n%s╭──────────────────────────────────────────────────────────────╮%s\n' "$CYAN" "$RESET"
  printf '%s│%s  %sVLESS TCP TUNER%s  %sv%s%s\n' "$CYAN" "$RESET" "$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET"
  printf '%s│%s  安全自适应 · BDP 缓冲计算 · 冲突审计 · 一键回滚\n' "$CYAN" "$RESET"
  printf '%s╰──────────────────────────────────────────────────────────────╯%s\n' "$CYAN" "$RESET"
}
step() {
  printf '\n%s◆ [%s/4] %s%s\n' "$MAGENTA" "$1" "$2" "$RESET"
  printf '%s────────────────────────────────────────────────────────────────%s\n\n' "$DIM" "$RESET"
}
section() {
  printf '\n%s◆ %s%s\n' "$MAGENTA" "$1" "$RESET"
  printf '%s────────────────────────────────────────────────────────────────%s\n\n' "$DIM" "$RESET"
}
kv() { printf '  %s%s%s\t%s\n' "$DIM" "$1" "$RESET" "$2"; }
badge() { printf '%s[%s]%s' "$1" "$2" "$RESET"; }

banner

(( EUID == 0 )) || die "必须以 root 运行：sudo bash $0"
for cmd in awk find grep ip modinfo modprobe nproc paste sed sort sysctl uname xargs; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
done

rollback() {
  local previous="$STATE_DIR/previous.conf"
  section "回滚检查"
  [[ -e "$previous" || -L "$previous" ]] || die "没有可恢复的上一次配置"
  if ((DRY_RUN)); then
    info "将用 $previous 恢复 $CONF_FILE"
    return
  fi
  if [[ -s "$previous" ]]; then
    install -m 0644 "$previous" "$CONF_FILE"
    ok "已恢复原配置：$CONF_FILE"
  else
    rm -f -- "$CONF_FILE"
    ok "原先不存在配置，已移除：$CONF_FILE"
  fi
  sysctl --system >/dev/null || warn "重新加载 sysctl 时有参数失败，请执行 sysctl --system 检查"
}

if ((ROLLBACK)); then rollback; exit 0; fi

step 1 "系统与链路检测"

MEM_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
CPU_CORES=$(nproc)
KERNEL=$(uname -r)
MAIN_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
MAIN_IFACE=${MAIN_IFACE:-unknown}

# 未提供链路参数时，仅用保守默认值；脚本不伪装成测速工具。
BW_SOURCE="用户指定"; RTT_SOURCE="用户指定"
if [[ -z "$BANDWIDTH_MBPS" ]]; then BANDWIDTH_MBPS=500; BW_SOURCE="保守默认"; fi
if [[ -z "$RTT_MS" ]]; then RTT_MS=150; RTT_SOURCE="保守默认"; fi

if ((MEM_MB <= 512)); then
  TIER="micro"; CAP_MB=8; SOMAX=2048; BACKLOG=4096
elif ((MEM_MB <= 1024)); then
  TIER="small"; CAP_MB=16; SOMAX=4096; BACKLOG=8192
elif ((MEM_MB <= 2048)); then
  TIER="standard"; CAP_MB=32; SOMAX=8192; BACKLOG=16384
elif ((MEM_MB <= 8192)); then
  TIER="performance"; CAP_MB=64; SOMAX=16384; BACKLOG=32768
else
  TIER="large"; CAP_MB=128; SOMAX=32768; BACKLOG=65536
fi

# BDP(bytes) = Mbps × RTT(ms) × 125。留 2× BDP 余量并受内存档位约束。
BDP_BYTES=$((BANDWIDTH_MBPS * RTT_MS * 125))
TARGET_BYTES=$((BDP_BYTES * 2))
MIN_BYTES=$((4 * 1024 * 1024))
CAP_BYTES=$((CAP_MB * 1024 * 1024))
((TARGET_BYTES < MIN_BYTES)) && TARGET_BYTES=$MIN_BYTES
((TARGET_BYTES > CAP_BYTES)) && TARGET_BYTES=$CAP_BYTES

case "$PROFILE" in
  balanced) TARGET_BYTES=$((TARGET_BYTES * 3 / 4)); ((TARGET_BYTES < MIN_BYTES)) && TARGET_BYTES=$MIN_BYTES ;;
  throughput) TARGET_BYTES=$((TARGET_BYTES * 5 / 4)); ((TARGET_BYTES > CAP_BYTES)) && TARGET_BYTES=$CAP_BYTES ;;
esac

# 取整到 MiB，便于审计。
BUFFER_MB=$(((TARGET_BYTES + 1048575) / 1048576))
BUFFER_BYTES=$((BUFFER_MB * 1048576))

available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
HAS_BBR=0
if grep -qw bbr <<<"$available_cc"; then
  HAS_BBR=1
elif modinfo tcp_bbr >/dev/null 2>&1; then
  if ((DRY_RUN)); then
    info "检测到 tcp_bbr 模块；预览模式不加载"
    HAS_BBR=1
  elif modprobe tcp_bbr && grep -qw bbr <<<"$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"; then
    HAS_BBR=1
  fi
fi

if ((HAS_BBR)); then CC=bbr; QDISC=fq; else CC=cubic; QDISC=fq_codel; fi

printf '  %s系统资源%s\n' "$BOLD" "$RESET"
kv "内核版本" "$KERNEL"
kv "内存 / CPU" "${MEM_MB} MiB / ${CPU_CORES} 核"
kv "性能档位" "$(badge "$BLUE" "$TIER")"
kv "主网卡" "$MAIN_IFACE"
printf '\n  %s链路模型%s\n' "$BOLD" "$RESET"
kv "目标带宽" "${BANDWIDTH_MBPS} Mbps  ${DIM}(${BW_SOURCE})${RESET}"
kv "典型 RTT" "${RTT_MS} ms  ${DIM}(${RTT_SOURCE})${RESET}"
kv "估算 BDP" "$(((BDP_BYTES + 1048575) / 1048576)) MiB"
kv "TCP 缓冲上限" "${BUFFER_MB} MiB  ${DIM}(档位上限 ${CAP_MB} MiB)${RESET}"
kv "拥塞控制" "$(badge "$GREEN" "$CC")  +  $(badge "$CYAN" "$QDISC")"

((HAS_BBR)) || warn "BBR 当前不可用，将安全回退到 cubic + fq_codel"

declare -a KEYS=() LINES=() CURRENT=() PARAM_GROUPS=()
add_param() {
  local group=$1 key=$2 value=$3 current
  if sysctl -n "$key" >/dev/null 2>&1; then
    current=$(sysctl -n "$key" 2>/dev/null | xargs || true)
    KEYS+=("$key")
    LINES+=("$key = $value")
    CURRENT+=("$current")
    PARAM_GROUPS+=("$group")
  else
    warn "内核不支持，跳过：$key"
  fi
}

add_param "拥塞控制" net.core.default_qdisc "$QDISC"
add_param "拥塞控制" net.ipv4.tcp_congestion_control "$CC"
add_param "自适应缓冲" net.core.rmem_max "$BUFFER_BYTES"
add_param "自适应缓冲" net.core.wmem_max "$BUFFER_BYTES"
add_param "自适应缓冲" net.ipv4.tcp_rmem "4096 131072 $BUFFER_BYTES"
add_param "自适应缓冲" net.ipv4.tcp_wmem "4096 65536 $BUFFER_BYTES"
add_param "连接队列" net.core.somaxconn "$SOMAX"
add_param "连接队列" net.ipv4.tcp_max_syn_backlog "$SOMAX"
add_param "连接队列" net.core.netdev_max_backlog "$BACKLOG"
add_param "TCP 特性" net.ipv4.tcp_mtu_probing 1
add_param "TCP 特性" net.ipv4.tcp_fastopen 3
add_param "TCP 特性" net.ipv4.tcp_slow_start_after_idle 0
add_param "TCP 特性" net.ipv4.tcp_sack 1
add_param "TCP 特性" net.ipv4.tcp_timestamps 1
add_param "TCP 特性" net.ipv4.tcp_window_scaling 1
add_param "TCP 特性" net.ipv4.tcp_syncookies 1

step 2 "配置冲突审计"

PATTERN=$(printf '%s\n' "${KEYS[@]}" | sed 's/\./\\./g' | paste -sd'|' -)
CONFLICTS=0
scan_file() {
  local file=$1
  [[ -r "$file" ]] || return 0
  local matches
  matches=$(grep -nE "^[[:space:]]*(${PATTERN})[[:space:]]*=" "$file" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    warn "发现同键配置（不会修改）：$file"
    printf '%s\n' "$matches" | sed 's/^/      /'
    CONFLICTS=$((CONFLICTS + 1))
  fi
}

for dir in /usr/lib/sysctl.d /usr/local/lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r file; do
    [[ "$file" == "$CONF_FILE" ]] || scan_file "$file"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort)
done
scan_file /etc/sysctl.conf
if ((CONFLICTS == 0)); then
  ok "审计通过：未发现同键配置"
else
  warn "共发现 ${CONFLICTS} 个包含同键配置的文件"
  info "安全策略：仅报告冲突，不删除、不清空、不改写原文件"
fi

emit_config() {
  local last_group="" i
  printf '# ════════════════════════════════════════════════════════════\n'
  printf '#  VLESS TCP TUNER v%s\n' "$VERSION"
  printf '#  profile=%s | bandwidth=%sMbps | rtt=%sms | buffer=%sMiB\n' \
    "$PROFILE" "$BANDWIDTH_MBPS" "$RTT_MS" "$BUFFER_MB"
  printf '#  Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '# ════════════════════════════════════════════════════════════\n'
  for i in "${!KEYS[@]}"; do
    if [[ "${PARAM_GROUPS[$i]}" != "$last_group" ]]; then
      printf '\n# ── %s ───────────────────────────────────────────────────\n' "${PARAM_GROUPS[$i]}"
      last_group=${PARAM_GROUPS[$i]}
    fi
    printf '%s\n' "${LINES[$i]}"
  done
}

step 3 "配置变更预览"
kv "运行模式" "$( ((DRY_RUN)) && badge "$YELLOW" "DRY-RUN" || badge "$GREEN" "APPLY" )"
kv "调优策略" "$(badge "$BLUE" "$PROFILE")"
kv "目标配置" "$CONF_FILE"
printf '\n  %s图例%s  %s当前值%s  %s→%s  %s目标值%s\n' \
  "$BOLD" "$RESET" "$DIM" "$RESET" "$CYAN" "$RESET" "$BOLD" "$RESET"

last_group=""; first_group=1
for i in "${!KEYS[@]}"; do
  key=${KEYS[$i]}
  target=${LINES[$i]#*= }; target=$(xargs <<<"$target")
  if [[ "${PARAM_GROUPS[$i]}" != "$last_group" ]]; then
    if ((first_group)); then branch='┌─'; first_group=0; else branch='├─'; fi
    printf '\n  %s%s %s%s\n' "$MAGENTA" "$branch" "${PARAM_GROUPS[$i]}" "$RESET"
    last_group=${PARAM_GROUPS[$i]}
  fi
  printf '  %s│%s %s%s%s\n' "$MAGENTA" "$RESET" "$BOLD" "$key" "$RESET"
  if [[ "${CURRENT[$i]}" == "$target" ]]; then
    printf '  %s│%s   %s%s  =  已是目标值%s\n' "$MAGENTA" "$RESET" "$DIM" "$target" "$RESET"
  else
    printf '  %s│%s   %s%s%s  %s→%s  %s%s%s\n' \
      "$MAGENTA" "$RESET" "$DIM" "${CURRENT[$i]}" "$RESET" \
      "$CYAN" "$RESET" "$GREEN" "$target" "$RESET"
  fi
done
printf '  %s└────────────────────────────────────────────────────────────%s\n' "$MAGENTA" "$RESET"

if ((DRY_RUN)); then
  printf '\n'
  ok "预览完成，未修改系统、未加载模块"
  exit 0
fi

if ((ASSUME_YES == 0)); then
  printf '\n应用以上配置？[Y/n] '
  read -r answer </dev/tty
  [[ ! "$answer" =~ ^[Nn]([Oo])?$ ]] || { info "已取消"; exit 0; }
fi

step 4 "写入配置并验证"
mkdir -p "$STATE_DIR"
if [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]]; then
  cp -a -- "$CONF_FILE" "$STATE_DIR/previous.conf"
else
  : > "$STATE_DIR/previous.conf"
fi

tmp_file=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
trap 'rm -f -- "${tmp_file:-}"' EXIT
{
  emit_config
} >"$tmp_file"
chmod 0644 "$tmp_file"
mv -f -- "$tmp_file" "$CONF_FILE"
trap - EXIT

if ((HAS_BBR)); then
  printf 'tcp_bbr\n' >/etc/modules-load.d/tcp_bbr.conf
fi

apply_output=$(sysctl -p "$CONF_FILE" 2>&1) || {
  printf '%s\n' "$apply_output" >&2
  die "部分参数应用失败；可执行：bash $0 --rollback"
}

FAILED=0
printf '  %s参数验证%s\n\n' "$BOLD" "$RESET"
for i in "${!KEYS[@]}"; do
  key=${KEYS[$i]}
  expected=${LINES[$i]#*= }; expected=${expected//  / }
  actual=$(sysctl -n "$key" 2>/dev/null | xargs || true)
  expected=$(xargs <<<"$expected")
  if [[ "$actual" == "$expected" ]]; then
    printf '  %s✔%s %-43s %s%s%s\n' "$GREEN" "$RESET" "$key" "$DIM" "$actual" "$RESET"
  else
    printf '  %s✘%s %s\n' "$RED" "$RESET" "$key"
    printf '      当前: %s  期望: %s\n' "$actual" "$expected"
    FAILED=$((FAILED + 1))
  fi
done

if ((FAILED)); then
  warn "$FAILED 个参数验证不一致；检查容器/虚拟化限制及后加载的 sysctl 配置"
  exit 1
fi

printf '\n%s╭──────────────────────────────────────────────────────────────╮%s\n' "$GREEN" "$RESET"
printf '%s│%s  %s✔ TCP 调优已完成%s\n' "$GREEN" "$RESET" "$BOLD" "$RESET"
printf '%s│%s\n' "$GREEN" "$RESET"
printf '%s│%s  拥塞控制   %s + %s\n' "$GREEN" "$RESET" "$CC" "$QDISC"
printf '%s│%s  TCP 缓冲   %s MiB\n' "$GREEN" "$RESET" "$BUFFER_MB"
printf '%s│%s  配置文件   %s\n' "$GREEN" "$RESET" "$CONF_FILE"
printf '%s│%s  回滚命令   bash %s --rollback\n' "$GREEN" "$RESET" "$0"
printf '%s╰──────────────────────────────────────────────────────────────╯%s\n' "$GREEN" "$RESET"
