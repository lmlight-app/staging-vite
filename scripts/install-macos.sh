#!/bin/bash
# AI Server Installer for macOS (Vite Edition)
# Single binary with embedded frontend - no Node.js required
set -e

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac

echo "Installing AI Server Vite Edition ($ARCH) to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

[ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true

# Download single binary (API + frontend embedded)
echo "Downloading AI Server..."
curl -fSL "$BASE_URL/lmlight-vite-macos-$ARCH" -o "$INSTALL_DIR/api"
chmod +x "$INSTALL_DIR/api"

# uv 仕込み (= YOLO / transcribe / plugin install を将来即実行できるようにする)
# venv は作らない (= 各 optional install script が lazy に作る、容量影響なし)
if ! command -v uv &>/dev/null; then
    echo "Installing uv (= optional features の前提)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || echo "⚠️  uv install 失敗。後で: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# DB 接続情報は env で上書き可 (DB_USER/DB_PASS/DB_NAME)、既定 digitalbase。
# 既存 .env がある場合は下の Database setup でその DATABASE_URL を正とする。
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
# =============================================================================
# AI Server Configuration (Vite Edition)
# =============================================================================

# Backend selection (= unified codebase で env で切替)
LLM_BACKEND=ollama

# PostgreSQL Database
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}

# Ollama 設定 (= daemon-native env、ollama serve が直接読む)
OLLAMA_BASE_URL=http://localhost:11434
# Ollama daemon の num_ctx 上書き (default 2048 → 16384) - document 出力切れ防止
OLLAMA_CONTEXT_LENGTH=16384
# 起動時に Ollama daemon を auto-spawn (= 1-click 起動向け、false にすると外部 daemon 想定)
OLLAMA_AUTO_START=true

# License
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic

# File Storage (pipeline uploads/outputs)
FILES_DIR=$INSTALL_DIR/files

# =============================================================================
# Server Configuration (API + Web on single port)
# =============================================================================
API_HOST=0.0.0.0
API_PORT=8000

# =============================================================================
# Authentication
# =============================================================================
JWT_SECRET=$(openssl rand -hex 32)
AUTH_MODE=local

# LDAP (AUTH_MODE=ldap)
# LDAP_HOST=your-ad-server.company.local
# LDAP_PORT=389
# LDAP_USE_SSL=false
# LDAP_BASE_DN=dc=company,dc=local
# LDAP_USER_DN_FORMAT={username}@company.local
# LDAP_BIND_DN=
# LDAP_BIND_PASSWORD=

# OIDC / Azure AD (AUTH_MODE=oidc)
# OIDC_CLIENT_ID=
# OIDC_CLIENT_SECRET=
# OIDC_TENANT_ID=

# =============================================================================
# Cloud LLM Providers (optional — set API key to enable)
# =============================================================================
# OPENAI_API_KEY=
# OPENAI_BASE_URL=https://api.openai.com/v1
# ANTHROPIC_API_KEY=
# GEMINI_API_KEY=

# =============================================================================
# Web Search (default OFF — set true to enable)
# =============================================================================
# WEB_SEARCH_ENABLED=false
# WEB_SEARCH_ENGINE=duckduckgo
# WEB_SEARCH_SEARXNG_URL=http://localhost:8888
# WEB_SEARCH_MAX_RESULTS=3

# =============================================================================
# Whisper Transcription (MPS auto-detected on Apple Silicon)
# Install model first: install-transcribe.sh [tiny|base|small|medium|large]
# =============================================================================
# WHISPER_MODEL=tiny
EOF

# Database setup
if [ -f "$INSTALL_DIR/.env" ]; then
    _DB_URL=$(grep -E "^DATABASE_URL=" "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)
    if [ -n "$_DB_URL" ]; then
        export DB_USER=$(echo "$_DB_URL" | sed -n 's|.*://\([^:]*\):.*|\1|p')
        export DB_PASS=$(echo "$_DB_URL" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
        export DB_NAME=$(echo "$_DB_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')
    fi
fi
# ── DB bootstrap (= superuser でしかできない 3 つだけ。schema / table / index /
# column 追加 / 初期 admin user は backend 起動時の migrations.py が冪等に作成) ──
echo "Setting up database (bootstrap only)..."
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

if ! command -v psql &>/dev/null; then
    echo "❌ PostgreSQL がインストールされていません。"
    echo "   brew install postgresql@16"
    echo "   brew services start postgresql@16"
    exit 1
fi
if ! pg_isready -q 2>/dev/null; then
    echo "❌ PostgreSQL に接続できません (localhost:5432)。"
    echo "   brew services start postgresql@16"
    exit 1
fi

PSQL_ADMIN="psql -U postgres"
$PSQL_ADMIN -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
$PSQL_ADMIN -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
$PSQL_ADMIN -c "ALTER USER $DB_USER CREATEDB CREATEROLE;" 2>/dev/null || true
if ! $PSQL_ADMIN -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "⚠️  pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
    echo "   brew install pgvector"
fi
echo "✅ DB bootstrap 完了 (= schemas / tables は backend 起動時に自動作成)"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# Check dependencies
pg_isready -q 2>/dev/null || { echo "❌ PostgreSQL not running"; exit 1; }
pgrep -x ollama >/dev/null || { ollama serve &>/dev/null & sleep 2; }

# Stop existing
pkill -f "\./api$" 2>/dev/null; sleep 1

echo "🚀 Starting AI Server..."

# Single process: API + Web frontend
./api &
API_PID=$!

echo "✅ Started - http://localhost:${API_PORT:-8000}"

# Show LAN IP
LAN_IP=$(ifconfig 2>/dev/null | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n1)
[ -n "$LAN_IP" ] && echo "🌐 LAN: http://$LAN_IP:${API_PORT:-8000}"

# Show mDNS hostname (Bonjour is always available on macOS)
echo "🌐 mDNS: http://$(hostname).local:${API_PORT:-8000}"

echo ""
echo "Press Ctrl+C to stop"

trap "kill $API_PID 2>/dev/null; echo 'Stopped'" EXIT
wait
EOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
pkill -f "\./api$" 2>/dev/null
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

# Create db CLI script
cat > "$INSTALL_DIR/db" << 'EOF'
#!/bin/bash
DB_HOME="${DB_HOME:-$HOME/.local/db}"
case "$1" in
    start) "$DB_HOME/start.sh" ;;
    stop)  "$DB_HOME/stop.sh" ;;
    *)     echo "Usage: db {start|stop}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

# Create symlink to /usr/local/bin (requires sudo)
sudo ln -sf "$INSTALL_DIR/db" /usr/local/bin/db 2>/dev/null || echo "⚠️  Run: sudo ln -sf $INSTALL_DIR/db /usr/local/bin/db"

echo ""
echo "Done. Edit $INSTALL_DIR/.env then run: db start"
