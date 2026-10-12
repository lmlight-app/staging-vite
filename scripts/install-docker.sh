#!/bin/bash
# DigitalBase Docker installer
#
#   curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-docker.sh | bash
#   curl -fsSL .../install-docker.sh | bash -s -- --platform cuda        # vLLM も同じ stack で (NVIDIA)。AMD は rocm、Intel は xpu
#   curl -fsSL .../install-docker.sh | bash -s -- --version 26.1010.3     # 版を固定
#   curl -fsSL .../install-docker.sh | bash -s -- --port 8080
#
# 再実行 = 更新 (compose ファイルを最新にして pull → up。.env と data/ postgres-data/ hf-cache/ はそのまま)。
set -euo pipefail

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/digitalbase}"
BASE_URL="${DB_SCRIPTS_URL:-https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts}"
PLATFORM="${DB_PLATFORM:-}"
VERSION="${DB_VERSION:-}"
PORT_ARG="${APP_PORT:-}"

usage() {
    cat << 'USAGE'
Usage: install-docker.sh [--platform none|cuda|rocm|xpu] [--version VERSION] [--port PORT]
  --platform  vLLM in the same stack: cuda (NVIDIA) | rocm (AMD) | xpu (Intel) | none (default: as recorded in .env, else none; env DB_PLATFORM)
  --version   DigitalBase version: latest | YY.MMDD[.N] | xYYYYMMDD[.N] (default: as recorded in .env, else latest; env DB_VERSION)
  --port      host port (default: as recorded in .env, else 8000; env APP_PORT)
  env DB_INSTALL_DIR (default ~/digitalbase)
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:?--platform requires none|cuda|rocm|xpu}"; shift ;;
        --version) VERSION="${2:?--version requires latest|YY.MMDD[.N]|xYYYYMMDD[.N]}"; shift ;;
        --port) PORT_ARG="${2:?--port requires a number}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done
case "$PLATFORM" in ""|none|cuda|rocm|xpu) ;; *) echo "[ERROR] --platform must be none, cuda, rocm or xpu (got: $PLATFORM)"; exit 2 ;; esac
if [ -n "$VERSION" ]; then
    printf '%s' "$VERSION" | grep -Eq '^(latest|[0-9]{2}\.[0-9]{4}(\.[0-9]+)?|x[0-9]{8}(\.[0-9]+)?)$' \
        || { echo "[ERROR] --version must be latest, a version (YY.MMDD[.N]), or a release tag (xYYYYMMDD[.N])"; exit 2; }
fi
if [ -n "$PORT_ARG" ]; then
    printf '%s' "$PORT_ARG" | grep -Eq '^[0-9]{1,5}$' || { echo "[ERROR] --port must be a number (got: $PORT_ARG)"; exit 2; }
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker is not installed: https://docs.docker.com/get-docker/"; exit 1; }
docker info >/dev/null 2>&1 || { echo "[ERROR] The Docker daemon is not running (Linux: sudo systemctl start docker / Mac・Windows: start Docker Desktop)"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "[ERROR] docker compose (v2) is not installed: https://docs.docker.com/compose/install/"; exit 1; }
COMPOSE_VER="$(docker compose version --short 2>/dev/null | sed 's/^v//; s/[^0-9.].*//')"
if [ "$(printf '%s\n' "2.24.0" "$COMPOSE_VER" | sort -V | head -1)" != "2.24.0" ]; then
    echo "[ERROR] docker compose $COMPOSE_VER is too old (2.24 or later is required)"; exit 1
fi

mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/postgres-data"
cd "$INSTALL_DIR"
for f in docker-compose.yml docker.env.example; do
    curl -fsSL "$BASE_URL/$f" -o "$f.tmp" || { rm -f "$f.tmp"; echo "[ERROR] Could not download $f ($BASE_URL)"; exit 1; }
    mv "$f.tmp" "$f"
done
rm -f docker-compose.vllm.yml docker-compose.vllm-rocm.yml docker-compose.vllm-xpu.yml

env_get() {
    [ -f .env ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v) } END { print v }' .env
}
env_set() {
    if grep -q "^$1=" .env && [ "$(env_get "$1")" = "$2" ]; then return 0; fi
    awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' .env > .env.tmp
    mv .env.tmp .env
}
env_unset() { awk -v k="$1" 'index($0, k "=") != 1' .env > .env.tmp; mv .env.tmp .env; }

if [ ! -f .env ]; then
    cp docker.env.example .env
    env_set DB_PASSWORD "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "[OK] Created $INSTALL_DIR/.env"
fi

[ -n "$PLATFORM" ] || PLATFORM="$(env_get COMPOSE_PROFILES)"
case "$PLATFORM" in cuda|rocm|xpu) ;; *) PLATFORM=none ;; esac
case "$PLATFORM:$(uname -m)" in rocm:aarch64|rocm:arm64|xpu:aarch64|xpu:arm64) echo "[ERROR] the $PLATFORM image of vLLM is x86_64 only"; exit 2 ;; esac
if [ "$PLATFORM" = "none" ]; then
    [ -z "$(env_get COMPOSE_PROFILES)" ] || env_set COMPOSE_PROFILES ""
    if [ "$(env_get VLLM_BASE_URL)" = "http://vllm-chat:8000" ]; then
        env_set LLM_BACKEND ollama
        env_unset VLLM_BASE_URL
        env_unset VLLM_EMBED_BASE_URL
    fi
else
    env_set COMPOSE_PROFILES "$PLATFORM"
    env_set LLM_BACKEND vllm
    env_set VLLM_BASE_URL "http://vllm-chat:8000"
    env_set VLLM_EMBED_BASE_URL "http://vllm-embed:8000"
fi
case "$VERSION" in
    "") ;;
    latest) env_unset DB_IMAGE_TAG ;;
    x*) env_set DB_IMAGE_TAG "${VERSION#x}" ;;
    *) env_set DB_IMAGE_TAG "$(printf '%s' "$VERSION" | sed -E 's/^([0-9]{2})\.([0-9]{4})/20\1\2/')" ;;
esac
[ -z "$PORT_ARG" ] || env_set APP_PORT "$PORT_ARG"
PORT="$(env_get APP_PORT)"; PORT="${PORT:-8000}"

case "$PLATFORM" in
    cuda) docker info 2>/dev/null | grep -qi nvidia || echo "[WARN] NVIDIA Container Toolkit not found: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/" ;;
    rocm) [ -e /dev/kfd ] || echo "[WARN] /dev/kfd not found: install the AMD GPU driver (amdgpu) on the host" ;;
    xpu)  ls /dev/dri/renderD* >/dev/null 2>&1 || echo "[WARN] /dev/dri not found: install the Intel GPU driver on the host" ;;
esac

TAG="$(env_get DB_IMAGE_TAG)"
echo "DigitalBase (Docker): $INSTALL_DIR, port $PORT, image ${TAG:-latest}, vLLM $PLATFORM"
ACTIVE="$(docker compose config --services)"
for service in $(docker compose --profile '*' config --services); do
    printf '%s\n' "$ACTIVE" | grep -qx "$service" && continue
    if [ -n "$(docker compose --profile '*' ps -aq "$service" 2>/dev/null)" ]; then docker compose --profile '*' rm -sf "$service"; fi
done
docker compose pull
docker compose up -d --remove-orphans

printf 'Waiting for the app'
for i in $(seq 1 90); do
    if curl -fs -m 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then echo " [OK]"; break; fi
    printf '.'; sleep 2
    [ "$i" = 90 ] && echo " (no response yet: docker compose logs -f app)"
done
[ "$PLATFORM" = "none" ] || echo "vLLM loads the models in the background (first start downloads them): docker compose logs -f vllm-chat-$PLATFORM"

cat << EOF

[OK] DigitalBase  http://localhost:$PORT   (admin@local / admin123)
  settings : $INSTALL_DIR/.env
  data     : $INSTALL_DIR/data, postgres-data, hf-cache
  license  : put it at $INSTALL_DIR/data/license.lic (or upload it in Admin > License)
  cd $INSTALL_DIR && docker compose logs -f app | down | up -d
  update   : run this installer again
EOF
