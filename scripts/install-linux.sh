#!/bin/bash
# AI Server Installer for Linux (Vite Edition)
# Single binary with embedded frontend - no Node.js required
set -e

# HOME 未設定/不正だと $HOME/.local/... が /.local/... に化ける (更新ボタン経由 =
# systemd 環境で HOME 無しが起きる)。実 uid の home を確実に解決してから使う。
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

mkdir -p "$INSTALL_DIR"

# 更新時: 稼働中の旧プロセスを止める (systemd unit → 従来 stop.sh の順。binary 上書きの text busy 防止)
WAS_ACTIVE=0; { systemctl is-active --quiet db 2>/dev/null || systemctl is-active --quiet digitalbase 2>/dev/null; } && WAS_ACTIVE=1
# ※ この時点では SUDO 未判定のため sudo -n (パスワード prompt で止めない)
if command -v systemctl &>/dev/null; then
    systemctl stop db digitalbase 2>/dev/null || sudo -n systemctl stop db digitalbase 2>/dev/null || true
fi
[ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true
# 停止確認: 同 dir 起動の api が残っていれば中断 (稼働 binary への上書きは破損リスク)
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
echo "Downloading AI Server..."
curl -fSL "$BASE_URL/lmlight-vite-linux-$ARCH" -o "$INSTALL_DIR/api"
chmod +x "$INSTALL_DIR/api"

# uv 仕込み (= YOLO / transcribe / plugin install を将来即実行できるようにする)
# venv は作らない (= 各 optional install script が lazy に作る、容量影響なし)
if ! command -v uv &>/dev/null; then
    echo "Installing uv (= optional features の前提)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || echo "[WARN] uv install 失敗。後で: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# DB 接続情報は env で上書き可 (DB_USER/DB_PASS/DB_NAME)、既定 digitalbase。
# 既存 .env がある場合は下の Database setup でその DATABASE_URL を正とする。
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
LLM_BACKEND=ollama
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_AUTO_START=true
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic
FILES_DIR=$INSTALL_DIR/files
API_HOST=0.0.0.0
API_PORT=8000
JWT_SECRET=$(openssl rand -hex 32)
AUTH_MODE=local
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

# ── Privilege helper: support root-without-sudo (minimal GPU containers) ──
# 最小コンテナ (GMI 等の CUDA イメージ) は root 直 + sudo 未インストールが普通。
# sudo を無条件前提にすると postgres bootstrap / symlink が黙って失敗するので分岐。
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo &>/dev/null; then
    SUDO="sudo"
else
    SUDO=""
    echo "[WARN] root でも sudo でもありません。特権操作 (postgres / symlink) が失敗する可能性があります。"
fi
pg_admin() {
    if [ -n "$SUDO" ]; then
        $SUDO -u postgres psql "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        su postgres -c "psql $(printf '%q ' "$@")"
    else
        psql "$@"
    fi
}

if ! command -v psql &>/dev/null; then
    echo "[ERROR] PostgreSQL がインストールされていません (pgvector 対応版・16 以降)。README 参照:"
    echo "   apt install -y postgresql postgresql-\$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)-pgvector"
    exit 1
fi
# 未起動なら自動起動を試みる (systemd 無しコンテナは pg_ctlcluster、それ以外は systemctl)
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

# role (冪等)
if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
    pg_admin -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "[WARN] CREATE USER $DB_USER に失敗"
fi
# database (冪等)
if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
    pg_admin -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "[WARN] CREATE DATABASE $DB_NAME に失敗"
fi
pg_admin -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "[WARN] pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
    echo "   apt install -y postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector"
fi
echo "[OK] DB bootstrap 完了 (= schemas / tables は backend 起動時に自動作成)"

# 正準起動 (= systemd ExecStart と start.sh の共用。env 読込 + 前処理 + exec api)
cat > "$INSTALL_DIR/run.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# Ollama 未起動なら起動 (公式 install 済みなら ollama.service が既に居るので通常 skip)
pgrep -x ollama >/dev/null || { ollama serve &>/dev/null & sleep 2; }

# PyInstaller 親プロセス由来の変数を除去 (= 再起動で spawn された新プロセスが
# 旧プロセスの一時展開 dir を再利用して即死するのを防ぐ)
unset _MEIPASS2 _PYI_ARCHIVE_FILE _PYI_PARENT_PROCESS_LEVEL _PYI_APPLICATION_HOME_DIR

exec ./api
EOF
chmod +x "$INSTALL_DIR/run.sh"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# systemd 管理中は二重起動しない (= unit 経由に誘導)
if systemctl is-active --quiet db 2>/dev/null; then
    echo "db.service が稼働中です。操作は: db {start|stop|restart|status|logs}"
    exit 1
fi

# Check dependencies
pg_isready -q 2>/dev/null || { echo "[ERROR] PostgreSQL not running"; exit 1; }

# Stop existing (= pidfile 優先、fallback は同 dir 起動の api のみ = 他 install を巻き添えにしない)
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
# 旧プロセスの完全終了を待つ (graceful shutdown 中に起動すると bind 失敗で新プロセスが死ぬ)
for _ in $(seq 1 30); do
    ALIVE=0
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
        [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && ALIVE=1
    done
    [ "$ALIVE" -eq 0 ] && break
    sleep 1
done

echo "Starting AI Server..."

# Single process: API + Web frontend (run.sh は exec するので PID = api 本体)
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
# systemd 管理中は unit を止める (止められなければ偽の Stopped を出さない)
if systemctl is-active --quiet db 2>/dev/null; then
    SCTL="systemctl"; [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && SCTL="sudo -n systemctl"
    $SCTL stop db && { echo "Stopped (systemd)"; exit 0; }
    echo "Failed to stop db.service (root required): sudo systemctl stop db"; exit 1
fi
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
# Clean up any remaining processes (= pidfile 優先、fallback は同 dir 起動の api のみ)
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null && rm -f api.pid
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

# ── systemd unit (サーバ標準: ブート自動起動 + クラッシュ自動復帰 + 確実な再起動) ──
SYSTEMD_OK=0
if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null && { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; }; then
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
TimeoutStopSec=30
LimitNOFILE=65535
SyslogIdentifier=db

[Install]
WantedBy=multi-user.target
UNIT
    if $SUDO install -o root -g root -m 644 "$UNIT_TMP" /etc/systemd/system/db.service \
        && $SUDO systemctl daemon-reload; then
        rm -f "$UNIT_TMP"
        $SUDO systemctl enable db >/dev/null 2>&1 || true
        $SUDO systemctl disable digitalbase >/dev/null 2>&1 || true  # 旧unitのboot起動を止める(二重bind防止)
        SYSTEMD_OK=1
        echo "[OK] systemd unit 登録 (db.service = ブート自動起動 + クラッシュ自動復帰)"
    else
        rm -f "$UNIT_TMP"
        echo "[WARN] systemd unit の登録に失敗しました (従来の start.sh 起動で動作します)"
    fi
fi

# Create db CLI script (= systemd unit があれば systemctl 管理、無ければ従来 script)
cat > "$INSTALL_DIR/db" << 'EOF'
#!/bin/bash
DB_HOME="${DB_HOME:-$HOME/.local/db}"
if [ -f /etc/systemd/system/db.service ] && [ -d /run/systemd/system ]; then
    SCTL="systemctl"; JCTL="journalctl"
    [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && { SCTL="sudo systemctl"; JCTL="sudo journalctl"; }
    case "$1" in
        start)   $SCTL start db ;;
        stop)    $SCTL stop db ;;
        restart) $SCTL restart db ;;
        status)  $SCTL status db --no-pager ;;
        logs)    $JCTL -u db -f ;;
        *)       echo "Usage: db {start|stop|restart|status|logs}"; exit 1 ;;
    esac
    exit $?
fi
case "$1" in
    start) "$DB_HOME/start.sh" ;;
    stop)  "$DB_HOME/stop.sh" ;;
    *)     echo "Usage: db {start|stop}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

# Create symlink to /usr/local/bin (root: direct, non-root: sudo)
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
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
