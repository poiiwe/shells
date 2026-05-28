#!/bin/bash
# ============================================================
# Remnawave Node 一键安装脚本
# 适用系统: Debian / Ubuntu
# 功能: 安装 Docker、配置 Docker、部署 remnawave-node
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────────
# 颜色输出
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "${CYAN}━━━ $* ━━━${NC}"; }

# ──────────────────────────────────────────────
# 退出陷阱 —— 任何非零退出时打印提示
# ──────────────────────────────────────────────
trap 'warn "脚本意外退出，请检查上方错误信息。"' ERR

# ──────────────────────────────────────────────
# 1. 检查是否为 root 用户
# ──────────────────────────────────────────────
step "检查运行权限"

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户或通过 sudo 运行此脚本。"
    exit 1
fi
info "已确认 root 权限"

# ──────────────────────────────────────────────
# 2. 检查操作系统（仅 Debian / Ubuntu）
# ──────────────────────────────────────────────
step "检查操作系统"

if [[ ! -f /etc/os-release ]]; then
    error "无法识别当前操作系统（缺少 /etc/os-release）。仅支持 Debian 和 Ubuntu。"
    exit 1
fi

source /etc/os-release

case "$ID" in
    debian|ubuntu)
        info "系统: $NAME $VERSION_ID"
        ;;
    *)
        error "当前系统 ($ID) 不是 Debian 或 Ubuntu。脚本仅支持这两类发行版。"
        exit 1
        ;;
esac

# ──────────────────────────────────────────────
# 3. 安装 Docker
# ──────────────────────────────────────────────
step "安装 Docker"

if command -v docker &>/dev/null; then
    info "Docker 已安装，跳过安装步骤。"
else
    info "正在安装依赖并执行 Docker 官方安装脚本..."
    apt update -y
    apt install -y curl ca-certificates
    curl -fsSL https://get.docker.com | sh
    info "Docker 安装完成"
fi

# ──────────────────────────────────────────────
# 4. 配置 Docker daemon
# ──────────────────────────────────────────────
step "配置 Docker daemon"

DOCKER_CONFIG="/etc/docker/daemon.json"

if [[ -f "$DOCKER_CONFIG" ]]; then
    warn "$DOCKER_CONFIG 已存在，将备份为 daemon.json.bak"
    cp "$DOCKER_CONFIG" "${DOCKER_CONFIG}.bak"
fi

cat > "$DOCKER_CONFIG" <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "dns": [
        "1.1.1.1",
        "8.8.8.8"
    ],
    "ipv6": true,
    "fixed-cidr-v6": "fd00::/64",
    "experimental": true,
    "ip6tables": true
}
EOF

info "Docker 配置文件已写入 $DOCKER_CONFIG"

# ──────────────────────────────────────────────
# 5. 启动 Docker 并设置开机自启
# ──────────────────────────────────────────────
step "启动 Docker 服务"

systemctl start docker
systemctl enable docker
info "Docker 服务已启动并已设置为开机自启"

# ──────────────────────────────────────────────
# 6. 配置 docker-compose 命令
# ──────────────────────────────────────────────
step "配置 docker-compose 命令"

if command -v docker-compose &>/dev/null; then
    info "docker-compose 命令已可用"
elif [[ -x /usr/libexec/docker/cli-plugins/docker-compose ]]; then
    ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose
    info "已创建 docker-compose 软链接"
else
    warn "未找到 docker compose CLI 插件，将在后续通过 'docker compose' 方式运行。"
fi

# 验证 docker compose 可用
if docker compose version &>/dev/null; then
    info "Docker Compose 插件可用: $(docker compose version)"
else
    error "Docker Compose 不可用，请检查 Docker 安装。"
    exit 1
fi

# ──────────────────────────────────────────────
# 7. 获取 SECRET_KEY
# ──────────────────────────────────────────────
step "配置 SECRET_KEY"

SECRET_KEY=""
while [[ -z "$SECRET_KEY" ]]; do
    echo -n "请输入 SECRET_KEY（不能为空）: "
    read -r SECRET_KEY
    if [[ -z "$SECRET_KEY" ]]; then
        warn "SECRET_KEY 不能为空，请重新输入。"
    fi
done

# ──────────────────────────────────────────────
# 8. 部署 remnawave-node
# ──────────────────────────────────────────────
step "部署 remnawave-node"

NODE_DIR="/opt/remnanode"
mkdir -p "$NODE_DIR"

# 写入 .env
cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=9527
SECRET_KEY="$SECRET_KEY"
EOF
info "环境变量文件已创建: $NODE_DIR/.env"

# 写入 docker-compose.yml
cat > "$NODE_DIR/docker-compose.yml" <<'EOF'
services:
    remnanode:
        container_name: remnanode
        hostname: remnanode
        image: remnawave/node:latest
        restart: always
        network_mode: host
        env_file:
            - .env
        cap_add:
            - NET_ADMIN
EOF
info "docker-compose.yml 已创建"

# ──────────────────────────────────────────────
# 9. 启动容器
# ──────────────────────────────────────────────
step "启动 remnawave-node 容器"

cd "$NODE_DIR"
docker compose up -d
info "remnawave-node 已启动"

# ──────────────────────────────────────────────
# 10. 显示日志
# ──────────────────────────────────────────────
step "容器日志（按 Ctrl+C 退出日志查看）"
echo ""
docker compose logs -f -t

