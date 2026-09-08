#!/bin/bash
# AI Server Installer for Linux (Vite Edition)
# Single binary with embedded frontend - no Node.js required
set -e

if [ -z "$HOME" ] || [ "$HOME" = "/" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/root"
    export HOME
fi

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac

echo "Installing AI Server Vite Edition ($ARCH) to $INSTALL_DIR"

# ── Privilege helper: support root-without-sudo (minimal GPU containers) ──
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo &>/dev/null; then
    SUDO="sudo"
else
    SUDO=""
    echo "[WARN] root でも sudo でもありません。特権操作 (postgres / symlink) が失敗する可能性があります。"
fi
[ -t 0 ] || { [ -n "$SUDO" ] && SUDO="sudo -n"; }

# Run psql as the postgres superuser. Handles: non-root+sudo, root w/o sudo (su), fallback.
pg_admin() {
    if [ -n "$SUDO" ]; then
        $SUDO -u postgres psql "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        su postgres -c "psql $(printf '%q ' "$@")"
    else
        psql "$@"
    fi
}

WITH_OLLAMA="${DB_WITH_OLLAMA:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-ollama) WITH_OLLAMA=1 ;;
        --version) DB_VERSION="${2:?--version requires latest|26.0908.2|x20260908.2-linux}"; shift ;;
        -h|--help) echo "Usage: install-linux.sh [--with-ollama] [--version latest|26.0908.2|x20260908.2-linux]"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1 (usage: install-linux.sh [--with-ollama] [--version ...])"; exit 2 ;;
    esac
    shift
done
DB_VERSION="${DB_VERSION:-latest}"
if [ "$DB_VERSION" != "latest" ] && [ -z "${DB_BASE_URL:-}" ]; then
    RELEASE_TAG="$DB_VERSION"
    case "$RELEASE_TAG" in
        x*) ;;
        *)
            RAW_VERSION="20$(printf '%s' "$RELEASE_TAG" | sed -E 's/^([0-9]{2})\.([0-9]{4})/\1\2/')"
            RELEASE_TAG="$(curl -fsSL "https://api.github.com/repos/lmlight-app/dist_vite/releases?per_page=100" 2>/dev/null \
                | grep -o '"tag_name": *"x'"$RAW_VERSION"'\(-[a-z0-9]*\)\{0,1\}"' | head -1 | sed -E 's/.*"(x[^"]+)".*/\1/')"
            [ -n "$RELEASE_TAG" ] || { echo "[ERROR] Version $DB_VERSION was not found in releases; pass the release tag instead (e.g. x20260908.2-linux)"; exit 1; }
            ;;
    esac
    BASE_URL="https://github.com/lmlight-app/dist_vite/releases/download/$RELEASE_TAG"
fi
if ! command -v ollama >/dev/null 2>&1; then
    if [ "$WITH_OLLAMA" = "1" ]; then
        echo "Installing Ollama (official script)..."
        curl -fsSL https://ollama.com/install.sh | sh
        command -v ollama >/dev/null 2>&1 || { echo "[ERROR] Ollama install failed"; exit 1; }
    else
        echo "[WARN] Ollama is not installed. The service will be installed, but chat needs Ollama. Install it later with:"
        echo "   curl -fsSL https://ollama.com/install.sh | sh"
        echo "   (or re-run this installer with --with-ollama:  curl -fsSL <installer URL> | bash -s -- --with-ollama)"
    fi
fi

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
        log "[WARN] checksum unavailable ($src), continuing without sha256 verification"; return 0
    fi
    actual="$(sha256sum "$file" | awk '{print $1}')"
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
}

WAS_ACTIVE=0
if [ -z "$DB_NO_SERVICE" ]; then
    { systemctl is-active --quiet db 2>/dev/null || systemctl is-active --quiet digitalbase 2>/dev/null; } && WAS_ACTIVE=1
    command -v systemctl &>/dev/null && $SUDO systemctl stop db digitalbase 2>/dev/null || true
    [ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true
fi
if [ -d "$INSTALL_DIR" ]; then
    _RP="$(cd "$INSTALL_DIR" && pwd -P)"
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$_RP/api" 2>/dev/null); do
        if [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$_RP" ]; then
            echo "[ERROR] 稼働中のプロセスを停止できませんでした。先に停止してから再実行してください:"
            echo "   sudo systemctl stop db   (または $INSTALL_DIR/stop.sh)"
            exit 1
        fi
    done
fi

# Download single binary (API + frontend embedded)
BINARY_URL="$BASE_URL/lmlight-vite-linux-$ARCH"
log "[UPDATE] start: $BINARY_URL"
echo "Downloading AI Server..."
curl -fL --connect-timeout 30 --max-time 0 --retry 3 --retry-delay 5 \
    "$BINARY_URL" -o "$INSTALL_DIR/api.new" || true
if [ ! -s "$INSTALL_DIR/api.new" ] || ! head -c 4 "$INSTALL_DIR/api.new" | grep -q $'\x7fELF'; then
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
    echo "[ERROR] PostgreSQL がインストールされていません (pgvector 対応版・16 以降)。README 参照:"
    echo "   apt install -y postgresql postgresql-\$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)-pgvector"
    exit 1
fi
if ! pg_isready -q 2>/dev/null; then
    if command -v pg_ctlcluster &>/dev/null; then
        PGVER=$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1)
        [ -n "$PGVER" ] && $SUDO pg_ctlcluster "$PGVER" main start 2>/dev/null || true
    elif command -v systemctl &>/dev/null; then
        $SUDO systemctl start postgresql 2>/dev/null || true
    fi
fi
if ! pg_isready -q 2>/dev/null; then
    echo "[ERROR] PostgreSQL に接続できません (localhost:5432)。手動起動してください:"
    echo "   pg_ctlcluster <ver> main start   # systemd 無しコンテナ"
    echo "   systemctl start postgresql       # systemd 環境"
    exit 1
fi

if [ "$(PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null)" = "1" ]; then
    echo "[OK] Database already configured; setup skipped"
else
    if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
        pg_admin -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "[WARN] CREATE USER $DB_USER に失敗"
    fi
    if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
        pg_admin -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "[WARN] CREATE DATABASE $DB_NAME に失敗"
    fi
    pg_admin -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
    if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
        echo "[WARN] pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
        echo "   apt install -y postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector"
    fi
    echo "[OK] Database setup complete (schemas and tables are created automatically on first startup)"
fi

cat > "$INSTALL_DIR/run.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
if [ -f .update-running ] && [ ! -f .update-requested ]; then
    echo "$(_ts) [UPDATE] previous update was interrupted" >> update.log
    printf 'result=interrupted\nexit_code=\nfinished_at=%s\n' "$(_ts)" > .update-result
    rm -f .update-running
fi
if [ -f .update-requested ]; then
    UPDATE_URL=$(head -1 .update-requested)
    rm -f .update-requested
    touch .update-running
    DB_INSTALL_DIR="$(pwd -P)"; export DB_INSTALL_DIR
    echo "$(_ts) [UPDATE] running installer: $UPDATE_URL" >> update.log
    echo "[UPDATE] running installer: $UPDATE_URL"
    RC=1
    if curl -fsSL "$UPDATE_URL" -o .update-installer.sh; then
        if DB_NO_SERVICE=1 bash .update-installer.sh > .update-installer.out 2>&1; then RC=0; else RC=$?; fi
        if [ "$RC" -ne 0 ]; then
            echo "[UPDATE] installer failed (rc=$RC, see update.log)"
            tail -n 40 .update-installer.out >> update.log
        fi
    else
        echo "$(_ts) [UPDATE] installer download failed: $UPDATE_URL" >> update.log
        echo "[UPDATE] installer download failed: $UPDATE_URL"
    fi
    if [ "$RC" -eq 0 ]; then
        echo "$(_ts) [UPDATE] result: ok" >> update.log
        printf 'result=ok\nexit_code=0\nfinished_at=%s\n' "$(_ts)" > .update-result
    else
        echo "$(_ts) [UPDATE] result: failed (rc=$RC). Previous binary is api.prev: db rollback" >> update.log
        printf 'result=failed\nexit_code=%s\nfinished_at=%s\n' "$RC" "$(_ts)" > .update-result
    fi
    rm -f .update-installer.sh .update-running
fi

if command -v ollama >/dev/null 2>&1; then
    pgrep -x ollama >/dev/null || { ollama serve &>/dev/null & sleep 2; }
fi

unset _MEIPASS2 _PYI_ARCHIVE_FILE _PYI_PARENT_PROCESS_LEVEL _PYI_APPLICATION_HOME_DIR

exec ./api
EOF
chmod +x "$INSTALL_DIR/run.sh"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

if systemctl is-active --quiet db 2>/dev/null; then
    echo "db.service が稼働中です。操作は: db {start|stop|restart|status|logs}"
    exit 1
fi

# Check dependencies
pg_isready -q 2>/dev/null || { echo "[ERROR] PostgreSQL not running"; exit 1; }

[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
for _ in $(seq 1 30); do
    ALIVE=0
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
        [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && ALIVE=1
    done
    [ "$ALIVE" -eq 0 ] && break
    sleep 1
done

echo "Starting AI Server..."

./run.sh &
API_PID=$!
echo "$API_PID" > api.pid

echo "[OK] Started - http://localhost:${API_PORT:-8000}"

# Show LAN IP
LAN_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
[ -n "$LAN_IP" ] && echo "LAN: http://$LAN_IP:${API_PORT:-8000}"

# Show mDNS hostname if Avahi is running
if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    echo "mDNS: http://$(hostname).local:${API_PORT:-8000}"
fi

echo ""
echo "Press Ctrl+C to stop"

trap "kill $API_PID 2>/dev/null; rm -f api.pid; echo 'Stopped'" EXIT
wait
EOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
if systemctl is-active --quiet db 2>/dev/null; then
    SCTL="systemctl"; [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && SCTL="sudo -n systemctl"
    $SCTL stop db && { echo "Stopped (systemd)"; exit 0; }
    echo "Failed to stop db.service (root required): sudo systemctl stop db"; exit 1
fi
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null && rm -f api.pid
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

SYSTEMD_OK=0
if [ -z "$DB_NO_SERVICE" ] && [ -d /run/systemd/system ] && command -v systemctl &>/dev/null && { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; }; then
    UNIT_TMP=$(mktemp)
    cat > "$UNIT_TMP" << UNIT
[Unit]
Description=DigitalBase AI Server
After=network-online.target postgresql.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/run.sh
Restart=always
RestartSec=5
TimeoutStopSec=180
LimitNOFILE=65535
SyslogIdentifier=db

[Install]
WantedBy=multi-user.target
UNIT
    if $SUDO install -o root -g root -m 644 "$UNIT_TMP" /etc/systemd/system/db.service \
        && $SUDO systemctl daemon-reload; then
        rm -f "$UNIT_TMP"
        $SUDO systemctl enable db >/dev/null 2>&1 || true
        $SUDO systemctl disable digitalbase >/dev/null 2>&1 || true
        SYSTEMD_OK=1
        echo "[OK] systemd unit 登録 (db.service = ブート自動起動 + クラッシュ自動復帰)"
    else
        rm -f "$UNIT_TMP"
        echo "[WARN] systemd unit の登録に失敗しました (従来の start.sh 起動で動作します)"
    fi
fi

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
    rm -f "$DB_HOME/.update-requested"
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
if [ -f /etc/systemd/system/db.service ] && [ -d /run/systemd/system ]; then
    SCTL="systemctl"; JCTL="journalctl"
    [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && { SCTL="sudo systemctl"; JCTL="sudo journalctl"; }
    case "$1" in
        start)    $SCTL start db ;;
        stop)     $SCTL stop db ;;
        restart)  $SCTL restart db ;;
        rollback) $SCTL stop db && rollback_binary && $SCTL start db ;;
        cleanup)  cleanup_backups "${2:-}" ;;
        status)   $SCTL status db --no-pager ;;
        logs)     $JCTL -u db -f ;;
        *)        echo "Usage: db {start|stop|restart|rollback|cleanup [--yes]|status|logs}"; exit 1 ;;
    esac
    exit $?
fi
case "$1" in
    start)    "$DB_HOME/start.sh" ;;
    stop)     "$DB_HOME/stop.sh" ;;
    rollback) "$DB_HOME/stop.sh"; rollback_binary && "$DB_HOME/start.sh" ;;
    cleanup)  cleanup_backups "${2:-}" ;;
    *)        echo "Usage: db {start|stop|rollback|cleanup [--yes]}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

if [ "$(readlink /usr/local/bin/db 2>/dev/null)" = "$INSTALL_DIR/db" ]; then
    :
elif [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[WARN] Run: sudo ln -sf $INSTALL_DIR/db /usr/local/bin/db"
else
    $SUDO ln -sf "$INSTALL_DIR/db" /usr/local/bin/db 2>/dev/null || echo "[WARN] Run: ln -sf $INSTALL_DIR/db /usr/local/bin/db"
fi

echo ""
if [ "$SYSTEMD_OK" -eq 1 ] && [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
    $SUDO systemctl start db 2>/dev/null && echo "[OK] 更新完了、db.service を再開しました" || true
fi
echo "Done. Edit $INSTALL_DIR/.env then run: db start"
[ "$SYSTEMD_OK" -eq 1 ] && echo "     (systemd 管理: ブート時自動起動。ログは db logs / journalctl -u db)" || true
