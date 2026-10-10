#!/usr/bin/env bash
# Standalone cleanup for poiiwe/shells tcp-tune v3.6.2 and its named v3 services.
# MIT. Does not source installed scripts or execute backup replay scripts.
set -Eeuo pipefail
VERSION=1.0.1
ROOT= SYS_NET=/sys/class/net
DRY_RUN=0 YES=0 SNAPSHOT= BASELINE= LITE_IFACE= LITE=0 FOUND=0 PARTIAL=0
UNITS=(tcp-tune-adapt.timer tcp-tune-adapt.service tcp-tune-qdisc.service tcp-tune-runtime.service)
KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling net.ipv4.tcp_limit_output_bytes
  net.ipv4.tcp_mem net.core.optmem_max net.core.netdev_max_backlog net.core.netdev_budget
  net.core.netdev_budget_usecs net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.core.rps_sock_flow_entries net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen
  net.ipv4.tcp_sack net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl
  net.ipv4.tcp_keepalive_probes net.ipv4.tcp_fin_timeout net.ipv4.tcp_slow_start_after_idle)
LITE_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max
  net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem)
IFACES=() FILES=() REMAINDER=() LOADED=()
declare -A RESTORE=() LISTINGS=() REBUILD_MQ=() UNIT_LOAD=()
say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; [[ -z "$SNAPSHOT" ]] || interrupted 1; exit 1; }
note() { say "提示：$*" >&2; PARTIAL=1; }
usage() {
  cat <<'EOF'
tcp-tune-cleanup — 独立清理旧版 tcp-tune，为 Lite 版迁移准备

sudo bash tcp-tune-cleanup.sh --dry-run       # 预览，不修改
sudo bash tcp-tune-cleanup.sh                 # 查看计划后确认清理
sudo bash tcp-tune-cleanup.sh --yes           # 无交互清理
sudo bash tcp-tune-cleanup.sh --interface eth0 --yes

--interface NAME  可重复指定；默认从旧设置、运行脚本和备份读取网卡
--dry-run         只列计划，不停止服务、不创建备份、不写参数
--yes             跳过确认
--help / --version

范围：tcp-tune-adapt.timer/service、qdisc/runtime 服务、对应运行脚本、
旧 99-tcp-tune.conf（sysctl 和 modules-load）、状态文件及 tcp-tune 命令。
已有文件移入 /var/backups/tcp-tune-cleanup/，旧 /var/backups/tcp-tune 保留。
旧配置中不属于 v3.6.2 管理的参数另存为 90-pre-tcp-tune-*.conf。

有首次 baseline 时恢复该版本管理的 25 个 sysctl、RPS 和可修改 offload。
不回放旧队列或自适应服务：出口重建为默认、不限速 FQ；原 mq 结构恢复。
已安装 Lite 时保留 Lite 的六个 sysctl 和它的出口队列。
缺少基线时，仍移除旧文件/服务和限速队列；无法还原的实时参数会提示。
不猜测其他工具的安装路径，不删除 ingress/clsact、防火墙或第三方配置。
退出码：0 清理完成/没有旧配置，1 操作失败，2 有项目无法精确恢复。
队列重建会清空旧积压，建议避开正在进行的测速或大文件传输。
EOF
}
valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.:@-]*$ ]]; }
add_iface() {
  local name=$1 old
  valid_iface "$name" || return 0
  for old in "${IFACES[@]}"; do [[ "$old" != "$name" ]] || return 0; done
  IFACES+=("$name")
}
# IFACE assignments in the original settings/runtime are literals, never eval.
read_iface() {
  local file=$1 value
  [[ -r "$file" ]] || return 0
  value=$(sed -n 's/^IFACE=//p' "$file" | head -n 1)
  if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value=${value:1:${#value}-2}; fi
  valid_iface "$value" && printf '%s' "$value" || true
}
paths() {
  local path unit
  for path in /etc/sysctl.d/99-tcp-tune.conf /etc/modules-load.d/99-tcp-tune.conf \
    /usr/local/libexec/tcp-tune-runtime /usr/local/libexec/tcp-tune-qdisc \
    /usr/local/libexec/tcp-tune-adapt /etc/systemd/system/tcp-tune-runtime.service \
    /etc/systemd/system/tcp-tune-qdisc.service /etc/systemd/system/tcp-tune-adapt.service \
    /etc/systemd/system/tcp-tune-adapt.timer /var/lib/tcp-tune/adapt.state \
    /var/lib/tcp-tune/settings.conf /usr/local/sbin/tcp-tune; do printf '%s\n' "$ROOT$path"; done
  for unit in "${UNITS[@]}"; do
    for path in "$ROOT"/etc/systemd/system/*.wants/"$unit" "$ROOT"/etc/systemd/system/*.requires/"$unit" \
      "$ROOT"/run/systemd/system/*.wants/"$unit" "$ROOT"/run/systemd/system/*.requires/"$unit"; do
      [[ ! -L "$path" ]] || printf '%s\n' "$path"
    done
  done
}
systemd_ok() { command -v systemctl >/dev/null && [[ -d "$ROOT/run/systemd/system" ]]; }
member() { local value=$1 item; shift; for item in "$@"; do [[ "$value" != "$item" ]] || return 0; done; return 1; }
parse() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) YES=1; shift ;;
      --interface) (($# >= 2)) || fail "--interface 缺少网卡名"
        valid_iface "$2" || fail "网卡名无效"; add_iface "$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      --version) say "tcp-tune-cleanup v$VERSION"; exit 0 ;;
      *) fail "未知参数：$1" ;;
    esac
  done
}
find_baseline() {
  local root="$ROOT/var/backups/tcp-tune" resolved
  [[ -r "$root/baseline" ]] || return 0
  resolved=$(realpath -e -- "$(<"$root/baseline")" 2>/dev/null) || return 0
  root=$(realpath -e -- "$root") || return 0
  [[ "$resolved" == "$root"/* && -d "$resolved" ]] || return 0
  BASELINE=$resolved
}
read_config() {
  local file=$1 mode=$2 line key value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]%%#*}
    value=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$value")
    if member "$key" "${KEYS[@]}"; then
      [[ "$mode" == baseline ]] || continue
      if ((LITE)) && member "$key" "${LITE_KEYS[@]}"; then continue; fi
      if [[ "$key" == net.core.default_qdisc && "$value" == cake* ]]; then
        RESTORE["$key"]=fq  # Do not restore CAKE at the next reboot.
      elif [[ "$value" =~ ^[a-zA-Z0-9_]+([[:space:]]+[0-9]+)*$ ]]; then RESTORE["$key"]=$value
      else note "基线中 $key 的值无法验证，跳过"; fi
    elif [[ "$mode" == current ]]; then REMAINDER+=("$key = $value"); fi
  done < "$file"
}
inspect() {
  local file unit name state iface root_kind classes filters
  FILES=(); LOADED=(); REMAINDER=(); RESTORE=(); LISTINGS=(); REBUILD_MQ=(); UNIT_LOAD=()
  while IFS= read -r file; do
    if [[ -e "$file" || -L "$file" ]]; then
      [[ ! -d "$file" ]] || fail "预期为文件却发现目录：$file"
      FILES+=("$file"); FOUND=1
    fi
  done < <(paths)
  if systemd_ok; then
    for unit in "${UNITS[@]}"; do
      state=$(systemctl show -p LoadState --value "$unit") || fail "无法查询 $unit"
      UNIT_LOAD["$unit"]=$state
      if [[ "$state" != not-found && -n "$state" ]]; then LOADED+=("$unit"); FOUND=1
      else
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        case "$state" in enabled|enabled-runtime|linked|linked-runtime) LOADED+=("$unit"); FOUND=1 ;; esac
      fi
    done
  fi
  if [[ -f "$ROOT/etc/sysctl.d/99-tcp-tune-lite.conf" ]]; then
    LITE=1; LITE_IFACE=$(read_iface "$ROOT/var/lib/tcp-tune-lite/settings.conf")
  fi
  find_baseline
  for file in "$ROOT/var/lib/tcp-tune/settings.conf" "$ROOT/var/lib/tcp-tune/adapt.state" \
    "$ROOT/usr/local/libexec/tcp-tune-qdisc" "$ROOT/usr/local/libexec/tcp-tune-runtime"; do
    name=$(read_iface "$file"); [[ -z "$name" ]] || add_iface "$name"
  done
  if [[ -n "$BASELINE" && $FOUND == 1 ]]; then
    for file in qdisc.iface offload.iface; do
      if [[ -r "$BASELINE/$file" ]]; then add_iface "$(<"$BASELINE/$file")"; fi
    done
    read_config "$BASELINE/sysctl.live" baseline
  fi
  if ((FOUND == 0)) && ((${#IFACES[@]} == 0)); then return 0; fi
  read_config "$ROOT/etc/sysctl.d/99-tcp-tune.conf" current
  if ((${#IFACES[@]} == 0)); then fail "未找到旧出口网卡，请用 --interface 指定"; fi
  if ((LITE)) && [[ -z "$LITE_IFACE" ]]; then
    say "检测到 Lite 配置但缺少网卡记录：保留所有当前队列，只清理旧持久化配置。"
  fi
  command -v tc >/dev/null || fail "缺少 tc，请安装 iproute2"
  command -v sysctl >/dev/null || fail "缺少 sysctl，请安装 procps"
  for iface in "${IFACES[@]}"; do
    if [[ ! -d "$SYS_NET/$iface" ]]; then note "网卡 $iface 已不存在，跳过实时队列"; continue; fi
    LISTINGS["$iface"]=$(tc qdisc show dev "$iface") || fail "无法读取 $iface 的队列"
    if ((LITE)) && [[ -z "$LITE_IFACE" || "$iface" == "$LITE_IFACE" ]]; then continue; fi
    root_kind=$(awk '$4=="root" {print $2; exit}' <<< "${LISTINGS[$iface]}")
    case "$root_kind" in mq|cake|fq|fq_pie|fq_codel|pfifo_fast|noqueue) ;; *) fail "$iface 存在 $root_kind 自定义队列，请先用其管理工具移除" ;; esac
    classes=$(tc class show dev "$iface") || fail "无法查询 $iface 的 class"
    filters=$(tc filter show dev "$iface") || fail "无法查询 $iface 的出口 filter"
    [[ -z "$filters" && -z "$(awk '$2!="mq" && $2!="cake" {print}' <<< "$classes")" ]] || fail "$iface 存在自定义 class/filter，停止清理"
    if [[ -n "$BASELINE" && -r "$BASELINE/qdisc.iface" && -r "$BASELINE/qdisc.txt" \
      && "$(<"$BASELINE/qdisc.iface")" == "$iface" ]] && \
      awk '$2=="mq" && $4=="root" {yes=1} END {exit !yes}' "$BASELINE/qdisc.txt"; then REBUILD_MQ["$iface"]=1; fi
  done
}
plan() {
  local item
  say "旧版 TCP 配置清理计划："
  for item in "${LOADED[@]}"; do say "  停用 $item"; done
  for item in "${FILES[@]}"; do say "  备份并移走 $item"; done
  say "  原始备份：${BASELINE:-未找到有效 baseline}"
  say "  可恢复旧版 sysctl：${#RESTORE[@]} 项；保留其他参数：${#REMAINDER[@]} 项"
  for item in "${IFACES[@]}"; do
    if ((LITE)) && [[ -z "$LITE_IFACE" || "$item" == "$LITE_IFACE" ]]; then say "  $item：保留 Lite 队列"
    else say "  $item：清除旧队列参数/限速，重建不限速 FQ，保留或恢复 mq"; fi
  done
  ((LITE == 0)) || say "  已检测到 Lite，保留它的六个 sysctl"
  say "  旧 baseline/latest 指针及历史备份保留；不启动任何旧服务。"
}
capture() {
  install -d -m 0700 "$ROOT/var/backups/tcp-tune-cleanup"
  SNAPSHOT=$(mktemp -d "$ROOT/var/backups/tcp-tune-cleanup/$(date +%Y%m%d-%H%M%S).XXXXXX")
  local iface key value path unit file
  plan > "$SNAPSHOT/plan.txt"
  for file in "${FILES[@]}"; do
    install -d -m 0700 "$(dirname "$SNAPSHOT/files-before$file")"
    cp -a -- "$file" "$SNAPSHOT/files-before$file"
  done
  : > "$SNAPSHOT/sysctl.before"; : > "$SNAPSHOT/rps.before.tsv"
  for key in "${KEYS[@]}"; do
    value=$(sysctl -n "$key" 2>/dev/null || true)
    [[ -z "$value" ]] || printf '%s = %s\n' "$key" "$value" >> "$SNAPSHOT/sysctl.before"
  done
  for iface in "${IFACES[@]}"; do
    [[ -n "${LISTINGS[$iface]:-}" ]] || continue
    printf '%s\n' "${LISTINGS[$iface]}" > "$SNAPSHOT/qdisc.$iface.txt"
    if command -v ethtool >/dev/null; then
      ethtool -k "$iface" > "$SNAPSHOT/offload.$iface.txt" || note "$iface 当前 offload 状态无法完整读取"
    fi
    for path in "$SYS_NET/$iface/queues"/rx-*/rps_cpus "$SYS_NET/$iface/queues"/rx-*/rps_flow_cnt; do
      [[ ! -r "$path" ]] || printf '%s\t%s\n' "$path" "$(<"$path")" >> "$SNAPSHOT/rps.before.tsv"
    done
  done
  : > "$SNAPSHOT/services.before.tsv"
  for unit in "${LOADED[@]}"; do
    printf '%s\t%s\t%s\n' "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
      "$(systemctl is-active "$unit" 2>/dev/null || true)" >> "$SNAPSHOT/services.before.tsv"
  done
  if [[ -n "$BASELINE" ]]; then
    install -d -m 0700 "$SNAPSHOT/baseline-data"
    for path in sysctl.live rps.tsv offload.iface offload.txt; do
      [[ ! -f "$BASELINE/$path" ]] || cp -- "$BASELINE/$path" "$SNAPSHOT/baseline-data/$path"
    done
  fi
}
stop_services() {
  local unit state
  for unit in "${LOADED[@]}"; do
    if [[ "${UNIT_LOAD[$unit]}" == not-found ]]; then
      systemctl disable "$unit" >/dev/null || fail "无法移除 $unit 的启用链接"
      continue
    fi
    systemctl disable --now "$unit" >/dev/null || fail "无法停用 $unit"
    state=$(systemctl show -p ActiveState --value "$unit") || fail "无法核实 $unit 状态"
    case "$state" in active|activating|deactivating|reloading) fail "$unit 仍在运行，停止清理" ;; esac
  done
}
# A qdisc with handle 0: cannot be deleted. An unused explicit handle makes
# replace create/graft a fresh instance, also clearing same-kind old options.
fresh_handle() {
  local iface=$1 listing handle major candidate
  local -A used=()
  listing=$(tc qdisc show dev "$iface") || fail "无法读取 $iface 的队列句柄"
  while read -r handle; do
    [[ "$handle" =~ ^[0-9a-fA-F]{1,4}:$ ]] || fail "队列句柄无法验证：$handle"
    major=$((16#${handle%:})); used["$major"]=1
  done < <(awk '$1=="qdisc" {print $3}' <<< "$listing")
  for ((candidate=32768; candidate<65535; candidate++)); do
    if [[ ! -v "used[$candidate]" ]]; then printf -v FRESH_HANDLE '%x:' "$candidate"; return 0; fi
  done
  fail "$iface 没有可用的队列句柄"
}
reset_queues() {
  local iface listing kind root_handle parent path targets=()
  command -v modprobe >/dev/null && modprobe sch_fq 2>/dev/null || true
  for iface in "${IFACES[@]}"; do
    [[ -d "$SYS_NET/$iface" ]] || continue
    if ((LITE)) && [[ -z "$LITE_IFACE" || "$iface" == "$LITE_IFACE" ]]; then continue; fi
    listing=$(tc qdisc show dev "$iface")
    kind=$(awk '$4=="root" {print $2; exit}' <<< "$listing")
    root_handle=$(awk '$4=="root" {print $3; exit}' <<< "$listing")
    [[ "$kind" != noqueue ]] || continue
    # Give a default mq root a real handle too, so child parent IDs do not
    # depend on a kernel accepting major-zero parent IDs such as :1.
    if [[ "$kind" == mq && "$root_handle" == 0: ]] || \
      [[ "$kind" != mq && ${REBUILD_MQ[$iface]:-0} == 1 ]]; then
      fresh_handle "$iface"
      tc qdisc replace dev "$iface" root handle "$FRESH_HANDLE" mq
      listing=$(tc qdisc show dev "$iface"); kind=mq
    fi
    if [[ "$kind" == mq ]]; then
      targets=()
      while read -r parent; do
        [[ "$parent" =~ ^[a-fA-F0-9]*:[a-fA-F0-9]+$ ]] || fail "mq 子队列标识无法验证：$parent"
        targets+=("$parent")
      done < <(awk '$2!="ingress" && $2!="clsact" && $4=="parent" {print $5}' <<< "$listing")
      ((${#targets[@]})) || fail "$iface 没有可识别的 mq 子队列"
      for parent in "${targets[@]}"; do
        fresh_handle "$iface"
        tc qdisc replace dev "$iface" parent "$parent" handle "$FRESH_HANDLE" fq
      done
    else
      fresh_handle "$iface"
      tc qdisc replace dev "$iface" root handle "$FRESH_HANDLE" fq
    fi
    listing=$(tc qdisc show dev "$iface")
    awk '$2=="ingress" || $2=="clsact" {next}
      $4=="root" {roots++; kind=$2; if(kind!="mq" && kind!="fq") bad=1}
      $4=="parent" {leaves++; if($2!="fq") bad=1}
      END {exit bad || roots!=1 || (kind=="mq" && leaves<1)}' <<< "$listing" || fail "$iface 队列核验失败"
    say "已清除 $iface 的 CAKE/旧队列参数和限速。"
  done
}
restore_parameters() {
  local key path value iface feature field actual base="$SNAPSHOT/baseline-data"
  for key in "${KEYS[@]}"; do
    if [[ ! -v "RESTORE[$key]" ]]; then
      if ((FOUND)) && [[ -n "$BASELINE" ]] && \
        { ((LITE == 0)) || ! member "$key" "${LITE_KEYS[@]}"; } && sysctl -n "$key" >/dev/null 2>&1; then
        note "$key 在基线中缺少原值，当前值保留"
      fi
      continue
    fi
    if ! sysctl -w "$key=${RESTORE[$key]}" >/dev/null; then note "$key 无法恢复，旧值见备份"; continue; fi
    actual=$(sysctl -n "$key")
    [[ "$(xargs <<< "$actual")" == "$(xargs <<< "${RESTORE[$key]}")" ]] || note "$key 恢复后核验不一致"
  done
  if ((FOUND)) && [[ -z "$BASELINE" || ! -s "$base/sysctl.live" ]]; then
    note "缺少 sysctl 首次基线，未猜测原值；旧实时参数需重启或逐项设置后复核。"
  fi
  if [[ -r "$base/rps.tsv" ]]; then
    while IFS=$'\t' read -r path value; do
      # Validate paths from data files before writing to sysfs; never follow ../.
      [[ "$path" =~ ^/sys/class/net/([a-zA-Z0-9_][a-zA-Z0-9_.:@-]*)/queues/rx-[0-9]+/rps_(cpus|flow_cnt)$ ]] || { note "跳过无法验证的 RPS 路径"; continue; }
      iface=${path#/sys/class/net/}; iface=${iface%%/*}; field=${path##*/}
      valid_iface "$iface" && member "$iface" "${IFACES[@]}" && \
        [[ "$path" =~ /queues/rx-[0-9]+/rps_(cpus|flow_cnt)$ ]] || { note "跳过无法验证的 RPS 路径"; continue; }
      if [[ "$field" == rps_cpus ]]; then [[ "$value" =~ ^[0-9a-fA-F]+(,[0-9a-fA-F]+)*$ ]] || { note "RPS mask 无效"; continue; }
      else [[ "$value" =~ ^[0-9]+$ ]] || { note "RPS 流数无效"; continue; }; fi
      path="$SYS_NET/${path#/sys/class/net/}"
      [[ ! -e "$path" ]] || { printf '%s' "$value" > "$path"; }
    done < "$base/rps.tsv"
  elif ((FOUND)); then
    for iface in "${IFACES[@]}"; do
      for path in "$SYS_NET/$iface/queues"/rx-*/rps_cpus "$SYS_NET/$iface/queues"/rx-*/rps_flow_cnt; do
        [[ ! -e "$path" ]] || printf '0' > "$path"
      done
    done
    note "缺少 RPS 基线，旧出口的 RPS 已关闭。"
  fi
  if [[ -r "$base/offload.txt" && -r "$base/offload.iface" ]]; then
    iface=$(<"$base/offload.iface")
    if valid_iface "$iface" && [[ -d "$SYS_NET/$iface" ]] && command -v ethtool >/dev/null; then
      while read -r feature value; do
        [[ "$value" == on || "$value" == off ]] || { note "offload 值无法验证"; continue; }
        ethtool -K "$iface" "$feature" "$value" >/dev/null || note "$iface 的 $feature 无法恢复"
      done < <(awk '/^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|rx-checksumming|tx-checksumming):/ && !/\[fixed\]/ {sub(/:$/, "", $1); print $1,$2}' "$base/offload.txt")
    else note "无法恢复 $iface 的 offload，请安装 ethtool 并对照备份"; fi
  elif ((FOUND)); then note "缺少 offload 基线，当前网卡卸载状态保留。"; fi
}
archive_files() {
  local file destination retained
  if ((${#REMAINDER[@]})); then
    retained="$ROOT/etc/sysctl.d/90-pre-tcp-tune-$(basename "$SNAPSHOT").conf"
    (set -o noclobber; printf '# Parameters inherited before tcp-tune cleanup\n%s\n' "${REMAINDER[@]}" > "$retained")
    chmod 0644 "$retained"; printf '%s\n' "$retained" > "$SNAPSHOT/preserved.conf.path"
    say "其他参数保留在 $retained"
  fi
  : > "$SNAPSHOT/moved.list"
  for file in "${FILES[@]}"; do
    destination="$SNAPSHOT/removed$file"
    install -d -m 0700 "$(dirname "$destination")"
    [[ -e "$file" || -L "$file" ]] || continue  # systemctl disable may remove enablement links.
    mv -- "$file" "$destination"
    printf '%s\n' "$file" >> "$SNAPSHOT/moved.list"
  done
  if systemd_ok; then systemctl daemon-reload; fi
}
interrupted() {
  local status=$1
  trap - ERR INT TERM HUP
  say "清理未完成；已备份/移走的内容在 ${SNAPSHOT:-尚未创建备份}。" >&2
  say "旧自适应服务不会自动重新启用；请检查错误后重跑。" >&2
  exit "$status"
}
main() {
  parse "$@"
  [[ "$(uname -s)" == Linux ]] || fail "仅支持 Linux"
  inspect
  if ((FOUND == 0)) && ((${#IFACES[@]} == 0)); then say "未发现旧版 tcp-tune 配置，无需清理。"; return 0; fi
  plan
  ((DRY_RUN == 0)) || return 0
  ((EUID == 0)) || fail "清理需要 root，请用 sudo；--dry-run 可只读运行"
  if ((YES == 0)); then
    [[ -t 0 ]] || fail "非交互执行需 --yes"
    local answer; read -r -p '按以上计划清理？[y/N]：' answer
    [[ "$answer" == y || "$answer" == Y ]] || { say "已取消"; return 0; }
  fi
  command -v flock >/dev/null || fail "缺少 flock，请安装 util-linux"
  install -d -m 0755 "$ROOT/run/lock"
  exec 9>"$ROOT/run/lock/tcp-tune.lock"; flock -n 9 || fail "旧版调优/自适应操作正在运行，请稍后重试"
  exec 8>"$ROOT/run/lock/tcp-tune-lite.lock"; flock -n 8 || fail "Lite 操作正在运行，请稍后重试"
  # Recheck all data under both locks after interactive confirmation.
  inspect
  capture
  trap 'interrupted $?' ERR
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM
  trap 'interrupted 129' HUP
  stop_services
  reset_queues
  restore_parameters
  archive_files
  trap - ERR INT TERM HUP
  exec 9>&-; exec 8>&-
  say "旧配置及清理前状态已备份到 $SNAPSHOT"
  if ((PARTIAL)); then say "持久化清理已完成，但部分实时设置未能精确恢复，见以上提示。"; return 2; fi
  say "旧版配置已清理，可继续运行 tcp-tune-lite.sh。"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
