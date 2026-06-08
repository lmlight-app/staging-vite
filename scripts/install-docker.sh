#!/bin/bash
# AI Server Docker Installer
# 使い方:
#   curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-docker.sh | bash                # vLLM 版 (= 既定。外部 vLLM サーバ前提)
#   curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-docker.sh | EDITION=ollama bash # Ollama 版
set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/digitalbase}"
EDITION="${EDITION:-vllm}"                    # vllm (既定) | ollama
DOCKER_USER="${DOCKER_USER:-lmlight}"
IMAGE="${DB_IMAGE:-$DOCKER_USER/digitalbase:latest}"
APP_CONTAINER="${APP_CONTAINER:-digitalbase-app}"
PG_CONTAINER="${PG_CONTAINER:-digitalbase-postgres}"
APP_PORT="${APP_PORT:-8000}"
# DB 接続情報は env で上書き可 (DB_USER/DB_PASS/DB_NAME)、既定 digitalbase。PG container 作成と DATABASE_URL で共通。
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

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
    OAUTH_ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || date +%s%N | sha256sum | cut -c1-64)
    cat > "$INSTALL_DIR/.env" << EOF
# AI Server Configuration ($EDITION edition / Docker)

# Backend selection
LLM_BACKEND=$EDITION

# PostgreSQL (= 同一 docker network 内の digitalbase-postgres container)
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@$PG_CONTAINER:5432/${DB_NAME}

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
OAUTH_ENCRYPTION_KEY=$OAUTH_ENCRYPTION_KEY
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
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASS" \
        -e POSTGRES_DB="$DB_NAME" \
        -v "$INSTALL_DIR/postgres-data:/var/lib/postgresql/data" \
        pgvector/pgvector:pg16 >/dev/null
    # PG 起動待ち
    echo "   PostgreSQL 起動待機中..."
    for i in $(seq 1 30); do
        if docker exec "$PG_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
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

# ── 7. アプリ container 起動 (= db-docker は廃止。操作は素の docker) ────
echo ""
echo "🚀 アプリ container 起動..."
# 既存 app container があれば作り直す (= data は volume に残るので安全)
docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
# --add-host: Linux で host.docker.internal を有効化 (= Mac/Win は default で有効)
docker run -d --name "$APP_CONTAINER" --restart unless-stopped \
    --network "$NETWORK" \
    --add-host=host.docker.internal:host-gateway \
    -p "$APP_PORT:8000" \
    --env-file "$INSTALL_DIR/.env" \
    -v "$INSTALL_DIR:/app/data" \
    "$IMAGE"

echo ""
echo "============================================"
echo "  ✅ Installation complete"
echo "============================================"
echo "  URL     : http://localhost:$APP_PORT"
echo "  env     : $INSTALL_DIR/.env"
echo "  data    : $INSTALL_DIR/files, $INSTALL_DIR/postgres-data"
echo ""
echo "  操作 (素の docker):"
echo "    docker logs -f $APP_CONTAINER     # ログ"
echo "    docker stop $APP_CONTAINER        # 停止"
echo "    docker start $APP_CONTAINER       # 起動"
echo "    更新   : docker pull $IMAGE → install を再実行 (data 保持)"
echo "    license: cp <license.lic> $INSTALL_DIR/license.lic && docker restart $APP_CONTAINER"
echo "============================================"
