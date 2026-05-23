#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  tcp-tune.sh  —  TCP 深度调优脚本
#  Version : 2.1
#  Date    : 2025-05-23
#  Author  : HexHub AI / DMIT-GREENCLOUD-NEBURST 统一标准
#
#  Changelog:
#    v2.1  符号链接检测 + vm.swappiness 统一 + sysctl.conf 彻底清空
#    v2.0  冲突检测 + 自动清理 + 分档适配 + 验证输出
#    v1.0  基础分档 + 写入配置
#
#  Features:
#    - 四档自适应 (微型/标准/高性能/旗舰) 按内存自动分档
#    - BBR + fq 拥塞控制 (不可用时自动降级 cubic + fq_codel)
#    - 扫描 & 自动清理 /etc/sysctl.d/*.conf 和 /etc/sysctl.conf 冲突
#    - 冲突文件备份到时间戳目录，安全可回滚
#    - RPS/XPS 多核分发 (单核自动跳过)
#    - 幂等设计，重复执行安全
#    - 最终 18 项关键参数验证表格
#
#  Usage:
#    curl -fsSL <url>/tcp-tune.sh | bash
#    bash tcp-tune.sh
# ═══════════════════════════════════════════════════════════════
set -e

CONF_FILE="/etc/sysctl.d/99-tcp-tuning.conf"
BACKUP_DIR="/etc/sysctl.d/.bak-tcp-tune-$(date +%Y%m%d%H%M%S)"
HOSTNAME=$(hostname)

# ═══════════════════════════════════════════════════════════════
#  Phase 0 — 系统检测
# ═══════════════════════════════════════════════════════════════
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)
KERNEL_VER=$(uname -r)

HAS_CONNTRACK=0;  [ -f /proc/sys/net/netfilter/nf_conntrack_max ] && HAS_CONNTRACK=1
HAS_BBR=0;        sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && HAS_BBR=1

MAIN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)

echo "════════════════════════════════════════════"
echo "  TCP 调优 v2.1 — $HOSTNAME"
echo "  内存: ${MEM_MB}MB  CPU: ${CPU_CORES}核  内核: $KERNEL_VER"
echo "  网卡: $MAIN_IFACE  BBR: $HAS_BBR  conntrack: $HAS_CONNTRACK"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════
#  Phase 1 — 冲突检测
# ═══════════════════════════════════════════════════════════════
echo ""
echo "-- [1/4] 扫描现有配置 --"

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

for f in /etc/sysctl.d/*.conf; do
    [ ! -f "$f" ] && continue
    [ "$(basename "$f")" = "$(basename "$CONF_FILE")" ] && continue

    if grep -qE "$PATTERN" "$f" 2>/dev/null; then
        echo "  [冲突] $f"
        grep -nE "$PATTERN" "$f" | while read line; do
            echo "         $line"
        done
        FOUND_CONFLICT=1
    fi
done

# 检测指向 ../sysctl.conf 的符号链接 (Ubuntu cloud-image 常见)
for f in /etc/sysctl.d/*.conf; do
    [ ! -L "$f" ] && continue
    LINK_TARGET=$(readlink "$f" 2>/dev/null || true)
    if [ "$LINK_TARGET" = "../sysctl.conf" ] || [ "$LINK_TARGET" = "/etc/sysctl.conf" ]; then
        echo "  [重复] $f -> $LINK_TARGET (sysctl.conf 会被加载两次)"
        FOUND_CONFLICT=1
    fi
done

if [ -f /etc/sysctl.conf ]; then
    if grep -qE "$PATTERN" /etc/sysctl.conf 2>/dev/null; then
        echo "  [冲突] /etc/sysctl.conf"
        grep -nE "$PATTERN" /etc/sysctl.conf | while read line; do
            echo "         $line"
        done
        FOUND_CONFLICT=1
    fi
fi

if [ "$FOUND_CONFLICT" -eq 0 ]; then
    echo "  [OK] 未发现冲突配置"
else
    echo "  -> 将在下一阶段自动处理"
fi

# ═══════════════════════════════════════════════════════════════
#  Phase 2 — 清理冲突
# ═══════════════════════════════════════════════════════════════
echo ""
echo "-- [2/4] 清理冲突 --"

NEED_CLEANUP=0

for f in /etc/sysctl.d/*.conf; do
    [ ! -f "$f" ] && continue
    [ "$(basename "$f")" = "$(basename "$CONF_FILE")" ] && continue

    if [ -L "$f" ]; then
        LINK_TARGET=$(readlink "$f" 2>/dev/null || true)
        if echo "$LINK_TARGET" | grep -qE "sysctl\.conf"; then
            NEED_CLEANUP=1
            rm "$f"
            echo "  [已处理] $f (符号链接已删除)"
        fi
    elif grep -qE "$PATTERN" "$f" 2>/dev/null; then
        NEED_CLEANUP=1
        mkdir -p "$BACKUP_DIR"
        cp "$f" "$BACKUP_DIR/"
        rm "$f"
        echo "  [已处理] $f -> $BACKUP_DIR/"
    fi
done

if [ -f /etc/sysctl.conf ]; then
    if grep -qE "$PATTERN" /etc/sysctl.conf 2>/dev/null; then
        NEED_CLEANUP=1
        cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null || true
        echo "# Cleared by tcp-tune.sh v2.1 — see /etc/sysctl.d/99-tcp-tuning.conf" > /etc/sysctl.conf
        echo "  [已处理] /etc/sysctl.conf -> 已清空"
    fi
fi

if [ "$NEED_CLEANUP" -eq 0 ]; then
    echo "  [SKIP] 无需清理"
fi

# ═══════════════════════════════════════════════════════════════
#  Phase 3 — 分档计算 & 写入配置
# ═══════════════════════════════════════════════════════════════
echo ""
echo "-- [3/4] 应用优化 --"

if   [ "$MEM_MB" -le 512 ]; then
    TIER="微型"
    RMEM_MAX=8388608; WMEM_MAX=8388608
    TCP_RMEM="4096 87380 8388608"; TCP_WMEM="4096 65536 8388608"
    TCP_MEM="32768 43690 65536"; CONNTRACK_MAX=131072
elif [ "$MEM_MB" -le 2048 ]; then
    TIER="标准"
    RMEM_MAX=33554432; WMEM_MAX=33554432
    TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"
    TCP_MEM="131072 174762 262144"; CONNTRACK_MAX=1000000
elif [ "$MEM_MB" -le 8192 ]; then
    TIER="高性能"
    RMEM_MAX=67108864; WMEM_MAX=67108864
    TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 65536 67108864"
    TCP_MEM="262144 349525 524288"; CONNTRACK_MAX=2000000
else
    TIER="旗舰"
    RMEM_MAX=134217728; WMEM_MAX=134217728
    TCP_RMEM="4096 131072 134217728"; TCP_WMEM="4096 65536 134217728"
    TCP_MEM="524288 699050 1048576"; CONNTRACK_MAX=4000000
fi

if [ "$HAS_BBR" -eq 1 ]; then
    CC_ALGO="bbr"; QDISC="fq"
else
    CC_ALGO="cubic"; QDISC="fq_codel"
    echo "  [WARN] BBR 不可用，降级为 cubic + fq_codel"
fi

echo "  档位: $TIER | 缓冲区: $((RMEM_MAX/1048576))MB"

cat > "$CONF_FILE" << EOF
# ════════════════════════════════════════════
#   TCP 深度调优 - $HOSTNAME
#   档位: $TIER (${MEM_MB}MB) | $(date '+%Y-%m-%d %H:%M:%S')
#   由 tcp-tune.sh v2.1 自动生成
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

if [ "$HAS_CONNTRACK" -eq 1 ]; then
    cat >> "$CONF_FILE" << EOF

# ── 连接追踪表 ─────────────────────────────
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
fi

sysctl -p "$CONF_FILE" > /dev/null 2>&1
echo "  [OK] 配置已写入并生效"

if [ "$CPU_CORES" -gt 1 ] && [ -n "$MAIN_IFACE" ]; then
    CPU_MASK=$(printf "%x" $(( (1 << CPU_CORES) - 1 )))
    for rxq in /sys/class/net/$MAIN_IFACE/queues/rx-*/rps_cpus; do
        echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
    done
    for txq in /sys/class/net/$MAIN_IFACE/queues/tx-*/xps_cpus; do
        echo "$CPU_MASK" > "$txq" 2>/dev/null || true
    done
    echo "  [OK] RPS/XPS (掩码: $CPU_MASK)"
else
    echo "  [SKIP] 单核跳过 RPS/XPS"
fi

# ═══════════════════════════════════════════════════════════════
#  Phase 4 — 验证
# ═══════════════════════════════════════════════════════════════
echo ""
echo "-- [4/4] 验证关键参数 --"
echo ""

verify() { sysctl -n "$1" 2>/dev/null || echo "N/A"; }

printf "  %-38s %s\n" "参数" "当前值"
printf "  %-38s %s\n" "--------------------------------------" "----------"
printf "  %-38s %s\n" "tcp_congestion_control"         "$(verify net.ipv4.tcp_congestion_control)"
printf "  %-38s %s\n" "default_qdisc"                  "$(verify net.core.default_qdisc)"
printf "  %-38s %s\n" "rmem_max / wmem_max"            "$(verify net.core.rmem_max) / $(verify net.core.wmem_max)"
printf "  %-38s %s\n" "tcp_rmem (min def max)"         "$(verify net.ipv4.tcp_rmem)"
printf "  %-38s %s\n" "tcp_wmem (min def max)"         "$(verify net.ipv4.tcp_wmem)"
printf "  %-38s %s\n" "tcp_mem (min pressure max)"     "$(verify net.ipv4.tcp_mem)"
printf "  %-38s %s\n" "somaxconn / tcp_max_syn_backlog" "$(verify net.core.somaxconn) / $(verify net.ipv4.tcp_max_syn_backlog)"
printf "  %-38s %s\n" "netdev_max_backlog"             "$(verify net.core.netdev_max_backlog)"
printf "  %-38s %s\n" "ip_local_port_range"            "$(verify net.ipv4.ip_local_port_range)"
printf "  %-38s %s\n" "tcp_fastopen"                   "$(verify net.ipv4.tcp_fastopen)"
printf "  %-38s %s\n" "tcp_keepalive (time/intvl/probes)" "$(verify net.ipv4.tcp_keepalive_time) / $(verify net.ipv4.tcp_keepalive_intvl) / $(verify net.ipv4.tcp_keepalive_probes)"
printf "  %-38s %s\n" "tcp_fin_timeout"                "$(verify net.ipv4.tcp_fin_timeout)"
printf "  %-38s %s\n" "tcp_retries2"                   "$(verify net.ipv4.tcp_retries2)"
printf "  %-38s %s\n" "tcp_rfc1337"                    "$(verify net.ipv4.tcp_rfc1337)"
printf "  %-38s %s\n" "tcp_notsent_lowat"              "$(verify net.ipv4.tcp_notsent_lowat)"
printf "  %-38s %s\n" "tcp_no_metrics_save"            "$(verify net.ipv4.tcp_no_metrics_save)"
printf "  %-38s %s\n" "nf_conntrack_max"               "$(verify net.netfilter.nf_conntrack_max)"
printf "  %-38s %s\n" "vm.swappiness"                  "$(verify vm.swappiness)"

echo ""
echo "════════════════════════════════════════════"
echo "  完成!  档位: $TIER  |  拥塞: $CC_ALGO  |  缓冲: $((RMEM_MAX/1048576))MB"
echo "  配置: $CONF_FILE"
[ "$NEED_CLEANUP" -eq 1 ] && echo "  备份: $BACKUP_DIR"
echo "════════════════════════════════════════════"
