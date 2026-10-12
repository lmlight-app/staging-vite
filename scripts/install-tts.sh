#!/bin/bash
# DigitalBase - Text-to-Speech (読み上げ) Engine Installer
# 読み上げ用の音声合成サーバーをこのサーバー機に Docker で立て、.env の TTS_* を設定する。
#   kokoro   … Kokoro-FastAPI (OpenAI 互換 /v1/audio/speech、Apache-2.0)。多言語、日本語は女性 1 声 (jf_alpha)
#   voicevox … VOICEVOX ENGINE (日本語特化、話者が多い)。話者ごとに利用規約 (クレジット表記等) がある
# DigitalBase 本体は server から http://127.0.0.1:<port> に頼むだけ (= 合成サーバーは外に公開しない)。

set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="${INSTALL_DIR}/.env"
CONTAINER="db-tts"

show_usage() {
    echo "使用方法: $0 [kokoro | voicevox] [--gpu] [--port <番号>]"
    echo ""
    echo "エンジン:"
    echo "  kokoro    - Kokoro-FastAPI (デフォルト。多言語、CPU でも実用速度、約 3GB の image)"
    echo "  voicevox  - VOICEVOX ENGINE (日本語の話者が多い。話者ごとの利用規約を確認してください)"
    echo ""
    echo "オプション:"
    echo "  --gpu          NVIDIA GPU 版 image を使う (要 NVIDIA Container Toolkit)"
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
    IMAGE="voicevox/voicevox_engine:cpu-latest"
    [ "$GPU_MODE" = true ] && IMAGE="voicevox/voicevox_engine:nvidia-latest"
    HEALTH_PATH="/speakers"
    BASE_URL="http://127.0.0.1:${PORT}"
fi

echo "=========================================="
echo "  DigitalBase 読み上げエンジン インストーラー"
echo "=========================================="
echo ""
echo "エンジン: ${ENGINE} (${IMAGE})"
echo "待ち受け: 127.0.0.1:${PORT}"
echo ""

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] DigitalBase がインストールされていません: $INSTALL_DIR"
    echo "   先に DigitalBase をインストールしてください (別の場所なら DB_INSTALL_DIR=... で指定)"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker が見つかりません。読み上げエンジンは Docker で動かします。"
    echo "   Docker を入れてから再実行してください: https://docs.docker.com/engine/install/"
    echo "   Docker を使えない場合は、OpenAI 互換の読み上げ API を .env で直接指定できます:"
    echo "     TTS_ENGINE=openai  TTS_BASE_URL=<接続先>/v1  TTS_API_KEY=<キー>  TTS_MODEL=<モデル>"
    exit 1
fi

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

GPU_ARGS=""
if [ "$GPU_MODE" = true ]; then
    GPU_ARGS="--gpus all"
fi

# 同名コンテナ (= 以前のインストール / 別エンジン) は置き換える
if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "既存の ${CONTAINER} コンテナを置き換えます..."
    $DOCKER rm -f "$CONTAINER" > /dev/null
fi

echo "image を取得中 (初回は数 GB のダウンロードがあります)..."
$DOCKER pull "$IMAGE"

echo "コンテナを起動中..."
# shellcheck disable=SC2086
$DOCKER run -d --name "$CONTAINER" --restart unless-stopped $GPU_ARGS \
    -p "127.0.0.1:${PORT}:${INNER_PORT}" "$IMAGE" > /dev/null

echo "起動を待っています (最大 180 秒)..."
READY=false
for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" > /dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done
if [ "$READY" != true ]; then
    echo "[ERROR] ${HEALTH_PATH} が応答しません。ログを確認してください: $DOCKER logs $CONTAINER"
    exit 1
fi
echo "[OK] 読み上げエンジンが応答しました"

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

echo ""
echo "[OK] インストール完了!"
echo "   エンジン: ${ENGINE}"
echo "   接続先:   ${BASE_URL}"
echo "   コンテナ: ${CONTAINER} (docker logs ${CONTAINER} / docker rm -f ${CONTAINER} で削除)"
if [ "$ENGINE" = "voicevox" ]; then
    echo ""
    echo "[注意] VOICEVOX の音声は話者ごとに利用規約があります (クレジット表記「VOICEVOX:<話者名>」等)。"
    echo "   業務で使う前に https://voicevox.hiroshiba.jp/ の各話者の規約を確認してください。"
fi
echo ""
echo "[WARN] DigitalBase の再起動が必要です (.env の TTS_* は起動時に読み込みます)"
echo "   再起動後、管理画面 → ライセンス → 読み上げ で状態を確認できます。"
