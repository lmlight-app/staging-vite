#!/bin/bash
# DigitalBase - Text-to-Speech (読み上げ) Engine Installer
# 読み上げ用の音声合成サーバーをこのサーバー機に立て、.env の TTS_* を設定する。
#   kokoro   … Kokoro-FastAPI (OpenAI 互換 /v1/audio/speech、Apache-2.0)。多言語、日本語は女性 1 声 (jf_alpha)
#              Linux + systemd + root / パスワード無し sudo なら uv で入れて db-tts.service で常駐させる。それ以外はコンテナ
#   voicevox … VOICEVOX ENGINE (日本語特化、話者が多い)。話者ごとに利用規約 (クレジット表記等) がある。コンテナで動かす
# DigitalBase 本体は server から http://127.0.0.1:<port> に頼むだけ (= 合成サーバーは外に公開しない)。
#
# 環境変数: DB_INSTALL_DIR (本体の配置先)、DB_KOKORO_VERSION (Kokoro-FastAPI の tag)

set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$(sed -n 's/^WorkingDirectory=//p' /etc/systemd/system/db.service 2>/dev/null | head -1)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="${INSTALL_DIR}/.env"
CONTAINER="db-tts"
KOKORO_VERSION="${DB_KOKORO_VERSION:-v0.9.2}"
UNIT_NAME="db-tts.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

show_usage() {
    echo "使用方法: $0 [kokoro | voicevox] [--gpu] [--port <番号>]"
    echo ""
    echo "エンジン:"
    echo "  kokoro    - Kokoro-FastAPI (デフォルト。多言語、CPU でも実用速度、約 3GB)"
    echo "  voicevox  - VOICEVOX ENGINE (日本語の話者が多い。話者ごとの利用規約を確認してください)"
    echo ""
    echo "オプション:"
    echo "  --gpu          NVIDIA GPU で動かす (コンテナの時は要 NVIDIA Container Toolkit)"
    echo "  --port <番号>  待ち受けポート (既定: kokoro 8880 / voicevox 50021。127.0.0.1 のみで待ち受け)"
    echo ""
    echo "リモート実行:"
    echo "  curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-tts.sh | bash -s -- kokoro"
    echo "  curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-tts.sh | bash -s -- voicevox --gpu"
}

ENGINE="kokoro"
GPU_MODE=false
PORT=""

while [ $# -gt 0 ]; do
    case "$1" in
        kokoro|voicevox) ENGINE="$1" ;;
        --gpu) GPU_MODE=true ;;
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

if [ "$ENGINE" = "kokoro" ]; then
    INNER_PORT=8880
    PORT="${PORT:-8880}"
    IMAGE="ghcr.io/remsky/kokoro-fastapi-cpu:latest"
    [ "$GPU_MODE" = true ] && IMAGE="ghcr.io/remsky/kokoro-fastapi-gpu:latest"
    HEALTH_PATH="/v1/audio/voices"
    BASE_URL="http://127.0.0.1:${PORT}/v1"
else
    INNER_PORT=50021
    PORT="${PORT:-50021}"
    # Podman は短い名前を非対話で解決できないので docker.io から書く
    IMAGE="docker.io/voicevox/voicevox_engine:cpu-latest"
    [ "$GPU_MODE" = true ] && IMAGE="docker.io/voicevox/voicevox_engine:nvidia-latest"
    HEALTH_PATH="/speakers"
    BASE_URL="http://127.0.0.1:${PORT}"
fi

echo "=========================================="
echo "  DigitalBase 読み上げエンジン インストーラー"
echo "=========================================="
echo ""
echo "エンジン: ${ENGINE}"
echo "待ち受け: 127.0.0.1:${PORT}"
echo ""

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] DigitalBase がインストールされていません: $INSTALL_DIR"
    echo "   先に DigitalBase をインストールしてください (別の場所なら DB_INSTALL_DIR=... で指定)"
    exit 1
fi

# ── Kokoro を uv で動かせる機か (root か パスワード無し sudo が要る: ビルドに使うパッケージと system unit のため) ──
SUDO=""
USE_NATIVE=false
if [ "$ENGINE" = "kokoro" ] && [ "$(uname -s)" = "Linux" ] && command -v systemctl &> /dev/null; then
    if [ "$(id -u)" -eq 0 ]; then
        USE_NATIVE=true
    elif command -v sudo &> /dev/null && sudo -n true 2> /dev/null; then
        SUDO="sudo -n"
        USE_NATIVE=true
    fi
fi

# 本体の実行ユーザー (uv の環境とモデルは本体と同じユーザーのものにする)
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

# 補助サーバー画面の停止 / 起動ボタン用。install-reranker.sh / install-media.sh と同じ内容を書く
install_sudoers_rule() {
    local sc visudo tmp u v first=1
    [ "$DB_USER" != "root" ] || return 0
    visudo="$(command -v visudo 2>/dev/null || true)"
    [ -n "$visudo" ] || { [ -x /usr/sbin/visudo ] && visudo=/usr/sbin/visudo; }
    if ! command -v sudo > /dev/null 2>&1 || [ -z "$visudo" ]; then
        echo "[WARN] sudo が無いので、補助サーバー画面の停止 / 起動ボタンは使えません"
        return 0
    fi
    sc="$(readlink -f "$(command -v systemctl)")"
    tmp="$(mktemp)"
    {
        echo "# DigitalBase: db.service の実行ユーザーに補助サーバーの unit の操作だけを許可する"
        printf 'Cmnd_Alias DB_AUX_UNITS = '
        for u in db-reranker.service db-media-image.service db-media-video.service db-tts.service; do
            for v in start stop restart "enable --now" "disable --now"; do
                [ "$first" -eq 1 ] || printf ', \\\n    '
                printf '%s %s %s' "$sc" "$v" "$u"
                first=0
            done
        done
        printf '\n%s ALL=(root) NOPASSWD: DB_AUX_UNITS\n' "$DB_USER"
    } > "$tmp"
    chmod 0440 "$tmp"
    if "$visudo" -cf "$tmp" > /dev/null; then
        $SUDO install -o root -g root -m 0440 "$tmp" /etc/sudoers.d/digitalbase-units
        if ! $SUDO "$visudo" -c > /dev/null 2>&1; then
            $SUDO rm -f /etc/sudoers.d/digitalbase-units
            echo "[WARN] sudoers の検証に失敗したので外しました。補助サーバー画面の停止 / 起動ボタンは使えません"
        fi
    else
        echo "[WARN] sudoers の検証に失敗したので置きませんでした。補助サーバー画面の停止 / 起動ボタンは使えません"
    fi
    rm -f "$tmp"
}

# Kokoro のビルド (pyopenjtalk は sdist のみ) と実行に要るパッケージ。公式の Dockerfile と同じ物
install_kokoro_packages() {
    local p
    if command -v apt-get > /dev/null 2>&1; then
        $SUDO apt-get update -qq
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq g++ cmake make espeak-ng espeak-ng-data libsndfile1
    elif command -v dnf > /dev/null 2>&1; then
        $SUDO dnf install -y gcc-c++ cmake make
        # espeak-ng は未知の語の読みの補助で、Python 側にも同梱がある。libsndfile も wheel に同梱。無くても止めない
        for p in espeak-ng libsndfile; do
            $SUDO dnf install -y "$p" || echo "[WARN] $p を入れられませんでした (無くても動きますが、未知の語の読みが落ちることがあります)"
        done
    else
        echo "[WARN] パッケージマネージャが見つかりません。g++ / cmake / make / espeak-ng は入っている前提で続けます"
    fi
}

install_kokoro_native() {
    local dir extra uv espeak_data unit_tmp old
    dir="$INSTALL_DIR/tts/kokoro-$KOKORO_VERSION"
    extra="cpu"
    [ "$GPU_MODE" = true ] && extra="gpu"

    echo "必要なパッケージを入れます..."
    install_kokoro_packages

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

    echo "Kokoro-FastAPI ${KOKORO_VERSION} を取得中..."
    as_db_user rm -rf "$dir"
    as_db_user mkdir -p "$dir"
    curl -fsSL "https://github.com/remsky/Kokoro-FastAPI/archive/refs/tags/${KOKORO_VERSION}.tar.gz" | as_db_user tar xz -C "$dir" --strip-components=1

    echo "Python と依存をインストール中 (PyTorch を含むので数分かかります)..."
    as_db_user "$uv" venv --python 3.12 --managed-python "$dir/.venv"
    as_db_user UV_HTTP_TIMEOUT=120 UV_HTTP_RETRIES=3 "$uv" sync --project "$dir" --frozen --extra "$extra" --no-install-project

    echo "音声モデルと日本語辞書を取得中..."
    as_db_user "$dir/.venv/bin/python" "$dir/docker/scripts/download_model.py" --output "$dir/api/src/models/v1_0"
    as_db_user "$dir/.venv/bin/python" -m unidic download

    espeak_data="$(find /usr/lib /usr/lib64 /usr/share -type d -name espeak-ng-data 2>/dev/null | head -1)"
    unit_tmp="$(mktemp)"
    {
        echo "[Unit]"
        echo "Description=DB Text-to-Speech (Kokoro-FastAPI)"
        echo "After=network-online.target"
        echo "After=db.service"
        echo "Wants=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "User=$DB_USER"
        echo "WorkingDirectory=$dir"
        echo "ExecStart=$dir/.venv/bin/python -m uvicorn api.src.main:app --host 127.0.0.1 --port $PORT"
        echo "Restart=on-failure"
        echo "RestartSec=10"
        echo "Environment=\"PYTHONPATH=$dir:$dir/api\""
        echo "Environment=PYTHONUNBUFFERED=1"
        echo "Environment=MODEL_DIR=src/models"
        echo "Environment=VOICES_DIR=src/voices/v1_0"
        echo "Environment=\"WEB_PLAYER_PATH=$dir/web\""
        if [ "$GPU_MODE" = true ]; then
            echo "Environment=USE_GPU=true"
            echo "Environment=DEVICE=gpu"
        else
            echo "Environment=USE_GPU=false"
            echo "Environment=DEVICE=cpu"
        fi
        if [ -n "$espeak_data" ]; then
            echo "Environment=PHONEMIZER_ESPEAK_PATH=/usr/bin"
            echo "Environment=\"PHONEMIZER_ESPEAK_DATA=$espeak_data\""
            echo "Environment=\"ESPEAK_DATA_PATH=$espeak_data\""
        fi
        echo "SyslogIdentifier=db-tts"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$unit_tmp"
    $SUDO install -o root -g root -m 644 "$unit_tmp" "$UNIT_PATH"
    rm -f "$unit_tmp"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT_NAME" > /dev/null
    $SUDO systemctl restart "$UNIT_NAME"
    install_sudoers_rule

    # 前のバージョンの環境を片付ける
    for old in "$INSTALL_DIR"/tts/kokoro-*; do
        [ "$old" = "$dir" ] || [ ! -d "$old" ] || as_db_user rm -rf "$old"
    done
}

# ── コンテナで動かす時 (RHEL の標準は Podman。Docker が無ければ Podman で動かす) ──
if [ "$USE_NATIVE" = true ]; then
    install_kokoro_native
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
    echo "[ERROR] Docker / Podman が見つかりません。読み上げエンジンはコンテナで動かします。"
    echo "   Docker を入れてから再実行してください: https://docs.docker.com/engine/install/"
    echo "   RHEL は sudo dnf install -y podman でも動きます"
    if [ "$ENGINE" = "kokoro" ]; then
        echo "   Kokoro は Linux なら、root か パスワード無し sudo があればコンテナ無しで入れられます: sudo bash で再実行してください"
    fi
    echo "   どちらも使えない場合は、OpenAI 互換の読み上げ API を .env で直接指定できます:"
    echo "     TTS_ENGINE=openai  TTS_BASE_URL=<接続先>/v1  TTS_API_KEY=<キー>  TTS_MODEL=<モデル>"
    exit 1
fi

if [ "$USE_NATIVE" != true ]; then
    GPU_ARGS=""
    if [ "$GPU_MODE" = true ]; then
        GPU_ARGS="--gpus all"
        [ "$DOCKER" = "podman" ] && GPU_ARGS="--device nvidia.com/gpu=all"
    fi

    # 同名コンテナ (= 以前のインストール / 別エンジン) は置き換える
    if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "既存の ${CONTAINER} コンテナを置き換えます..."
        $DOCKER rm -f "$CONTAINER" > /dev/null
    fi

    # uv で入れた Kokoro から VOICEVOX へ替える時は、前の常駐を止める
    if [ -f "$UNIT_PATH" ]; then
        sudo -n systemctl disable --now "$UNIT_NAME" > /dev/null 2>&1 || echo "[WARN] $UNIT_NAME を止められませんでした: sudo systemctl disable --now $UNIT_NAME"
    fi

    echo "image を取得中 (初回は数 GB のダウンロードがあります)..."
    $DOCKER pull "$IMAGE"

    echo "コンテナを起動中..."
    # shellcheck disable=SC2086
    $DOCKER run -d --name "$CONTAINER" --restart unless-stopped $GPU_ARGS \
        -p "127.0.0.1:${PORT}:${INNER_PORT}" "$IMAGE" > /dev/null
fi

echo "起動を待っています (最大 300 秒)..."
READY=false
for _ in $(seq 1 150); do
    if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" > /dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done
if [ "$READY" != true ]; then
    if [ "$USE_NATIVE" = true ]; then
        echo "[ERROR] ${HEALTH_PATH} が応答しません。ログを確認してください: journalctl -u $UNIT_NAME -n 50"
    else
        echo "[ERROR] ${HEALTH_PATH} が応答しません。ログを確認してください: $DOCKER logs $CONTAINER"
    fi
    exit 1
fi
echo "[OK] 読み上げエンジンが応答しました"

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
if [ "$ENGINE" = "kokoro" ]; then
    set_env TTS_ENGINE openai
    set_env TTS_MODEL kokoro
    set_env TTS_VOICE jf_alpha
else
    set_env TTS_ENGINE voicevox
    set_env TTS_MODEL ""
    set_env TTS_VOICE ""
fi
set_env TTS_BASE_URL "$BASE_URL"
set_env TTS_API_KEY ""
# root で実行すると sed -i で .env の所有者が root に替わり、本体が読めなくなる
if [ "$(id -u)" -eq 0 ] && [ "$DB_USER" != "root" ]; then
    chown "$DB_USER" "$ENV_FILE"
fi

echo ""
echo "[OK] インストール完了!"
echo "   エンジン: ${ENGINE}"
echo "   接続先:   ${BASE_URL}"
if [ "$USE_NATIVE" = true ]; then
    echo "   サービス: ${UNIT_NAME} (journalctl -u ${UNIT_NAME} / sudo systemctl disable --now ${UNIT_NAME} で停止)"
else
    echo "   コンテナ: ${CONTAINER} (${DOCKER} logs ${CONTAINER} / ${DOCKER} rm -f ${CONTAINER} で削除)"
fi
if [ "$ENGINE" = "voicevox" ]; then
    echo ""
    echo "[注意] VOICEVOX の音声は話者ごとに利用規約があります (クレジット表記「VOICEVOX:<話者名>」等)。"
    echo "   業務で使う前に https://voicevox.hiroshiba.jp/ の各話者の規約を確認してください。"
fi
echo ""
echo "[WARN] DigitalBase の再起動が必要です (.env の TTS_* は起動時に読み込みます)"
echo "   再起動後、管理画面 → 登録管理 → 読み上げ で状態を確認できます。"
