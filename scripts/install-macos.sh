#!/bin/bash
# AI Server Installer for macOS (Vite Edition)
# Single binary with embedded frontend - no Node.js required
set -e

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/digitalbase}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac

echo "Installing AI Server Vite Edition ($ARCH) to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"/logs

[ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true

# Download single binary (API + frontend embedded)
echo "Downloading AI Server..."
curl -fSL "$BASE_URL/lmlight-vite-macos-$ARCH" -o "$INSTALL_DIR/api"
chmod +x "$INSTALL_DIR/api"

[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
# =============================================================================
# AI Server Configuration (Vite Edition)
# =============================================================================

# PostgreSQL Database
DATABASE_URL=postgresql://lmlight:lmlight@localhost:5432/lmlight

# Ollama LLM Server
OLLAMA_BASE_URL=http://localhost:11434

# License
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic

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
echo "Setting up database..."
curl -fsSL https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/db_setup.sh | bash

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
pkill -f "digitalbase/start\.sh" 2>/dev/null
sleep 1
pkill -f "\./api$" 2>/dev/null
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

# Create db CLI script
cat > "$INSTALL_DIR/db" << 'EOF'
#!/bin/bash
DB_HOME="${DB_HOME:-$HOME/.local/digitalbase}"
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
