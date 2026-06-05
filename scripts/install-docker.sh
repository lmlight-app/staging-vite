#!/bin/bash
# AI Server Docker Installer
# 使い方:
#   curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-docker.sh | bash
#   EDITION=vllm bash install-docker.sh           # vLLM 版 (= Linux + CUDA)
set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
EDITION="${EDITION:-ollama}"                  # ollama | vllm
DOCKER_USER="${DOCKER_USER:-lmlight}"
IMAGE="${DB_IMAGE:-$DOCKER_USER/digitalbase-$EDITION:latest}"
APP_CONTAINER="${APP_CONTAINER:-digitalbase-app}"
PG_CONTAINER="${PG_CONTAINER:-digitalbase-postgres}"
APP_PORT="${APP_PORT:-8000}"

echo "============================================"
echo "  AI Server Docker Installer"
echo "============================================"
echo "  edition       : $EDITION"
echo "  image         : $IMAGE"
echo "  install dir   : $INSTALL_DIR"
echo "  port          : $APP_PORT"
echo ""

# ── 1. Preflight ────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || {
    echo "❌ Docker が install されていません"
    echo "   https://docs.docker.com/get-docker/ から install してください"
    exit 1
}
docker info >/dev/null 2>&1 || {
    echo "❌ Docker daemon が起動していません"
    echo "   Linux: sudo systemctl start docker"
    echo "   Mac/Win: Docker Desktop を起動してください"
    exit 1
}

# Port 競合 check
if lsof -i ":$APP_PORT" >/dev/null 2>&1 || ss -tln 2>/dev/null | grep -q ":$APP_PORT "; then
    echo "⚠️  Port $APP_PORT 既に使用中です。別 port を指定するには APP_PORT=8001 で再実行してください"
    read -p "  続行しますか? [y/N]: " yn
    [ "$yn" != "y" ] && exit 1
fi

# ── 2. Pull image ───────────────────────────────────────────────────────
echo "📥 Image pull 中..."
docker pull "$IMAGE" || {
    echo "❌ Image pull 失敗。確認事項:"
    echo "   - Docker Hub にアクセスできるか (= proxy / 認証)"
    echo "   - image 名: $IMAGE"
    exit 1
}

# ── 3. Directory + .env setup ──────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/files" "$INSTALL_DIR/postgres-data"

if [ ! -f "$INSTALL_DIR/.env" ]; then
    JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || date +%s%N | sha256sum | cut -c1-64)
    cat > "$INSTALL_DIR/.env" << EOF
# AI Server Configuration ($EDITION edition / Docker)

# Backend selection
LLM_BACKEND=$EDITION

# PostgreSQL (= 同一 docker network 内の digitalbase-postgres container)
DATABASE_URL=postgresql://digitalbase:digitalbase@$PG_CONTAINER:5432/digitalbase

# Ollama / vLLM endpoint (= container 内から host へは host.docker.internal)
OLLAMA_BASE_URL=http://host.docker.internal:11434
OLLAMA_AUTO_START=false
VLLM_BASE_URL=http://host.docker.internal:8080
VLLM_EMBED_BASE_URL=http://host.docker.internal:8081
VLLM_AUTO_START=false

# License / Files
LICENSE_FILE_PATH=/app/data/license.lic
FILES_DIR=/app/data/files

# Server
API_HOST=0.0.0.0
API_PORT=8000
JWT_SECRET=$JWT_SECRET
AUTH_MODE=local

# Cloud LLM (= API key 設定で有効化)
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# GEMINI_API_KEY=
EOF
    echo "✅ .env 生成完了: $INSTALL_DIR/.env"
else
    echo "ℹ️  既存 .env を保持: $INSTALL_DIR/.env (= 上書きしません)"
fi

# ── 4. Docker network ──────────────────────────────────────────────────
NETWORK="${DB_NETWORK:-digitalbase-net}"
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

# ── 5. PostgreSQL container (= pgvector 同梱) ──────────────────────────
if ! docker ps -a --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
    echo "📦 PostgreSQL (pgvector) container 起動..."
    docker run -d --name "$PG_CONTAINER" --restart unless-stopped \
        --network "$NETWORK" \
        -e POSTGRES_USER=digitalbase \
        -e POSTGRES_PASSWORD=digitalbase \
        -e POSTGRES_DB=digitalbase \
        -v "$INSTALL_DIR/postgres-data:/var/lib/postgresql/data" \
        pgvector/pgvector:pg16 >/dev/null
    # PG 起動待ち
    echo "   PostgreSQL 起動待機中..."
    for i in $(seq 1 30); do
        if docker exec "$PG_CONTAINER" pg_isready -U digitalbase >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec "$PG_CONTAINER" psql -U digitalbase -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
    echo "✅ PostgreSQL 準備完了"
else
    docker start "$PG_CONTAINER" >/dev/null 2>&1 || true
    echo "ℹ️  既存 PostgreSQL container 利用: $PG_CONTAINER"
fi

# ── 6. License 配置案内 ────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/license.lic" ]; then
    echo ""
    echo "📜 ライセンス配置オプション (= 起動後でも upload 可):"
    echo "   A. 事前配置:  cp <license.lic> $INSTALL_DIR/license.lic"
    echo "   B. 起動後 UI: http://localhost:$APP_PORT > admin > ライセンス"
    echo "   C. 起動後 API: POST /api/admin/license -F file=@license.lic"
    echo ""
fi

# ── 7. db-docker CLI wrapper 生成 ──────────────────────────────────────
cat > "$INSTALL_DIR/db-docker" << EOF
#!/bin/bash
# AI Server Docker control
APP="$APP_CONTAINER"
PG="$PG_CONTAINER"
IMAGE="$IMAGE"
INSTALL_DIR="$INSTALL_DIR"
NETWORK="$NETWORK"
APP_PORT="$APP_PORT"

start_app() {
    if docker ps --format '{{.Names}}' | grep -q "^\$APP\$"; then
        echo "✅ Already running"
    elif docker ps -a --format '{{.Names}}' | grep -q "^\$APP\$"; then
        docker start "\$APP"
        echo "✅ Started"
    else
        # Linux で host.docker.internal を有効化 (= Mac/Win は default で有効)
        EXTRA_HOST="--add-host=host.docker.internal:host-gateway"
        docker run -d --name "\$APP" --restart unless-stopped \\
            --network "\$NETWORK" \\
            \$EXTRA_HOST \\
            -p \$APP_PORT:8000 \\
            --env-file "\$INSTALL_DIR/.env" \\
            -v "\$INSTALL_DIR:/app/data" \\
            "\$IMAGE"
        echo "✅ Started"
    fi
    echo "🌐 URL: http://localhost:\$APP_PORT"
}

case "\$1" in
    start)   start_app ;;
    stop)    docker stop "\$APP" 2>/dev/null && echo "✅ Stopped" ;;
    restart) docker restart "\$APP" 2>/dev/null && echo "✅ Restarted" ;;
    logs)    docker logs -f "\$APP" ;;
    status)  docker ps -a --filter "name=\$APP" --filter "name=\$PG" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
    pull)    docker pull "\$IMAGE" && echo "✅ Pulled (= db-docker restart で反映)" ;;
    upload-license)
        [ -z "\$2" ] && { echo "Usage: db-docker upload-license <license.lic>"; exit 1; }
        cp "\$2" "\$INSTALL_DIR/license.lic" && echo "✅ License placed at \$INSTALL_DIR/license.lic"
        echo "   db-docker restart で反映"
        ;;
    *) echo "Usage: db-docker {start|stop|restart|logs|status|pull|upload-license <file>}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db-docker"

# Try symlink to /usr/local/bin
sudo ln -sf "$INSTALL_DIR/db-docker" /usr/local/bin/db-docker 2>/dev/null || \
    echo "ℹ️  symlink 作成失敗 (= 直接 $INSTALL_DIR/db-docker で実行可能)"

# ── 8. 起動 ────────────────────────────────────────────────────────────
echo ""
echo "🚀 アプリ container 起動..."
"$INSTALL_DIR/db-docker" start

echo ""
echo "============================================"
echo "  ✅ Installation complete"
echo "============================================"
echo "  URL          : http://localhost:$APP_PORT"
echo "  control cmd  : db-docker {start|stop|restart|logs|status|pull|upload-license}"
echo "  env file     : $INSTALL_DIR/.env"
echo "  data         : $INSTALL_DIR/files, $INSTALL_DIR/postgres-data"
echo "============================================"
