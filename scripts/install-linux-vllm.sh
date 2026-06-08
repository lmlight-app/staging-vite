#!/bin/bash
# AI Server Installer for Linux (vLLM Edition)
set -e

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac

echo " Installing AI Server vLLM Edition ($ARCH) to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

[ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true

# Download unified backend binary (= api/ 統一、LLM_BACKEND=vllm で vllm mode)
echo " Downloading AI Server backend..."

BINARY_URL="$BASE_URL/lmlight-vite-linux-$ARCH"

if command -v wget &>/dev/null; then
  wget --show-progress --timeout=600 --tries=3 "$BINARY_URL" -O "$INSTALL_DIR/api"
else
  curl -fL --connect-timeout 30 --max-time 0 --retry 3 --retry-delay 5 \
    "$BINARY_URL" -o "$INSTALL_DIR/api"
fi

if [ ! -f "$INSTALL_DIR/api" ] || [ ! -s "$INSTALL_DIR/api" ]; then
  echo "❌ Failed to download vLLM backend"
  echo "   Please check:"
  echo "   1. Network connection"
  echo "   2. File exists at: $BINARY_URL"
  exit 1
fi

chmod +x "$INSTALL_DIR/api"

# Python venv for vLLM + whisper (separate from PyInstaller binary)
echo "Setting up Python environment for vLLM..."

# Install uv (recommended by vLLM for faster and more reliable installation)
if ! command -v uv &>/dev/null; then
    echo " Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# Build dependencies: python3-dev for Triton JIT, ffmpeg for Whisper
if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq python3-dev ffmpeg
elif command -v dnf &>/dev/null; then
    sudo dnf install -y python3-devel ffmpeg
elif command -v yum &>/dev/null; then
    sudo yum install -y python3-devel ffmpeg
else
    echo "⚠️  Please install python3-dev and ffmpeg manually."
fi

if [ ! -d "$INSTALL_DIR/venv" ]; then
    uv venv --python 3.12 "$INSTALL_DIR/venv"
fi

# vLLM version. Bump together with api-vllm/pyproject.toml's `vllm~=X.Y.0`
# constraint when moving across patches. The wheels.vllm.ai host is version-
# pathed (one URL per release), so even though pyproject is loose this script
# pins the exact patch — keep them in sync.
VLLM_VER=0.20.2

# Detect CUDA version for vLLM wheel selection
CUDA_MAJOR=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K\d+' || echo "12")
echo " CUDA $CUDA_MAJOR detected, installing vLLM $VLLM_VER..."

if [ "$CUDA_MAJOR" -ge 13 ]; then
    # CUDA 13: PyPI default ships cu130 wheels — no extra index needed.
    uv pip install --python "$INSTALL_DIR/venv/bin/python" "vllm==$VLLM_VER"
else
    # CUDA 12.x: pull from the cu129 wheel index (only 12.x variant
    # vLLM publishes for $VLLM_VER; covers CUDA 12.0–12.9).
    uv pip install --python "$INSTALL_DIR/venv/bin/python" \
        "vllm==$VLLM_VER" \
        --extra-index-url "https://wheels.vllm.ai/$VLLM_VER/cu129" \
        --extra-index-url "https://download.pytorch.org/whl/cu129" \
        --index-strategy unsafe-best-match
fi

uv pip install --python "$INSTALL_DIR/venv/bin/python" "openai-whisper>=20231117"

echo "✅ Python venv ready"

# Vite Edition: frontend is embedded in the API binary, no app.tar.gz needed

[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
# =============================================================================
# AI Server Configuration (vLLM Edition)
# =============================================================================

# Backend selection (= unified codebase で env で切替)
LLM_BACKEND=vllm

# Python path for vLLM (auto-configured by installer)
VLLM_PYTHON=$INSTALL_DIR/venv/bin/python

# PostgreSQL Database
DATABASE_URL=postgresql://digitalbase:digitalbase@localhost:5432/digitalbase

# =============================================================================
# vLLM Server URLs
# =============================================================================
VLLM_BASE_URL=http://localhost:8080
VLLM_EMBED_BASE_URL=http://localhost:8081
# Optional: Separate vision server (leave empty to use chat server for vision)
# VLLM_VISION_BASE_URL=http://localhost:8082

# =============================================================================
# vLLM Auto-Start Configuration
# When enabled, API will automatically start vLLM servers on startup.
# First run requires network to download models from HuggingFace.
# Models are cached at ~/.cache/huggingface/hub/
# =============================================================================
VLLM_AUTO_START=true

# Models (HuggingFace model IDs)
# 軽量 default = Qwen3-4B (= 4B params, 32K context, 24GB GPU で余裕、PoC 用)
# 上位:   Qwen/Qwen3-8B (= ~16GB), Qwen/Qwen3.5-35B-A3B (= 大型 MoE、>24GB)
# 最軽量: Qwen/Qwen3-1.7B (= ~4GB、low-end GPU 可)
VLLM_CHAT_MODEL=Qwen/Qwen3-4B
VLLM_EMBED_MODEL=Qwen/Qwen3-Embedding-0.6B
# Optional: Separate vision model (requires VLLM_VISION_BASE_URL)
# VLLM_VISION_MODEL=Qwen/Qwen2.5-VL-7B-Instruct

# GPU Configuration
# VLLM_TENSOR_PARALLEL: Number of GPUs for tensor parallelism (default: 1)
# VLLM_GPU_MEMORY_UTILIZATION_{CHAT,EMBED,VISION}: Per-server GPU memory ratio
#   Unset = vLLM default (0.9), set when running multiple servers on same GPU
#   2-server (chat + embed):  0.70 + 0.10 = 0.80
#   3-server (+ vision):      0.35 + 0.10 + 0.25 = 0.70
# VLLM_MAX_MODEL_LEN: Max context length (empty = model default)
VLLM_TENSOR_PARALLEL=1
VLLM_GPU_MEMORY_UTILIZATION_CHAT=0.70
VLLM_GPU_MEMORY_UTILIZATION_EMBED=0.10
# VLLM_GPU_MEMORY_UTILIZATION_VISION=0.25
# VLLM_MAX_MODEL_LEN=4096

# Additional vLLM arguments (space-separated, passed directly to vllm serve)
# Examples: --enforce-eager, --enable-prefix-caching, --quantization awq, --dtype half
#VLLM_REASONING_PARSER=qwen3 
# VLLM_EXTRA_ARGS_CHAT=--enforce-eager --enable-prefix-caching
# VLLM_EXTRA_ARGS_EMBED=--enforce-eager
# VLLM_EXTRA_ARGS_VISION=--enforce-eager

# =============================================================================
# Whisper Transcription (GPU auto-detect)
# Models are downloaded automatically on first use to ~/.cache/whisper/
# Available: tiny, base, small, medium, large
# =============================================================================
WHISPER_MODEL=base

# =============================================================================
# API Server Configuration
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
# Offline Mode
# After models are downloaded, uncomment to run without internet.
# Not needed if using local model paths (e.g. /path/to/model).
# =============================================================================
# HF_HUB_OFFLINE=1

# =============================================================================
# License Configuration
# =============================================================================
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic

# File Storage (pipeline uploads/outputs)
FILES_DIR=$INSTALL_DIR/files
EOF

# Database setup - parse DATABASE_URL from .env if it exists (for updates with custom DB config)
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
    echo "   sudo apt install postgresql"
    echo "   sudo systemctl start postgresql"
    exit 1
fi
if ! pg_isready -q 2>/dev/null; then
    echo "❌ PostgreSQL に接続できません (localhost:5432)。"
    echo "   sudo systemctl start postgresql"
    exit 1
fi

PSQL_ADMIN="sudo -u postgres psql"
$PSQL_ADMIN -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
$PSQL_ADMIN -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
$PSQL_ADMIN -c "ALTER USER $DB_USER CREATEDB CREATEROLE;" 2>/dev/null || true
if ! $PSQL_ADMIN -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "⚠️  pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
    echo "   sudo apt install postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector"
fi
echo "✅ DB bootstrap 完了 (= schemas / tables は backend 起動時に自動作成)"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# CUDA 13+: Triton bundled ptxas is CUDA 12, need system ptxas
CUDA_MAJOR=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K\d+' || true)
[ "${CUDA_MAJOR:-0}" -ge 13 ] && [ -f /usr/local/cuda/bin/ptxas ] && export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas

# Check dependencies

pg_isready -q 2>/dev/null || { echo "❌ PostgreSQL not running"; exit 1; }

# Check NVIDIA GPU (vLLM requires CUDA)
if ! command -v nvidia-smi &>/dev/null; then
    echo "⚠️  nvidia-smi not found. vLLM requires NVIDIA GPU with CUDA."
fi

# Stop existing
pkill -f "db.*api" 2>/dev/null; sleep 1

echo "🚀 Starting AI Server (vLLM Edition)..."

# Single process: API + Web frontend
./api &
API_PID=$!

echo "✅ Started - http://localhost:${API_PORT:-8000}"

# Show LAN IP
LAN_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
[ -n "$LAN_IP" ] && echo "🌐 LAN: http://$LAN_IP:${API_PORT:-8000}"

# Show mDNS hostname if Avahi is running
if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    echo "🌐 mDNS: http://$(hostname).local:${API_PORT:-8000}"
fi

# vLLM 起動状態は Python (api 側) が single source of truth で log 出力する
# shell では予言せず、URL だけ案内
echo ""
echo "📡 vLLM endpoints: chat=${VLLM_BASE_URL:-http://localhost:8080}, embed=${VLLM_EMBED_BASE_URL:-http://localhost:8081}"

echo ""
echo "Press Ctrl+C to stop"

trap "kill $API_PID 2>/dev/null; echo 'Stopped'" EXIT
wait
EOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
# Kill start.sh first (which will trigger its trap to kill API/Web)
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
# Clean up any remaining processes
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
echo ""
echo "Note: vLLM requires NVIDIA GPU with CUDA."
echo "      First run will download models from HuggingFace (~3GB)."
echo "      Models are cached at ~/.cache/huggingface/hub/"