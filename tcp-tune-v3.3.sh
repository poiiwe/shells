#!/usr/bin/env bash
# VLESS/TCP node tuning — safe adaptive edition
# Version: 3.3.0

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.3.0"
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
  bash tcp-tune-v3.sh                         # 交互输入带宽与 RTT
  bash tcp-tune-v3.sh --bandwidth 1000 --rtt 180
  bash tcp-tune-v3.sh --profile throughput --bandwidth 500 --rtt 220 -y

说明：
  应用前自动备份并清理旧 TCP 调优配置；混合配置仅移除冲突 TCP 参数，
  不会破坏其中的其他系统设置。交互运行时可手动输入带宽和 RTT；
  --yes 或无终端环境中未指定参数时，采用 500Mbps / 150ms 保守默认值。
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
  printf '%s│%s  交互参数 · 旧配置备份清理 · BDP 计算 · 一键回滚\n' "$CYAN" "$RESET"
  printf '%s╰──────────────────────────────────────────────────────────────╯%s\n' "$CYAN" "$RESET"
}
step() {
  printf '\n%s◆ [%s/5] %s%s\n' "$MAGENTA" "$1" "$2" "$RESET"
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
for cmd in awk basename dirname find grep ip modinfo modprobe nproc paste sed sort sysctl uname xargs; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
done
[[ "$(dirname "$CONF_FILE")" == /etc/sysctl.d && "$(basename "$CONF_FILE")" == *.conf ]] || \
  die "TCP_TUNE_CONF 必须位于 /etc/sysctl.d/ 且以 .conf 结尾"

safe_managed_path() {
  case "$1" in
    /etc/sysctl.conf|/etc/modules-load.d/tcp_bbr.conf) return 0 ;;
    /etc/sysctl.d/*.conf)
      [[ "$(dirname "$1")" == /etc/sysctl.d ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

restore_snapshot() {
  local snapshot=$1 file saved
  [[ -d "$snapshot" ]] || return 1
  [[ "$snapshot" == "$STATE_DIR"/backups/* ]] || return 1

  if [[ -f "$snapshot/created.manifest" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if safe_managed_path "$file"; then
        rm -f -- "$file"
      else
        warn "跳过备份清单中的异常路径：$file"
      fi
    done <"$snapshot/created.manifest"
  fi

  if [[ -f "$snapshot/backed-up.manifest" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      saved="$snapshot/${file#/}"
      if safe_managed_path "$file" && [[ -e "$saved" || -L "$saved" ]]; then
        mkdir -p "$(dirname "$file")"
        rm -f -- "$file"
        cp -a -- "$saved" "$file"
      else
        warn "无法恢复备份项：$file"
      fi
    done <"$snapshot/backed-up.manifest"
  fi
}

rollback() {
  local latest="$STATE_DIR/latest-backup" snapshot previous="$STATE_DIR/previous.conf"
  section "回滚检查"

  if [[ -s "$latest" ]]; then
    snapshot=$(<"$latest")
    [[ -d "$snapshot" && "$snapshot" == "$STATE_DIR"/backups/* ]] || die "最新备份记录无效：$snapshot"
    if ((DRY_RUN)); then
      info "将恢复完整快照：$snapshot"
      return
    fi
    restore_snapshot "$snapshot" || die "备份恢复失败：$snapshot"
    sysctl --system >/dev/null 2>&1 || warn "重新加载 sysctl 时有参数失败，请执行 sysctl --system 检查"
    ok "已恢复应用前的全部配置：$snapshot"
    return
  fi

  # 兼容 v3.2 及更早版本的单文件备份。
  [[ -e "$previous" || -L "$previous" ]] || die "没有可恢复的历史配置"
  if ((DRY_RUN)); then
    info "将用旧版备份恢复 $CONF_FILE"
  elif [[ -s "$previous" ]]; then
    install -m 0644 "$previous" "$CONF_FILE"
    sysctl --system >/dev/null 2>&1 || true
    ok "已恢复旧版单文件备份"
  else
    rm -f -- "$CONF_FILE"
    sysctl --system >/dev/null 2>&1 || true
    ok "原先不存在配置，已移除当前调优文件"
  fi
}

if ((ROLLBACK)); then rollback; exit 0; fi

step 1 "链路参数设置"

DEFAULT_BANDWIDTH_MBPS=500
DEFAULT_RTT_MS=150
BW_SOURCE="参数指定"
RTT_SOURCE="参数指定"

prompt_uint() {
  local label=$1 hint=$2 default=$3 input
  while true; do
    printf '  %s%s%s\n' "$BOLD" "$label" "$RESET"
    printf '  %s%s%s\n' "$DIM" "$hint" "$RESET"
    printf '  输入数值 [%s]: ' "$default"
    if ! read -r -u "$INPUT_FD" input; then
      REPLY_VALUE=$default
      REPLY_SOURCE="保守默认"
      printf '\n'
      return
    fi
    if [[ -z "$input" ]]; then
      REPLY_VALUE=$default
      REPLY_SOURCE="交互默认"
      return
    fi
    if is_uint "$input"; then
      REPLY_VALUE=$input
      REPLY_SOURCE="手动输入"
      return
    fi
    warn "请输入大于 0 的整数，不要包含 Mbps、ms 等单位"
    printf '\n'
  done
}

CAN_PROMPT=0
INPUT_FD=0
if ((ASSUME_YES == 0)); then
  if [[ -t 0 ]]; then
    CAN_PROMPT=1
  elif [[ -r /dev/tty ]] && exec 3</dev/tty 2>/dev/null; then
    CAN_PROMPT=1
    INPUT_FD=3
  fi
fi

if [[ -z "$BANDWIDTH_MBPS" ]]; then
  if ((CAN_PROMPT)); then
    prompt_uint \
      "目标带宽（Mbps）" \
      "建议填写 VPS 端口与 iperf3 多流稳定速度中的较小值，例如 500 或 1000。" \
      "$DEFAULT_BANDWIDTH_MBPS"
    BANDWIDTH_MBPS=$REPLY_VALUE
    BW_SOURCE=$REPLY_SOURCE
  else
    BANDWIDTH_MBPS=$DEFAULT_BANDWIDTH_MBPS
    BW_SOURCE="保守默认"
  fi
fi

if [[ -z "$RTT_MS" ]]; then
  if ((CAN_PROMPT)); then
    printf '\n'
    prompt_uint \
      "典型 RTT（ms）" \
      "建议填写真实客户端空载 Ping 的 P50～P75，不要填写满载时的最高延迟。" \
      "$DEFAULT_RTT_MS"
    RTT_MS=$REPLY_VALUE
    RTT_SOURCE=$REPLY_SOURCE
  else
    RTT_MS=$DEFAULT_RTT_MS
    RTT_SOURCE="保守默认"
  fi
fi

printf '\n  %s已选择的链路参数%s\n' "$BOLD" "$RESET"
kv "目标带宽" "${BANDWIDTH_MBPS} Mbps  ${DIM}(${BW_SOURCE})${RESET}"
kv "典型 RTT" "${RTT_MS} ms  ${DIM}(${RTT_SOURCE})${RESET}"

step 2 "系统与链路检测"

MEM_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
CPU_CORES=$(nproc)
KERNEL=$(uname -r)
MAIN_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
MAIN_IFACE=${MAIN_IFACE:-unknown}

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
BBR_NEEDS_LOAD=0
if grep -qw bbr <<<"$available_cc"; then
  HAS_BBR=1
elif modinfo tcp_bbr >/dev/null 2>&1; then
  HAS_BBR=1
  BBR_NEEDS_LOAD=1
  info "检测到 tcp_bbr 模块；将在确认应用后加载"
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

declare -a KEYS=() PARAM_LINES=() CURRENT=() PARAM_GROUPS=()
add_param() {
  local group=$1 key=$2 value=$3 current
  if sysctl -n "$key" >/dev/null 2>&1; then
    current=$(sysctl -n "$key" 2>/dev/null | xargs || true)
    KEYS+=("$key")
    PARAM_LINES+=("$key = $value")
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

step 3 "配置冲突审计"

MANAGED_KEYS=(
  net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog
  net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen
  net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_sack
  net.ipv4.tcp_timestamps net.ipv4.tcp_window_scaling net.ipv4.tcp_syncookies
)
LEGACY_CLEAN_KEYS=(
  net.ipv4.tcp_tw_reuse net.ipv4.tcp_max_tw_buckets
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_syn_retries net.ipv4.tcp_synack_retries
  net.ipv4.ip_local_port_range net.core.rmem_default net.core.wmem_default
  net.ipv4.tcp_mem net.ipv4.tcp_no_metrics_save net.ipv4.tcp_notsent_lowat
  net.ipv4.tcp_fin_timeout net.ipv4.tcp_rfc1337 net.ipv4.tcp_retries2
  net.core.optmem_max
)
DEDICATED_EXTRA_KEYS=(
  fs.file-max vm.swappiness
  net.netfilter.nf_conntrack_max
  net.netfilter.nf_conntrack_tcp_timeout_established
)

CLEAN_PATTERN=$(
  printf '%s\n' "${MANAGED_KEYS[@]}" "${LEGACY_CLEAN_KEYS[@]}" |
    awk '!seen[$0]++' | sed 's/\./\\./g' | paste -sd'|' -
)
DEDICATED_PATTERN=$(
  printf '%s\n' "${MANAGED_KEYS[@]}" "${LEGACY_CLEAN_KEYS[@]}" "${DEDICATED_EXTRA_KEYS[@]}" |
    awk '!seen[$0]++' | sed 's/\./\\./g' | paste -sd'|' -
)

CONFLICTS=0
declare -a CLEANUP_FILES=()
add_cleanup_file() {
  local candidate=$1 existing
  for existing in "${CLEANUP_FILES[@]}"; do
    [[ "$existing" == "$candidate" ]] && return
  done
  CLEANUP_FILES+=("$candidate")
}
scan_file() {
  local file=$1 mutable=${2:-0}
  [[ -r "$file" ]] || return 0
  local matches
  matches=$(grep -nE "^[[:space:]]*(${CLEAN_PATTERN})[[:space:]]*=" "$file" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    if ((mutable)); then
      warn "发现旧调优配置（将备份并清理）：$file"
      add_cleanup_file "$file"
    else
      info "发现系统/运行时默认值（仅由新配置覆盖）：$file"
    fi
    printf '%s\n' "$matches" | sed 's/^/      /'
    CONFLICTS=$((CONFLICTS + 1))
  fi
}

for dir in /usr/lib/sysctl.d /usr/local/lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r file; do
    if [[ "$dir" == /etc/sysctl.d ]]; then
      scan_file "$file" 1
    else
      scan_file "$file" 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort)
done
scan_file /etc/sysctl.conf 1
if ((CONFLICTS == 0)); then
  ok "审计通过：未发现旧 TCP 调优配置"
else
  warn "共发现 ${CONFLICTS} 个包含 TCP 调优参数的文件"
fi
if ((${#CLEANUP_FILES[@]})); then
  info "将清理 ${#CLEANUP_FILES[@]} 个管理员配置文件；操作前创建完整备份"
  info "专用调优文件整文件移除；混合配置只移除旧 TCP 参数"
else
  ok "没有需要移除的管理员旧配置"
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
    printf '%s\n' "${PARAM_LINES[$i]}"
  done
}

step 4 "配置变更预览"
kv "运行模式" "$( ((DRY_RUN)) && badge "$YELLOW" "DRY-RUN" || badge "$GREEN" "APPLY" )"
kv "调优策略" "$(badge "$BLUE" "$PROFILE")"
kv "目标配置" "$CONF_FILE"
printf '\n  %s图例%s  %s当前值%s  %s→%s  %s目标值%s\n' \
  "$BOLD" "$RESET" "$DIM" "$RESET" "$CYAN" "$RESET" "$BOLD" "$RESET"

last_group=""; first_group=1
for i in "${!KEYS[@]}"; do
  key=${KEYS[$i]}
  target=${PARAM_LINES[$i]#*= }; target=$(xargs <<<"$target")
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
  ((CAN_PROMPT)) || die "当前没有可用交互终端；请传入 --bandwidth、--rtt 并使用 --yes"
  printf '\n应用以上配置？[Y/n] '
  read -r -u "$INPUT_FD" answer
  [[ ! "$answer" =~ ^[Nn]([Oo])?$ ]] || { info "已取消"; exit 0; }
fi

declare -A BACKED_UP=()
backup_one() {
  local snapshot=$1 file=$2 relative
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -z "${BACKED_UP[$file]:-}" ]] || return 0
  relative=${file#/}
  mkdir -p "$snapshot/$(dirname "$relative")"
  cp -a -- "$file" "$snapshot/$relative"
  printf '%s\n' "$file" >>"$snapshot/backed-up.manifest"
  BACKED_UP["$file"]=1
}

prepare_snapshot() {
  local file module_file=/etc/modules-load.d/tcp_bbr.conf
  BACKUP_DIR="$STATE_DIR/backups/$(date '+%Y%m%d-%H%M%S')-$$"
  mkdir -p "$BACKUP_DIR"
  : >"$BACKUP_DIR/backed-up.manifest"
  : >"$BACKUP_DIR/created.manifest"

  for file in "${CLEANUP_FILES[@]}"; do
    backup_one "$BACKUP_DIR" "$file"
  done

  if [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]]; then
    backup_one "$BACKUP_DIR" "$CONF_FILE"
  else
    printf '%s\n' "$CONF_FILE" >>"$BACKUP_DIR/created.manifest"
  fi

  if ((HAS_BBR)); then
    if [[ -e "$module_file" || -L "$module_file" ]]; then
      backup_one "$BACKUP_DIR" "$module_file"
    else
      printf '%s\n' "$module_file" >>"$BACKUP_DIR/created.manifest"
    fi
  fi
}

clean_old_file() {
  local file=$1 active_count dedicated_count filtered
  [[ -f "$file" ]] || return 0
  active_count=$(grep -Ec '^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=' "$file" 2>/dev/null || true)
  dedicated_count=$(grep -Ec "^[[:space:]]*(${DEDICATED_PATTERN})[[:space:]]*=" "$file" 2>/dev/null || true)

  if [[ "$file" != /etc/sysctl.conf && "$active_count" -gt 0 && "$active_count" -eq "$dedicated_count" ]]; then
    rm -f -- "$file"
    ok "已移除旧专用调优文件：$file"
    return
  fi

  filtered=$(mktemp "${file}.tmp.XXXXXX")
  grep -vE "^[[:space:]]*(${CLEAN_PATTERN})[[:space:]]*=" "$file" >"$filtered" || true
  chmod --reference="$file" "$filtered" 2>/dev/null || chmod 0644 "$filtered"
  chown --reference="$file" "$filtered" 2>/dev/null || true
  mv -f -- "$filtered" "$file"
  ok "已从混合配置中移除旧 TCP 参数：$file"
}

TRANSACTION_ACTIVE=0
tmp_file=""
transaction_exit() {
  local rc=$?
  trap - EXIT
  [[ -z "$tmp_file" ]] || rm -f -- "$tmp_file"
  if ((TRANSACTION_ACTIVE)); then
    warn "应用过程失败，正在自动恢复应用前快照"
    restore_snapshot "$BACKUP_DIR" || warn "自动恢复不完整，请手动检查：$BACKUP_DIR"
    sysctl --system >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap transaction_exit EXIT

step 5 "写入配置并验证"
mkdir -p "$STATE_DIR"
prepare_snapshot
ok "应用前快照已创建：$BACKUP_DIR"
TRANSACTION_ACTIVE=1

for old_file in "${CLEANUP_FILES[@]}"; do
  clean_old_file "$old_file"
done

if ((BBR_NEEDS_LOAD)); then
  modprobe tcp_bbr || die "tcp_bbr 模块加载失败，已中止并恢复旧配置"
  grep -qw bbr <<<"$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)" || \
    die "tcp_bbr 模块加载后仍不可用，已中止并恢复旧配置"
  ok "BBR 模块已加载"
fi

tmp_file=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
{
  emit_config
} >"$tmp_file"
chmod 0644 "$tmp_file"
mv -f -- "$tmp_file" "$CONF_FILE"
tmp_file=""
ok "新配置已写入：$CONF_FILE"

if ((HAS_BBR)); then
  mkdir -p /etc/modules-load.d
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
  expected=${PARAM_LINES[$i]#*= }; expected=${expected//  / }
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

latest_tmp=$(mktemp "$STATE_DIR/latest-backup.tmp.XXXXXX")
printf '%s\n' "$BACKUP_DIR" >"$latest_tmp"
mv -f -- "$latest_tmp" "$STATE_DIR/latest-backup"
TRANSACTION_ACTIVE=0
trap - EXIT

printf '\n%s╭──────────────────────────────────────────────────────────────╮%s\n' "$GREEN" "$RESET"
printf '%s│%s  %s✔ TCP 调优已完成%s\n' "$GREEN" "$RESET" "$BOLD" "$RESET"
printf '%s│%s\n' "$GREEN" "$RESET"
printf '%s│%s  拥塞控制   %s + %s\n' "$GREEN" "$RESET" "$CC" "$QDISC"
printf '%s│%s  TCP 缓冲   %s MiB\n' "$GREEN" "$RESET" "$BUFFER_MB"
printf '%s│%s  配置文件   %s\n' "$GREEN" "$RESET" "$CONF_FILE"
printf '%s│%s  配置备份   %s\n' "$GREEN" "$RESET" "$BACKUP_DIR"
printf '%s│%s  回滚命令   bash %s --rollback\n' "$GREEN" "$RESET" "$0"
printf '%s╰──────────────────────────────────────────────────────────────╯%s\n' "$GREEN" "$RESET"
