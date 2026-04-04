#!/usr/bin/env bash

set -Eeuo pipefail

DEFAULT_INSTALL_DIR="/opt/gpt-register-oss"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
BRANCH="main"
REPO_URL=""
PROJECT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  ./install_server.sh
  ./install_server.sh --repo https://github.com/<user>/<repo>.git [--dir /opt/gpt-register-oss] [--branch main]

Behavior:
  1. On Debian/Ubuntu, installs git and Docker Compose if missing
  2. Clones or updates the repository when --repo is provided
  3. Creates .env and docker-data/backend/config.json if missing
  4. Starts the project with docker compose

Examples:
  ./install_server.sh
  ./install_server.sh --repo https://github.com/example/gpt-register-oss.git --dir /opt/gpt-register-oss
EOF
}

log() {
  printf '[install] %s\n' "$*"
}

die() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    die "需要 root 或 sudo 权限来安装系统依赖: $*"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo 需要一个 Git 地址"
        REPO_URL="$2"
        shift 2
        ;;
      --dir)
        [[ $# -ge 2 ]] || die "--dir 需要一个安装目录"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 ]] || die "--branch 需要一个分支名"
        BRANCH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

ensure_supported_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统，当前脚本只支持 Debian/Ubuntu 自动安装依赖"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      die "当前脚本仅内置 Debian/Ubuntu 自动安装逻辑，检测到系统: ${PRETTY_NAME:-unknown}"
      ;;
  esac
}

install_base_packages() {
  log "安装基础依赖: git, curl, ca-certificates, gnupg"
  run_as_root apt-get update
  run_as_root apt-get install -y ca-certificates curl gnupg git
}

install_docker_if_missing() {
  local need_docker=0

  if ! command_exists docker; then
    need_docker=1
  elif ! docker compose version >/dev/null 2>&1; then
    need_docker=1
  fi

  if [[ "$need_docker" -eq 0 ]]; then
    log "检测到 Docker 和 Docker Compose"
    return
  fi

  ensure_supported_os
  install_base_packages

  # shellcheck disable=SC1091
  . /etc/os-release

  log "安装 Docker Engine 和 Docker Compose"
  run_as_root install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    run_as_root curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    run_as_root chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local arch codename docker_list
  arch="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die "无法识别系统代号 VERSION_CODENAME"
  docker_list="/etc/apt/sources.list.d/docker.list"

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$ID" "$codename" | run_as_root tee "$docker_list" >/dev/null

  run_as_root apt-get update
  run_as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_as_root systemctl enable --now docker

  if [[ -n "${SUDO_USER:-}" ]]; then
    run_as_root usermod -aG docker "$SUDO_USER" || true
  elif [[ "${EUID:-$(id -u)}" -eq 0 && -n "${USER:-}" && "${USER}" != "root" ]]; then
    run_as_root usermod -aG docker "$USER" || true
  fi
}

ensure_git_if_missing() {
  if command_exists git; then
    return
  fi

  ensure_supported_os
  install_base_packages
}

resolve_project_dir() {
  if [[ -f "./docker-compose.yml" && -f "./config.example.json" ]]; then
    PROJECT_DIR="$(pwd)"
    log "检测到当前目录就是项目目录: $PROJECT_DIR"
    return
  fi

  [[ -n "$REPO_URL" ]] || die "当前目录不是项目目录时，需要通过 --repo 提供 GitHub 仓库地址"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    PROJECT_DIR="$INSTALL_DIR"
    log "更新已有仓库: $PROJECT_DIR"
    git -C "$PROJECT_DIR" fetch --all --tags
    git -C "$PROJECT_DIR" checkout "$BRANCH"
    git -C "$PROJECT_DIR" pull --ff-only origin "$BRANCH"
    return
  fi

  if [[ -e "$INSTALL_DIR" && -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "安装目录不是空目录，且不是一个 Git 仓库: $INSTALL_DIR"
  fi

  mkdir -p "$INSTALL_DIR"
  log "克隆仓库到: $INSTALL_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  PROJECT_DIR="$INSTALL_DIR"
}

ensure_runtime_files() {
  local data_dir
  data_dir="$PROJECT_DIR/docker-data/backend"

  mkdir -p "$data_dir"

  if [[ ! -f "$PROJECT_DIR/.env" && -f "$PROJECT_DIR/.env.example" ]]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    log "已生成 $PROJECT_DIR/.env"
  fi

  if [[ ! -f "$data_dir/config.json" ]]; then
    cp "$PROJECT_DIR/config.example.json" "$data_dir/config.json"
    log "已生成 $data_dir/config.json"
  fi
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return
  fi

  if command_exists sudo && sudo docker compose version >/dev/null 2>&1; then
    sudo docker compose "$@"
    return
  fi

  die "Docker Compose 不可用，请确认 docker compose 已安装"
}

start_services() {
  log "构建并启动服务"
  (
    cd "$PROJECT_DIR"
    docker_compose_cmd up -d --build
  )
}

show_next_steps() {
  local host_ip token_hint
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  token_hint="$PROJECT_DIR/docker-data/backend/admin_token.txt"

  printf '\n'
  log "部署完成"
  printf '项目目录: %s\n' "$PROJECT_DIR"
  printf '配置文件: %s\n' "$PROJECT_DIR/docker-data/backend/config.json"
  printf '管理 token: %s\n' "$token_hint"
  if [[ -n "$host_ip" ]]; then
    printf '访问地址: http://%s:8080\n' "$host_ip"
  else
    printf '访问地址: http://<服务器IP>:8080\n'
  fi
  printf '\n'
  printf '后续建议:\n'
  printf '1. 先编辑 %s，填入真实的 clean/mail 等配置。\n' "$PROJECT_DIR/docker-data/backend/config.json"
  printf '2. 用下面命令查看服务状态: cd %s && docker compose ps\n' "$PROJECT_DIR"
  printf '3. 首次登录前端时，读取 %s 里的 token。\n' "$token_hint"
}

parse_args "$@"
install_docker_if_missing
ensure_git_if_missing
resolve_project_dir
ensure_runtime_files
start_services
show_next_steps
