#!/bin/bash
# DigitalBase - Web Search (SearXNG) Installer
# チャットの Web 検索に使うメタ検索エンジン SearXNG をこのサーバー機に立て、.env の WEB_SEARCH_* を設定する。
#   キー不要。Google・Bing・Brave などの結果をまとめて返す (AGPL-3.0)。
#   Linux + systemd + root / パスワード無し sudo なら uv で入れて db-websearch.service で常駐させる。それ以外はコンテナ
# DigitalBase 本体は server から http://127.0.0.1:<port> に頼むだけ (= 検索サーバーは外に公開しない)。
#
# 環境変数: DB_INSTALL_DIR (本体の配置先)、DB_SEARXNG_VERSION (SearXNG の commit。リリースの tag が無いので commit で固定する)

set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$(sed -n 's/^WorkingDirectory=//p' /etc/systemd/system/db.service 2>/dev/null | head -1)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="${INSTALL_DIR}/.env"
CONTAINER="db-websearch"
SEARXNG_VERSION="${DB_SEARXNG_VERSION:-57ff753ad416b7bf27e59d72ae8c7cac93b56be4}"
IMAGE="docker.io/searxng/searxng:latest"
UNIT_NAME="db-websearch.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
CONF_DIR="$INSTALL_DIR/websearch"

show_usage() {
    echo "使用方法: $0 [--port <番号>]"
    echo ""
    echo "オプション:"
    echo "  --port <番号>  待ち受けポート (既定 8888。127.0.0.1 のみで待ち受け)"
    echo ""
    echo "リモート実行:"
    echo "  curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-websearch.sh | bash"
}

PORT="8888"
while [ $# -gt 0 ]; do
    case "$1" in
        --port)
            shift
            [ -n "${1:-}" ] || { echo "[ERROR] --port には番号が必要です"; exit 1; }
            PORT="$1"
            ;;
        --port=*) PORT="${1#--port=}" ;;
        -h|--help) show_usage; exit 0 ;;
        *)
            echo "[ERROR] 無効な引数: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
    shift
done
case "$PORT" in
    ''|*[!0-9]*) echo "[ERROR] --port は数字で指定してください: $PORT"; exit 1 ;;
esac
BASE_URL="http://127.0.0.1:${PORT}"

echo "=========================================="
echo "  DigitalBase Web 検索 (SearXNG) インストーラー"
echo "=========================================="
echo ""
echo "待ち受け: 127.0.0.1:${PORT}"
echo ""

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] DigitalBase がインストールされていません: $INSTALL_DIR"
    echo "   先に DigitalBase をインストールしてください (別の場所なら DB_INSTALL_DIR=... で指定)"
    exit 1
fi

# ── uv で動かせる機か (root か パスワード無し sudo が要る: system unit のため) ──
SUDO=""
USE_NATIVE=false
if [ "$(uname -s)" = "Linux" ] && command -v systemctl &> /dev/null; then
    if [ "$(id -u)" -eq 0 ]; then
        USE_NATIVE=true
    elif command -v sudo &> /dev/null && sudo -n true 2> /dev/null; then
        SUDO="sudo -n"
        USE_NATIVE=true
    fi
fi

# 本体の実行ユーザー (uv の環境と設定は本体と同じユーザーのものにする)
DB_USER="$(sed -n 's/^User=//p' /etc/systemd/system/db.service 2>/dev/null | head -1)"
DB_USER="${DB_USER:-$(stat -c %U "$INSTALL_DIR" 2>/dev/null || id -un)}"
DB_HOME="$(getent passwd "$DB_USER" 2>/dev/null | cut -d: -f6)"
DB_HOME="${DB_HOME:-$HOME}"

as_db_user() {
    if [ "$(id -un)" = "$DB_USER" ]; then
        env HOME="$DB_HOME" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        runuser -u "$DB_USER" -- env HOME="$DB_HOME" "$@"
    else
        sudo -n -u "$DB_USER" env HOME="$DB_HOME" "$@"
    fi
}

# ── 設定 (入れ直しでも secret_key は替えない) ──
# limiter は公開サーバー向けのボット避け。本体だけが 127.0.0.1 から頼むので切る。本体は format=json で頼む
write_settings() {
    local secret
    as_db_user mkdir -p "$CONF_DIR"
    if [ -f "$CONF_DIR/settings.yml" ]; then
        echo "既存の設定を使います: $CONF_DIR/settings.yml"
        return 0
    fi
    secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' \
        "# DigitalBase の Web 検索用 (install-websearch.sh が作成)。既定は SearXNG の settings.yml を引き継ぐ" \
        "use_default_settings: true" \
        "server:" \
        "  secret_key: \"$secret\"" \
        "  limiter: false" \
        "  public_instance: false" \
        "  image_proxy: false" \
        "search:" \
        "  formats:" \
        "    - html" \
        "    - json" \
        | as_db_user tee "$CONF_DIR/settings.yml" > /dev/null
    as_db_user chmod 600 "$CONF_DIR/settings.yml"
}

install_native() {
    local dir short uv venv unit_tmp old
    short="${SEARXNG_VERSION:0:9}"
    dir="$CONF_DIR/searxng-$short"

    # 前のコンテナ / unit が同じポートを掴んでいると起動できない
    $SUDO systemctl stop "$UNIT_NAME" > /dev/null 2>&1 || true
    if command -v docker > /dev/null 2>&1; then
        docker rm -f "$CONTAINER" > /dev/null 2>&1 || $SUDO docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
    fi
    if command -v podman > /dev/null 2>&1; then
        as_db_user podman rm -f "$CONTAINER" > /dev/null 2>&1 || true
    fi

    uv="$DB_HOME/.local/bin/uv"
    if [ ! -x "$uv" ]; then
        if command -v uv > /dev/null 2>&1; then
            uv="$(command -v uv)"
        else
            echo "uv をインストール中..."
            curl -LsSf https://astral.sh/uv/install.sh | as_db_user UV_NO_MODIFY_PATH=1 sh
        fi
    fi

    echo "SearXNG ${short} を取得中..."
    as_db_user rm -rf "$dir"
    as_db_user mkdir -p "$dir"
    curl -fsSL "https://github.com/searxng/searxng/archive/${SEARXNG_VERSION}.tar.gz" | as_db_user tar xz -C "$dir" --strip-components=1
    # git の外では版を git から読めないので、公式の配布物と同じく固定の版を書いておく
    printf '%s\n' \
        "VERSION_STRING = \"${short}\"" \
        "VERSION_TAG = \"${short}\"" \
        "DOCKER_TAG = \"${short}\"" \
        "GIT_URL = \"https://github.com/searxng/searxng\"" \
        "GIT_BRANCH = \"master\"" \
        | as_db_user tee "$dir/searx/version_frozen.py" > /dev/null

    echo "Python と依存をインストール中..."
    venv="$dir/venv"
    as_db_user "$uv" venv --python 3.12 --managed-python "$venv"
    as_db_user VIRTUAL_ENV="$venv" UV_HTTP_TIMEOUT=120 UV_HTTP_RETRIES=3 "$uv" pip install --python "$venv/bin/python" \
        -r "$dir/requirements.txt" -r "$dir/requirements-server.txt"

    unit_tmp="$(mktemp)"
    {
        echo "[Unit]"
        echo "Description=DB Web Search (SearXNG)"
        echo "After=network-online.target"
        echo "After=db.service"
        echo "Wants=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "User=$DB_USER"
        echo "WorkingDirectory=$dir"
        # SELinux は systemd がホーム配下のファイルを直接起動するのを止める (203/EXEC)。bash 経由なら通る
        if command -v selinuxenabled > /dev/null 2>&1 && selinuxenabled; then
            echo "ExecStart=/bin/bash -c \"exec $venv/bin/granian searx.webapp:app\""
        else
            echo "ExecStart=$venv/bin/granian searx.webapp:app"
        fi
        echo "Restart=on-failure"
        echo "RestartSec=10"
        echo "Environment=\"PYTHONPATH=$dir\""
        echo "Environment=PYTHONUNBUFFERED=1"
        echo "Environment=\"SEARXNG_SETTINGS_PATH=$CONF_DIR/settings.yml\""
        echo "Environment=GRANIAN_INTERFACE=wsgi"
        echo "Environment=GRANIAN_HOST=127.0.0.1"
        echo "Environment=GRANIAN_PORT=$PORT"
        echo "Environment=GRANIAN_BLOCKING_THREADS=4"
        echo "SyslogIdentifier=db-websearch"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$unit_tmp"
    $SUDO install -o root -g root -m 644 "$unit_tmp" "$UNIT_PATH"
    rm -f "$unit_tmp"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT_NAME" > /dev/null
    $SUDO systemctl restart "$UNIT_NAME"

    # 前のバージョンの環境を片付ける
    for old in "$CONF_DIR"/searxng-*; do
        [ "$old" = "$dir" ] || [ ! -d "$old" ] || as_db_user rm -rf "$old"
    done
}

write_settings

# ── コンテナで動かす時 (RHEL の標準は Podman。Docker が無ければ Podman で動かす) ──
if [ "$USE_NATIVE" = true ]; then
    install_native
elif command -v docker &> /dev/null; then
    DOCKER="docker"
    if ! docker info &> /dev/null; then
        if command -v sudo &> /dev/null && sudo -n docker info &> /dev/null; then
            DOCKER="sudo docker"
        else
            echo "[ERROR] Docker に接続できません (デーモン停止中、またはこのユーザーに権限がありません)"
            echo "   sudo usermod -aG docker \$(id -un) の後に再ログインするか、sudo で実行してください"
            exit 1
        fi
    fi
elif command -v podman &> /dev/null; then
    DOCKER="podman"
    echo "Docker が無いので Podman で動かします"
else
    echo "[ERROR] Docker / Podman が見つかりません。"
    echo "   Linux なら、root か パスワード無し sudo があればコンテナ無しで入れられます: sudo bash で再実行してください"
    echo "   Docker を入れてから再実行することもできます: https://docs.docker.com/engine/install/"
    echo "   どちらも使えない場合は、キーを入れて Brave / Serper / Tavily を使えます (管理画面 → システム → Web 検索)"
    exit 1
fi

if [ "$USE_NATIVE" != true ]; then
    if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "既存の ${CONTAINER} コンテナを置き換えます..."
        $DOCKER rm -f "$CONTAINER" > /dev/null
    fi
    if [ -f "$UNIT_PATH" ]; then
        sudo -n systemctl disable --now "$UNIT_NAME" > /dev/null 2>&1 || echo "[WARN] $UNIT_NAME を止められませんでした: sudo systemctl disable --now $UNIT_NAME"
    fi

    echo "image を取得中..."
    # Docker Hub への接続は IPv6 で一度失敗することがあるので数回試す
    for attempt in 1 2 3; do
        if $DOCKER pull "$IMAGE"; then break; fi
        [ "$attempt" -lt 3 ] || { echo "[ERROR] image を取得できませんでした: $IMAGE"; exit 1; }
        sleep 3
    done

    echo "コンテナを起動中..."
    # 設定はコンテナの中の利用者 (uid 977) が読むので、読めるようにしておく
    chmod 644 "$CONF_DIR/settings.yml"
    $DOCKER run -d --name "$CONTAINER" --restart unless-stopped \
        -p "127.0.0.1:${PORT}:8080" \
        -v "$CONF_DIR/settings.yml:/etc/searxng/settings.yml:ro" \
        "$IMAGE" > /dev/null
fi

echo "起動を待っています (最大 120 秒)..."
READY=false
for _ in $(seq 1 60); do
    if curl -fsS "${BASE_URL}/healthz" > /dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done
if [ "$READY" != true ]; then
    if [ "$USE_NATIVE" = true ]; then
        # 動かない unit を再起動で回し続けない
        $SUDO systemctl disable --now "$UNIT_NAME" > /dev/null 2>&1 || true
        echo "[ERROR] SearXNG が応答しません。ログを確認してください: journalctl -u $UNIT_NAME -n 50"
    else
        echo "[ERROR] SearXNG が応答しません。ログを確認してください: $DOCKER logs $CONTAINER"
    fi
    exit 1
fi
if ! curl -fsS "${BASE_URL}/search?q=test&format=json" > /dev/null 2>&1; then
    echo "[WARN] 検索の JSON が返りません。$CONF_DIR/settings.yml の search.formats に json があるか確認してください"
fi
echo "[OK] SearXNG が応答しました"

# Podman はデーモンが無く、--restart だけでは機の再起動後に戻らない
if [ "$USE_NATIVE" != true ] && [ "$DOCKER" = "podman" ]; then
    if ! { loginctl enable-linger "$(id -un)" && systemctl --user enable podman-restart.service; } > /dev/null 2>&1; then
        echo "[WARN] 機の再起動後の自動起動を設定できませんでした。再起動後は podman start ${CONTAINER} で起動してください"
    fi
fi

# ── .env (printf 使用: echo >> は past incident のため禁止) ──
set_env() {
    local key="$1" value="$2"
    touch "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        # 末尾に改行が無い .env に追記すると前の行と連結する → 先に改行を補う
        [ -z "$(tail -c1 "$ENV_FILE")" ] || printf '\n' >> "$ENV_FILE"
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    echo ".envを更新: ${key}=${value}"
}
set_env WEB_SEARCH_ENGINE searxng
set_env WEB_SEARCH_SEARXNG_URL "$BASE_URL"
# root で実行すると sed -i で .env の所有者が root に替わり、本体が読めなくなる
if [ "$(id -u)" -eq 0 ] && [ "$DB_USER" != "root" ]; then
    chown "$DB_USER" "$ENV_FILE"
fi

echo ""
echo "[OK] インストール完了!"
echo "   接続先:   ${BASE_URL}"
echo "   設定:     $CONF_DIR/settings.yml"
if [ "$USE_NATIVE" = true ]; then
    echo "   サービス: ${UNIT_NAME} (journalctl -u ${UNIT_NAME} / sudo systemctl disable --now ${UNIT_NAME} で停止)"
else
    echo "   コンテナ: ${CONTAINER} (${DOCKER} logs ${CONTAINER} / ${DOCKER} rm -f ${CONTAINER} で削除)"
fi
echo ""
echo "[WARN] DigitalBase の再起動が必要です (.env の WEB_SEARCH_* は起動時に読み込みます)"
echo "   再起動後、管理画面 → システム → Web 検索 で状態を確認できます。"
