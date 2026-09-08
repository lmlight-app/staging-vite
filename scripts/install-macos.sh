#!/bin/bash
# AI Server Installer for macOS (Vite Edition)
# Single binary with embedded frontend - no Node.js required
set -e

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
VERSION_BASE_URL="https://github.com/lmlight-app/dist_vite/releases/download/"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) DB_VERSION="${2:?--version requires latest|26.0908.2|x20260908.2-macos}"; shift ;;
        -h|--help) echo "Usage: install-macos.sh [--version VERSION]"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1 (usage: install-macos.sh [--version VERSION])"; exit 2 ;;
    esac
    shift
done
DB_VERSION="${DB_VERSION:-latest}"
printf '%s' "$DB_VERSION" | grep -Eq '^(latest|[0-9]{2}\.[0-9]{4}(\.[0-9]+)?|x[0-9]{8}(\.[0-9]+)?(-[a-z0-9]+)?)$' \
    || { echo "[ERROR] --version must be latest, a version like 26.0908.2, or a release tag like x20260908.2-macos"; exit 2; }
TARGET_VERSION=""
if [ "$DB_VERSION" != "latest" ]; then
    RELEASE_REF="$DB_VERSION"
    case "$VERSION_BASE_URL" in
        *github.com/*)
            case "$RELEASE_REF" in
                x*) ;;
                *)
                    RAW_VERSION="20$(printf '%s' "$RELEASE_REF" | sed -E 's/^([0-9]{2})\.([0-9]{4})/\1\2/')"
                    CANDIDATES="$(curl -fsSL "https://api.github.com/repos/lmlight-app/dist_vite/releases?per_page=100" 2>/dev/null \
                        | grep -o '"tag_name": *"x'"$RAW_VERSION"'\(-[a-z0-9]*\)\{0,1\}"' | sed -E 's/.*"(x[^"]+)".*/\1/')"
                    RELEASE_REF="$(printf '%s\n' "$CANDIDATES" | grep -m1 -- '-macos$' || printf '%s\n' "$CANDIDATES" | grep -m1 -v -- '-' || true)"
                    [ -n "$RELEASE_REF" ] || { echo "[ERROR] Version $DB_VERSION was not found in releases; pass the release tag instead (e.g. x20260908.2-macos)"; exit 1; }
                    ;;
            esac
            ;;
    esac
    [ -n "${DB_BASE_URL:-}" ] || BASE_URL="${VERSION_BASE_URL}${RELEASE_REF}"
    TARGET_VERSION="$(printf '%s' "$RELEASE_REF" | sed -E 's/^x20([0-9]{2})([0-9]{4})/\1.\2/; s/-[a-z0-9]+$//')"
fi
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac

echo "Installing AI Server Vite Edition ($ARCH) to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

UPDATE_LOG="$INSTALL_DIR/update.log"
log() { echo "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$UPDATE_LOG"; }

verify_sha256() {
    local file="$1" src="$2" expected="" actual=""
    if [ "${DB_SKIP_SHA256:-0}" = "1" ]; then log "[WARN] sha256 verification skipped (DB_SKIP_SHA256=1)"; return 0; fi
    if [ -f "$src" ]; then
        expected="$(awk '{print $1}' "$src")"
    else
        expected="$(curl -fsSL --retry 3 --retry-delay 5 "$src" 2>/dev/null | awk '{print $1}')"
    fi
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    if ! printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
        rm -f "$file"; log "[ERROR] Could not fetch checksum: $src"; exit 1
    fi
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
        rm -f "$file"; log "[ERROR] sha256 mismatch for $(basename "$src" .sha256): expected $expected, got $actual"; exit 1
    fi
    log "[OK] sha256 verified: $actual"
}

install_binary() {
    chmod +x "$INSTALL_DIR/api.new"
    if [ -f "$INSTALL_DIR/api" ]; then
        rm -f "$INSTALL_DIR/api.prev"
        ln -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev" 2>/dev/null || cp -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev"
    fi
    mv -f "$INSTALL_DIR/api.new" "$INSTALL_DIR/api"
    log "[OK] binary installed (previous kept as api.prev for 'db rollback')"
    if [ -n "$TARGET_VERSION" ]; then
        [ -f "$INSTALL_DIR/VERSION" ] && cp -f "$INSTALL_DIR/VERSION" "$INSTALL_DIR/VERSION.prev"
        printf '%s\n' "$TARGET_VERSION" > "$INSTALL_DIR/VERSION"
    fi
}

version_lt() { awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) { p = (i <= n) ? x[i] + 0 : 0; q = (i <= m) ? y[i] + 0 : 0; if (p < q) exit 0; if (p > q) exit 1 } exit 1 }'; }
INSTALLED_VERSION="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
if [ -n "$TARGET_VERSION" ] && [ -n "$INSTALLED_VERSION" ] && version_lt "$TARGET_VERSION" "$INSTALLED_VERSION" && [ "${DB_ALLOW_DOWNGRADE:-0}" != "1" ]; then
    echo "[ERROR] $TARGET_VERSION is older than the installed $INSTALLED_VERSION. Data written by the newer version may become unreadable."
    echo "        Use 'db rollback' to return to the previous version, or set DB_ALLOW_DOWNGRADE=1 to force."
    exit 1
fi
[ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true

# Download single binary (API + frontend embedded)
BINARY_URL="$BASE_URL/lmlight-vite-macos-$ARCH"
log "[UPDATE] start: $BINARY_URL"
echo "Downloading AI Server..."
curl -fL --connect-timeout 30 --max-time 0 --retry 3 --retry-delay 5 \
    "$BINARY_URL" -o "$INSTALL_DIR/api.new" || true
if [ ! -s "$INSTALL_DIR/api.new" ] || ! file -b "$INSTALL_DIR/api.new" | grep -q "Mach-O"; then
    rm -f "$INSTALL_DIR/api.new"
    log "[ERROR] Failed to download backend: $BINARY_URL"
    exit 1
fi
verify_sha256 "$INSTALL_DIR/api.new" "$BINARY_URL.sha256"
install_binary

if ! command -v uv &>/dev/null; then
    echo "Installing uv (= optional features の前提)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || echo "[WARN] uv install 失敗。後で: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
LLM_BACKEND=ollama
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
JWT_SECRET=$(openssl rand -hex 32)
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_AUTO_START=true
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic
FILES_DIR=$INSTALL_DIR/files
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
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

if ! command -v psql &>/dev/null; then
    echo "[ERROR] PostgreSQL がインストールされていません (pgvector 対応・16 以降)。"
    echo "   Homebrew:  brew install postgresql@16 pgvector && brew services start postgresql@16"
    echo "   または:    Postgres.app (postgresapp.com) / 公式インストーラ でも可 (brew 必須ではありません)"
    exit 1
fi
if ! pg_isready -q 2>/dev/null; then
    echo "[ERROR] PostgreSQL に接続できません (localhost:5432)。起動してください:"
    echo "   brew services start postgresql@16   (Postgres.app なら app を起動)"
    exit 1
fi

PG_SUPER=""
if psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
    PG_SUPER="postgres"
fi
pg_admin() { psql ${PG_SUPER:+-U "$PG_SUPER"} "$@"; }

if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "[WARN] CREATE USER $DB_USER に失敗"
fi
if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "[WARN] CREATE DATABASE $DB_NAME に失敗"
fi
pg_admin -d postgres -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "[WARN] pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
    echo "   brew install pgvector   (Postgres.app は同梱のことが多い)"
fi
echo "[OK] Database setup complete (schemas and tables are created automatically on first startup)"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# Check dependencies
pg_isready -q 2>/dev/null || { echo "[ERROR] PostgreSQL not running"; exit 1; }
pgrep -x ollama >/dev/null || { ollama serve &>/dev/null & sleep 2; }

[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$HERE" ] && kill "$p" 2>/dev/null
done
for _ in $(seq 1 30); do
    ALIVE=0
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
        [ "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$HERE" ] && ALIVE=1
    done
    [ "$ALIVE" -eq 0 ] && break
    sleep 1
done

echo "Starting AI Server..."

# Single process: API + Web frontend
unset _MEIPASS2 _PYI_ARCHIVE_FILE _PYI_PARENT_PROCESS_LEVEL _PYI_APPLICATION_HOME_DIR

./api &
API_PID=$!
echo "$API_PID" > api.pid

echo "[OK] Started - http://localhost:${API_PORT:-8000}"

# Show LAN IP
LAN_IP=$(ifconfig 2>/dev/null | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n1)
[ -n "$LAN_IP" ] && echo "LAN: http://$LAN_IP:${API_PORT:-8000}"

# Show mDNS hostname (Bonjour is always available on macOS)
echo "mDNS: http://$(hostname).local:${API_PORT:-8000}"

echo ""
echo "Press Ctrl+C to stop"

trap "kill $API_PID 2>/dev/null; rm -f api.pid; echo 'Stopped'" EXIT
wait
EOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null && rm -f api.pid
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$HERE" ] && kill "$p" 2>/dev/null
done
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

cat > "$INSTALL_DIR/db" << EOF
#!/bin/bash
DB_HOME="\${DB_HOME:-$INSTALL_DIR}"
EOF
cat >> "$INSTALL_DIR/db" << 'EOF'
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rollback_binary() {
    if [ ! -f "$DB_HOME/api.prev" ]; then
        echo "[ERROR] No previous binary to roll back to ($DB_HOME/api.prev not found)"; return 1
    fi
    mv -f "$DB_HOME/api" "$DB_HOME/api.rollback" \
        && mv -f "$DB_HOME/api.prev" "$DB_HOME/api" \
        && mv -f "$DB_HOME/api.rollback" "$DB_HOME/api.prev" || return 1
    if [ -f "$DB_HOME/VERSION.prev" ]; then
        mv -f "$DB_HOME/VERSION" "$DB_HOME/VERSION.rollback" 2>/dev/null || true
        mv -f "$DB_HOME/VERSION.prev" "$DB_HOME/VERSION"
        [ -f "$DB_HOME/VERSION.rollback" ] && mv -f "$DB_HOME/VERSION.rollback" "$DB_HOME/VERSION.prev"
    fi
    printf 'result=rolled_back\nexit_code=0\nfinished_at=%s\n' "$(_ts)" > "$DB_HOME/.update-result"
    echo "$(_ts) [ROLLBACK] api <-> api.prev swapped" >> "$DB_HOME/update.log"
    echo "[OK] Rolled back to the previous binary (run 'db rollback' again to undo)"
}

cleanup_backups() {
    if [ -f "$DB_HOME/.update-requested" ] || pgrep -f "install-(linux|macos)[^ ]*\.sh" >/dev/null 2>&1; then
        echo "[ERROR] An update is in progress; run cleanup after it finishes"; return 1
    fi
    local targets=() p
    for p in "$DB_HOME"/api.prev "$DB_HOME"/venv.prev "$DB_HOME"/api.new "$DB_HOME"/venv.new \
             "$DB_HOME"/api.rollback "$DB_HOME"/venv.rollback "$DB_HOME"/.env.bak-* "$DB_HOME"/*.bak-* "$DB_HOME"/*.bak; do
        [ -e "$p" ] && targets+=("$p")
    done
    if [ ${#targets[@]} -eq 0 ]; then echo "[OK] Nothing to clean up"; return 0; fi
    du -sh "${targets[@]}" 2>/dev/null
    if [ "${1:-}" != "--yes" ]; then
        read -r -p "Delete these? 'db rollback' will no longer be available [y/N] " ans
        case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelled"; return 1 ;; esac
    fi
    rm -rf -- "${targets[@]}"
    echo "$(_ts) [CLEANUP] removed: ${targets[*]}" >> "$DB_HOME/update.log"
    echo "[OK] Cleaned up ${#targets[@]} item(s)"
}
case "$1" in
    start)    "$DB_HOME/start.sh" ;;
    stop)     "$DB_HOME/stop.sh" ;;
    rollback) "$DB_HOME/stop.sh"; rollback_binary && "$DB_HOME/start.sh" ;;
    cleanup)  cleanup_backups "${2:-}" ;;
    *)        echo "Usage: db {start|stop|rollback|cleanup [--yes]}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

# Create symlink to /usr/local/bin (root: direct, otherwise sudo)
if [ "$(id -u)" -eq 0 ]; then
    ln -sf "$INSTALL_DIR/db" /usr/local/bin/db 2>/dev/null || echo "[WARN] Run: ln -sf $INSTALL_DIR/db /usr/local/bin/db"
else
    sudo ln -sf "$INSTALL_DIR/db" /usr/local/bin/db 2>/dev/null || echo "[WARN] Run: sudo ln -sf $INSTALL_DIR/db /usr/local/bin/db"
fi

echo ""
echo "Done. Edit $INSTALL_DIR/.env then run: db start"
