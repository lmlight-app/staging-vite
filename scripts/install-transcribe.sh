#!/bin/bash
# DigitalBase - Transcription Model Installer
# Whisper モデルを stt-model/whisper/ に配置する。形式は 2 種類:
#   ggml (whisper.cpp)  … 既定。追加 pip なし、バイナリ配布でも動く。CPU / Apple Silicon (Metal)
#   CT2  (faster-whisper) … --gpu / --ct2。ソース配布 (pyproject.toml がある) のみ。CUDA は自動判定
# backend は本体がモデル形式と GPU の有無で自動選択する (.env に GPU 設定は不要)。

set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
MODEL_DIR="${INSTALL_DIR}/stt-model/whisper"
ENV_FILE="${INSTALL_DIR}/.env"

# Get model size (bash 3.2 compatible - no associative arrays)
get_model_size() {
    case "$1" in
        tiny)         echo "75MB" ;;
        base)         echo "145MB" ;;
        small)        echo "480MB" ;;
        medium)       echo "1.5GB" ;;
        large)        echo "3.0GB" ;;
        distil-large) echo "1.5GB" ;;
        *)            echo "unknown" ;;
    esac
}

show_usage() {
    echo "使用方法: $0 [モデル名] [--gpu | --ct2] [--lang <code>]"
    echo ""
    echo "モデル一覧:"
    echo "  tiny         - 75MB  (デフォルト、軽量・高速)"
    echo "  base         - 145MB (バランス型)"
    echo "  small        - 480MB (高精度)"
    echo "  medium       - 1.5GB (高精度・GPU推奨)"
    echo "  large        - 3.0GB (最高精度・GPU必須、large-v3)"
    echo "  distil-large - 1.5GB (large 相当の精度で medium 並みの速度。--gpu / --ct2 のみ)"
    echo ""
    echo "オプション:"
    echo "  --gpu          faster-whisper を導入し CT2 形式のモデルを配置 (CUDA は自動判定。ソース配布のみ)"
    echo "  --ct2          --gpu と同じだが CUDA ライブラリを入れない (CPU で faster-whisper。ソース配布のみ)"
    echo "  --lang <code>  既定言語を .env に書く (ja / en 等。短い発話は指定した方が確実)"
    echo ""
    echo "例:"
    echo "  $0                          # tiny (whisper.cpp、CPU)"
    echo "  $0 small --lang ja          # small (whisper.cpp) + 日本語固定"
    echo "  $0 medium --gpu --lang ja   # medium (faster-whisper、CUDA があれば GPU)"
    echo ""
    echo "リモート実行:"
    echo "  curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-transcribe.sh | bash -s -- small"
    echo "  curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-transcribe.sh | bash -s -- medium --gpu --lang ja"
}

# Parse arguments
MODEL_NAME="tiny"
FORMAT="ggml"      # ggml | ct2
GPU_MODE=false     # --gpu = ct2 + CUDA ライブラリ
LANG_CODE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --gpu) FORMAT="ct2"; GPU_MODE=true ;;
        --ct2) FORMAT="ct2" ;;
        --lang)
            shift
            [ -n "${1:-}" ] || { echo "[ERROR] --lang には言語コードが必要です (例: --lang ja)"; exit 1; }
            LANG_CODE="$1"
            ;;
        --lang=*) LANG_CODE="${1#--lang=}" ;;
        tiny|base|small|medium|large|distil-large) MODEL_NAME="$1" ;;
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

if [ "$MODEL_NAME" = "distil-large" ] && [ "$FORMAT" != "ct2" ]; then
    echo "[ERROR] distil-large は faster-whisper 専用です。--gpu か --ct2 を付けてください"
    exit 1
fi

# ソース配布 (pyproject.toml あり) か バイナリ配布か。CT2 は faster-whisper の pip が要るのでソース配布のみ
IS_SOURCE=false
[ -f "${INSTALL_DIR}/pyproject.toml" ] && IS_SOURCE=true

MODEL_SIZE="$(get_model_size "$MODEL_NAME")"

# ── モデルの取得元 ──
# ggml: ggerganov/whisper.cpp の単一ファイル。large は v3
# ct2 : Systran の CT2 変換済みディレクトリ (config.json / model.bin / tokenizer.json / vocabulary.txt)。
#       ディレクトリ名は ct2-<モデル名> (= 本体がディレクトリ名からモデル名を検出する)
if [ "$FORMAT" = "ggml" ]; then
    if [ "$MODEL_NAME" = "large" ]; then
        MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
        MODEL_FILE="${MODEL_DIR}/ggml-large-v3.bin"
    else
        MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
        MODEL_FILE="${MODEL_DIR}/ggml-${MODEL_NAME}.bin"
    fi
else
    case "$MODEL_NAME" in
        large)        CT2_REPO="Systran/faster-whisper-large-v3" ;;
        distil-large) CT2_REPO="Systran/faster-distil-whisper-large-v3" ;;
        *)            CT2_REPO="Systran/faster-whisper-${MODEL_NAME}" ;;
    esac
    MODEL_URL="https://huggingface.co/${CT2_REPO}/resolve/main"
    MODEL_FILE="${MODEL_DIR}/ct2-${MODEL_NAME}"
fi

echo "=========================================="
echo "  DigitalBase 文字起こしモデル インストーラー"
echo "=========================================="
echo ""
echo "選択モデル: ${MODEL_NAME} (${MODEL_SIZE}、形式: ${FORMAT})"
echo ""

# Check install directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] DigitalBase がインストールされていません: $INSTALL_DIR"
    echo "   先に DigitalBase をインストールしてください (別の場所なら DB_INSTALL_DIR=... で指定)"
    exit 1
fi

if [ "$FORMAT" = "ct2" ] && [ "$IS_SOURCE" = false ]; then
    echo "[ERROR] この配布はバイナリ版 (whisper.cpp 同梱) のため、--gpu / --ct2 は使えません。"
    echo "   オプション無しで再実行すると whisper.cpp 用 (ggml) のモデルを配置します。"
    echo "   faster-whisper / CUDA を使う場合はソース版 (pyproject.toml がある配布) で実行してください。"
    exit 1
fi

# Check if already installed
if [ -e "$MODEL_FILE" ]; then
    echo "[OK] モデルは既にインストールされています: $MODEL_FILE"
    echo ""
    echo "再インストールする場合は、まず以下を削除してください:"
    echo "  rm -rf $MODEL_DIR"
    exit 0
fi

# Remove old model files (different model / format)
if [ -d "$MODEL_DIR" ]; then
    echo "既存のモデルを削除..."
    rm -rf "$MODEL_DIR"
fi

echo "モデルディレクトリを作成: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

# ── downloader (curl / wget) ──
if command -v curl &> /dev/null; then
    fetch() { curl -fL --progress-bar -o "$2" "$1"; }
elif command -v wget &> /dev/null; then
    fetch() { wget --show-progress -O "$2" "$1"; }
else
    echo "[ERROR] curlまたはwgetが必要です"
    exit 1
fi

echo "Whisper ${MODEL_NAME}モデルをダウンロード中..."
echo "   URL: $MODEL_URL"
echo "   サイズ: 約${MODEL_SIZE}"
echo ""

if [ "$FORMAT" = "ggml" ]; then
    fetch "$MODEL_URL" "$MODEL_FILE"
else
    mkdir -p "$MODEL_FILE"
    for f in config.json model.bin tokenizer.json vocabulary.txt; do
        echo "   $f"
        fetch "${MODEL_URL}/${f}" "${MODEL_FILE}/${f}"
    done
fi

# ── .env (printf 使用: echo >> は past incident のため禁止) ──
set_env() {
    local key="$1" value="$2"
    [ -f "$ENV_FILE" ] || return 0
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        # 末尾に改行が無い .env に追記すると前の行と連結する (2026-09-10 の本番事故) → 先に改行を補う
        [ -z "$(tail -c1 "$ENV_FILE")" ] || printf '\n' >> "$ENV_FILE"
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    echo ".envを更新: ${key}=${value}"
}
set_env WHISPER_MODEL "$MODEL_NAME"
[ -n "$LANG_CODE" ] && set_env WHISPER_LANGUAGE "$LANG_CODE"

# ── faster-whisper (ct2) の pip 導入 ──
if [ "$FORMAT" = "ct2" ]; then
    echo ""
    if ! command -v uv &> /dev/null; then
        echo "uv をインストール中..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
    cd "$INSTALL_DIR"
    ARCH="$(uname -m)"
    if [ "$GPU_MODE" = true ] && [ "$(uname -s)" = "Linux" ]; then
        echo "faster-whisper + CUDA ライブラリ (cuBLAS / cuDNN 9) をインストール中... (uv sync --extra gpu)"
        uv sync --extra gpu --quiet
    else
        echo "faster-whisper をインストール中... (uv sync --extra whisper)"
        uv sync --extra whisper --quiet
    fi
    echo "[OK] faster-whisper インストール完了"
    if [ "$GPU_MODE" = true ] && { [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; } && [ "$(uname -s)" = "Linux" ]; then
        echo ""
        echo "[WARN] Linux aarch64 (DGX Spark / Grace 等) では、公式 ctranslate2 wheel は CPU 専用です。"
        echo "   このままでも動きますが GPU は使われません (faster-whisper が CPU int8 で動作)。"
        echo "   GPU で動かす場合は次のいずれか:"
        echo "     - CUDA 13 向け community ビルド: https://github.com/assix/ctranslate2-aarch64-cuda13-binaries"
        echo "     - whisper.cpp を CUDA 有効でビルド (ggml 形式に戻す):"
        echo "         GGML_CUDA=1 CMAKE_CUDA_ARCHITECTURES=121a-real uv pip install --force-reinstall --no-cache-dir git+https://github.com/absadiki/pywhispercpp"
        echo "         その後、このスクリプトをオプション無しで再実行して ggml モデルを配置"
    fi
fi

# Verify download
if [ -e "$MODEL_FILE" ]; then
    SIZE=$(du -sh "$MODEL_FILE" | awk '{print $1}')
    echo ""
    echo "[OK] インストール完了!"
    echo "   モデル: ${MODEL_NAME} (${FORMAT})"
    echo "   配置先: $MODEL_FILE"
    echo "   サイズ: $SIZE"
    if [ "$FORMAT" = "ct2" ]; then
        echo "   backend: faster-whisper (CUDA が見えれば GPU、無ければ CPU int8 に自動で落ちる)"
    else
        echo "   backend: whisper.cpp (CPU / Apple Silicon は Metal)"
    fi
    echo ""
    echo "[WARN] DigitalBase の再起動が必須です（再起動しないと旧モデルがキャッシュされ 503 になります）"
    echo "   再起動後、管理画面 → ライセンス → 文字起こし で backend / device を確認できます (GET /api/transcribe)。"
else
    echo "[ERROR] ダウンロードに失敗しました"
    exit 1
fi
