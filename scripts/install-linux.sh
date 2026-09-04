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
# 非対話実行 (TTY 無し = self-update 等) では sudo に password prompt させない (-n)。
# 必要な特権操作は下の各所で「導入済みなら skip」してから呼ぶので、PAM ログも汚れない。
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

# ── Ollama (= この edition の推論 backend)。既定は導入確認のみ、--with-ollama (or DB_WITH_OLLAMA=1) で公式 script により導入 ──
# curl ... | bash -s -- --with-ollama の形で渡す。未導入でも service は入れて続行 (= 後から Ollama を入れれば動く。導入を止めない)
WITH_OLLAMA="${DB_WITH_OLLAMA:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-ollama) WITH_OLLAMA=1 ;;
        -h|--help) echo "Usage: install-linux.sh [--with-ollama]"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1 (usage: install-linux.sh [--with-ollama])"; exit 2 ;;
    esac
    shift
done
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

# 更新手順の記録 (= admin の update/status が末尾を表示する。日時は UTC)
UPDATE_LOG="$INSTALL_DIR/update.log"
log() { echo "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$UPDATE_LOG"; }

# 公開 .sha256 (release.yml が sha256sum 形式で生成し promote.sh が同居させる) と照合。
# 不一致は中断 (= 改竄/途中欠損 binary を稼働させない)。取得不能は警告して続行 (= checksum の配布漏れで導入を止めない。DB_SKIP_SHA256=1 は検証自体を省略)
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

# 旧 binary を api.prev に残してから差し替える (= db rollback で戻せる)。hard link なので容量も時間もゼロ
install_binary() {
    chmod +x "$INSTALL_DIR/api.new"
    if [ -f "$INSTALL_DIR/api" ]; then
        rm -f "$INSTALL_DIR/api.prev"
        ln -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev" 2>/dev/null || cp -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev"
    fi
    mv -f "$INSTALL_DIR/api.new" "$INSTALL_DIR/api"
    log "[OK] binary installed (previous kept as api.prev for 'db rollback')"
}

# 更新時: 稼働中の旧プロセスを止める (systemd unit → 従来 stop.sh の順。binary 上書きの text busy 防止)
# DB_NO_SERVICE=1 (= run.sh 経由の self-update、unit の内側で実行中) では unit を触らない (自壊防止)
WAS_ACTIVE=0
if [ -z "$DB_NO_SERVICE" ]; then
    { systemctl is-active --quiet db 2>/dev/null || systemctl is-active --quiet digitalbase 2>/dev/null; } && WAS_ACTIVE=1
    command -v systemctl &>/dev/null && $SUDO systemctl stop db digitalbase 2>/dev/null || true
    [ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true
fi
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
# 一時ファイルへ DL → sha256 検証 → 旧 binary を api.prev に退避 → mv (= 失敗・中断時に稼働 binary を壊さない)
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

# config の既定値でカバーされる項目は書かない (= .env は既定と異なるものだけ。行が消えても
# 既定値で復帰でき、設定の正が config.py に一本化される)。path 系は install dir 依存なので残す。
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
# ── DB bootstrap (= superuser でしかできない 3 つだけ。schema / table / index /
# column 追加 / 初期 admin user は backend 起動時の migrations.py が冪等に作成) ──
echo "Setting up database..."
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

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

# 既に app 資格情報で接続でき pgvector も有効なら bootstrap 全体を skip
# (= 更新時は pg_admin/sudo を一切呼ばず PAM ログを汚さない)
if [ "$(PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null)" = "1" ]; then
    echo "[OK] Database already configured; setup skipped"
else
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
    echo "[OK] Database setup complete (schemas and tables are created automatically on first startup)"
fi

# 正準起動 (= systemd ExecStart と start.sh の共用。env 読込 + 前処理 + exec api)
cat > "$INSTALL_DIR/run.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# アップデート要求 marker (= 管理画面の更新ボタン。api が marker を置いて self-exit し、
# systemd の Restart=always でここに再入する。unit 操作権限が不要な self-update)
# 進行中 .update-running / 結果 .update-result / 手順 update.log は admin の update/status が読む。
# installer は旧 binary を api.prev に残すので、失敗・起動不能時は `db rollback` で戻す
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
if [ -f .update-running ] && [ ! -f .update-requested ]; then
    # 前回の installer が途中で落ちた (= systemd stop / 電源断)。結果だけ残して通常起動へ
    echo "$(_ts) [UPDATE] previous update was interrupted" >> update.log
    printf 'result=interrupted\nexit_code=\nfinished_at=%s\n' "$(_ts)" > .update-result
    rm -f .update-running
fi
if [ -f .update-requested ]; then
    UPDATE_URL=$(head -1 .update-requested)
    rm -f .update-requested
    touch .update-running
    # installer に自分の設置 dir を教える (= $HOME/.local/db 以外の設置でも同じ dir を更新する)
    DB_INSTALL_DIR="$(pwd -P)"; export DB_INSTALL_DIR
    echo "$(_ts) [UPDATE] running installer: $UPDATE_URL" >> update.log
    echo "[UPDATE] running installer: $UPDATE_URL"
    RC=1
    if curl -fsSL "$UPDATE_URL" -o .update-installer.sh; then
        # installer 自身が手順を update.log に書くので、生ログは別ファイルに取り失敗時だけ末尾を寄せる
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

# Ollama 未起動なら起動 (公式 install 済みなら ollama.service が既に居るので通常 skip。未導入なら skip)
if command -v ollama >/dev/null 2>&1; then
    pgrep -x ollama >/dev/null || { ollama serve &>/dev/null & sleep 2; }
fi

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
# DB_NO_SERVICE=1 (= self-update) では unit 再登録も skip (既存 unit のまま run.sh が exec ./api する)
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
# vLLM/SGLang を chat/embed/vision 分 SIGTERM→SIGKILL する時間 (= 途中で SIGKILL されると GPU が孤児化)。
# pkg/db.service と同値。systemd は行末コメント非対応なので値と同じ行に書かない
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
        $SUDO systemctl disable digitalbase >/dev/null 2>&1 || true  # 旧unitのboot起動を止める(二重bind防止)
        SYSTEMD_OK=1
        echo "[OK] systemd unit 登録 (db.service = ブート自動起動 + クラッシュ自動復帰)"
    else
        rm -f "$UNIT_TMP"
        echo "[WARN] systemd unit の登録に失敗しました (従来の start.sh 起動で動作します)"
    fi
fi

# Create db CLI script (= systemd unit があれば systemctl 管理、無ければ従来 script)
# 設置先は install 時に焼き込む (= $HOME 依存だと sudo / systemd 経由で別 dir を見る)
cat > "$INSTALL_DIR/db" << EOF
#!/bin/bash
DB_HOME="\${DB_HOME:-$INSTALL_DIR}"
EOF
cat >> "$INSTALL_DIR/db" << 'EOF'
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# 直前の binary (api.prev、installer が更新時に退避) と入れ替える。もう一度実行すると元に戻る。
# update.log / .update-result にも記録 (= admin の update/status に出る)
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
if [ -f /etc/systemd/system/db.service ] && [ -d /run/systemd/system ]; then
    SCTL="systemctl"; JCTL="journalctl"
    [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && { SCTL="sudo systemctl"; JCTL="sudo journalctl"; }
    case "$1" in
        start)    $SCTL start db ;;
        stop)     $SCTL stop db ;;
        restart)  $SCTL restart db ;;
        rollback) $SCTL stop db && rollback_binary && $SCTL start db ;;
        status)   $SCTL status db --no-pager ;;
        logs)     $JCTL -u db -f ;;
        *)        echo "Usage: db {start|stop|restart|rollback|status|logs}"; exit 1 ;;
    esac
    exit $?
fi
case "$1" in
    start)    "$DB_HOME/start.sh" ;;
    stop)     "$DB_HOME/stop.sh" ;;
    rollback) "$DB_HOME/stop.sh"; rollback_binary && "$DB_HOME/start.sh" ;;
    *)        echo "Usage: db {start|stop|rollback}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

# Create symlink to /usr/local/bin (root: direct, non-root: sudo)。既に正しければ skip (= sudo 不要)
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
