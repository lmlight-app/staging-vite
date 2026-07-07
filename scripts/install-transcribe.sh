#!/bin/bash
# AI Server - Transcription Model Installer
# Downloads Whisper model for speech-to-text functionality

set -e

INSTALL_DIR="${HOME}/.local/db"
MODEL_DIR="${INSTALL_DIR}/models/whisper"
ENV_FILE="${INSTALL_DIR}/.env"

# Get model size (bash 3.2 compatible - no associative arrays)
get_model_size() {
    case "$1" in
        tiny)   echo "74MB" ;;
        base)   echo "142MB" ;;
        small)  echo "466MB" ;;
        medium) echo "1.5GB" ;;
        large)  echo "2.9GB" ;;
        *)      echo "unknown" ;;
    esac
}

show_usage() {
    echo "使用方法: $0 [モデル名] [--gpu]"
    echo ""
    echo "モデル一覧:"
    echo "  tiny   - 74MB  (デフォルト、軽量・高速)"
    echo "  base   - 142MB (バランス型)"
    echo "  small  - 466MB (高精度)"
    echo "  medium - 1.5GB (高精度・GPU推奨)"
    echo "  large  - 2.9GB (最高精度・GPU必須)"
    echo ""
    echo "オプション:"
    echo "  --gpu  GPU版をインストール (openai-whisper + torch)"
    echo ""
    echo "例:"
    echo "  $0              # tinyモデルをインストール (CPU)"
    echo "  $0 small        # smallモデルをインストール (CPU)"
    echo "  $0 small --gpu  # smallモデル + GPU版をインストール"
    echo ""
    echo "リモート実行:"
    echo "  curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/scripts/install-transcribe.sh | bash -s -- small"
    echo "  curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/scripts/install-transcribe.sh | bash -s -- small --gpu"
}

# Parse arguments
MODEL_NAME="tiny"
GPU_MODE=false

for arg in "$@"; do
    case "$arg" in
        --gpu) GPU_MODE=true ;;
        tiny|base|small|medium|large) MODEL_NAME="$arg" ;;
        *)
            echo "[ERROR] 無効な引数: $arg"
            echo ""
            show_usage
            exit 1
            ;;
    esac
done

# large uses v3 version
if [ "$MODEL_NAME" = "large" ]; then
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
    MODEL_FILE="${MODEL_DIR}/ggml-large-v3.bin"
else
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
    MODEL_FILE="${MODEL_DIR}/ggml-${MODEL_NAME}.bin"
fi
MODEL_SIZE="$(get_model_size "$MODEL_NAME")"

echo "=========================================="
echo "  AI Server 文字起こしモデル インストーラー"
echo "=========================================="
echo ""
echo "選択モデル: ${MODEL_NAME} (${MODEL_SIZE})"
echo ""

# Check if already installed
if [ -f "$MODEL_FILE" ]; then
    echo "[OK] モデルは既にインストールされています: $MODEL_FILE"
    echo ""
    echo "再インストールする場合は、まず以下を削除してください:"
    echo "  rm -rf $MODEL_DIR"
    exit 0
fi

# Check install directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] AI Serverがインストールされていません"
    echo "   先にAI Serverをインストールしてください"
    exit 1
fi

# Remove old model files (different model)
if [ -d "$MODEL_DIR" ]; then
    echo "既存のモデルを削除..."
    rm -rf "$MODEL_DIR"
fi

# Create model directory
echo "モデルディレクトリを作成: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

# Download model
echo "Whisper ${MODEL_NAME}モデルをダウンロード中..."
echo "   URL: $MODEL_URL"
echo "   サイズ: 約${MODEL_SIZE}"
echo ""

if command -v curl &> /dev/null; then
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
elif command -v wget &> /dev/null; then
    wget --show-progress -O "$MODEL_FILE" "$MODEL_URL"
else
    echo "[ERROR] curlまたはwgetが必要です"
    exit 1
fi

# Update .env WHISPER_MODEL
if [ -f "$ENV_FILE" ]; then
    if grep -q "^WHISPER_MODEL=" "$ENV_FILE"; then
        sed -i.bak "s/^WHISPER_MODEL=.*/WHISPER_MODEL=${MODEL_NAME}/" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        echo "WHISPER_MODEL=${MODEL_NAME}" >> "$ENV_FILE"
    fi
    echo ".envを更新: WHISPER_MODEL=${MODEL_NAME}"
fi

# GPU mode: install openai-whisper + torch
# ※ GPU版(torch) が効くのは「ソース実行(pyproject.toml あり)」の配布のみ。
#   バイナリ配布(./api, pywhispercpp/CPU 同梱)は torch を使わないので --gpu は無効。
if [ "$GPU_MODE" = true ]; then
    echo ""
    if [ -f "${INSTALL_DIR}/pyproject.toml" ]; then
        # ソース配布: api が venv の torch/openai-whisper を使うので有効
        if ! command -v uv &> /dev/null; then
            echo "uv をインストール中..."
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
        fi
        cd "$INSTALL_DIR"
        echo "GPU版 (openai-whisper + torch) をインストール中... (uv sync)"
        uv sync --extra gpu --quiet
        echo "[OK] GPU版インストール完了"
    else
        # バイナリ配布: 同梱の pywhispercpp(CPU) で動作。torch は使われないのでスキップ。
        echo "[WARN] この配布はバイナリ版 (CPU pywhispercpp 同梱) です。"
        echo "   --gpu (openai-whisper + torch) はこの配布では使用されないためスキップします。"
        echo "   (GPU 文字起こしが必要な場合はソース版での実行が必要です)"
        GPU_MODE=false   # 最終表示を CPU 版に統一
    fi
fi

# Verify download
if [ -f "$MODEL_FILE" ]; then
    SIZE=$(ls -lh "$MODEL_FILE" | awk '{print $5}')
    echo ""
    echo "[OK] インストール完了!"
    echo "   モデル: ${MODEL_NAME}"
    echo "   ファイル: $MODEL_FILE"
    echo "   サイズ: $SIZE"
    if [ "$GPU_MODE" = true ]; then
        echo "   GPU: 有効 (openai-whisper)"
    else
        echo "   GPU: 無効 (CPU版 pywhispercpp)"
    fi
    echo ""
    echo "[WARN] AI Server の再起動が必須です（再起動しないと旧モデルがキャッシュされ 503 になります）"
    echo "   再起動後、サイドバーに「文字起こし」が表示され、利用できます。"
else
    echo "[ERROR] ダウンロードに失敗しました"
    exit 1
fi