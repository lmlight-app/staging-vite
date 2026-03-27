#!/bin/bash
# AI Server - YOLO Model Installer
# Downloads YOLO model for object detection functionality

set -e

INSTALL_DIR="${HOME}/.local/lmlight"
MODEL_DIR="${INSTALL_DIR}/models/yolo"

# Available models
show_usage() {
    echo "使用方法: $0 [モデル名]"
    echo ""
    echo "モデル一覧:"
    echo "  yolov8n - 6MB   (デフォルト、軽量・高速)"
    echo "  yolov8s - 22MB  (バランス型)"
    echo "  yolov8m - 52MB  (高精度)"
    echo "  yolov8l - 87MB  (高精度・GPU推奨)"
    echo "  yolov8x - 131MB (最高精度・GPU推奨)"
    echo ""
    echo "例:"
    echo "  $0              # yolov8nをインストール"
    echo "  $0 yolov8s      # yolov8sをインストール"
    echo ""
    echo "カスタムモデル:"
    echo "  学習済み .pt ファイルを ${MODEL_DIR}/ に配置してください"
    echo ""
    echo "リモート実行:"
    echo "  curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/scripts/install-yolo.sh | bash -s -- yolov8s"
}

get_model_size() {
    case "$1" in
        yolov8n) echo "6MB" ;;
        yolov8s) echo "22MB" ;;
        yolov8m) echo "52MB" ;;
        yolov8l) echo "87MB" ;;
        yolov8x) echo "131MB" ;;
        *)       echo "unknown" ;;
    esac
}

# Parse arguments
MODEL_NAME="${1:-yolov8n}"

# Validate model name
if [[ ! " yolov8n yolov8s yolov8m yolov8l yolov8x " =~ " ${MODEL_NAME} " ]]; then
    echo "❌ 無効なモデル名: $MODEL_NAME"
    echo ""
    show_usage
    exit 1
fi

MODEL_URL="https://github.com/ultralytics/assets/releases/download/v8.3.0/${MODEL_NAME}.pt"
MODEL_FILE="${MODEL_DIR}/${MODEL_NAME}.pt"
MODEL_SIZE="$(get_model_size "$MODEL_NAME")"

echo "=========================================="
echo "  AI Server YOLO物体検出モデル インストーラー"
echo "=========================================="
echo ""
echo "選択モデル: ${MODEL_NAME} (${MODEL_SIZE})"
echo ""

# Check if already installed
if [ -f "$MODEL_FILE" ]; then
    echo "✅ モデルは既にインストールされています: $MODEL_FILE"
    echo ""
    echo "再インストールする場合は、まず以下を削除してください:"
    echo "  rm $MODEL_FILE"
    exit 0
fi

# Check install directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo "❌ AI Serverがインストールされていません"
    echo "   先にAI Serverをインストールしてください"
    exit 1
fi

# Create model directory (don't remove existing - allow multiple models)
echo "📁 モデルディレクトリを作成: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

# Download model
echo "📥 YOLO ${MODEL_NAME}モデルをダウンロード中..."
echo "   URL: $MODEL_URL"
echo "   サイズ: 約${MODEL_SIZE}"
echo ""

if command -v curl &> /dev/null; then
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
elif command -v wget &> /dev/null; then
    wget --show-progress -O "$MODEL_FILE" "$MODEL_URL"
else
    echo "❌ curlまたはwgetが必要です"
    exit 1
fi

# Install ultralytics
echo ""
echo "📦 ultralyticsパッケージを確認中..."

# Ensure uv is available
if ! command -v uv &> /dev/null; then
    echo "📥 uv をインストール中..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# pyproject.toml があれば uv sync
if [ -f "${INSTALL_DIR}/pyproject.toml" ]; then
    cd "$INSTALL_DIR"
    if uv run python -c "import ultralytics" 2>/dev/null; then
        echo "✅ ultralytics は既にインストール済み"
    else
        echo "📥 ultralytics をインストール中... (uv sync)"
        uv sync --extra yolo --quiet
    fi
else
    # venv なければ作成
    VENV_DIR="${INSTALL_DIR}/.venv"
    if [ ! -d "$VENV_DIR" ]; then
        echo "📥 venv を作成中..."
        uv venv "$VENV_DIR" --quiet
    fi

    if "$VENV_DIR/bin/python" -c "import ultralytics" 2>/dev/null; then
        echo "✅ ultralytics は既にインストール済み"
    else
        echo "📥 ultralytics をインストール中... (uv pip install)"
        uv pip install ultralytics --python "$VENV_DIR/bin/python" --quiet
    fi

    # Set VENV_PYTHON in .env so the binary can find the venv
    ENV_FILE="${INSTALL_DIR}/.env"
    if [ -f "$ENV_FILE" ]; then
        if grep -q "^VENV_PYTHON=" "$ENV_FILE"; then
            sed -i.bak "s|^VENV_PYTHON=.*|VENV_PYTHON=$VENV_DIR/bin/python|" "$ENV_FILE"
            rm -f "${ENV_FILE}.bak"
        else
            echo "VENV_PYTHON=$VENV_DIR/bin/python" >> "$ENV_FILE"
        fi
        echo "📝 .envを更新: VENV_PYTHON=$VENV_DIR/bin/python"
    fi
fi

# Verify download
if [ -f "$MODEL_FILE" ]; then
    SIZE=$(ls -lh "$MODEL_FILE" | awk '{print $5}')
    echo ""
    echo "✅ インストール完了!"
    echo "   モデル: ${MODEL_NAME}"
    echo "   ファイル: $MODEL_FILE"
    echo "   サイズ: $SIZE"
    echo ""
    echo "AI Serverを再起動すると、画像処理ページで物体検出が利用可能になります"
else
    echo "❌ ダウンロードに失敗しました"
    exit 1
fi
