#!/bin/bash
# DigitalBase - カスタム MCP ランタイム インストーラー (Linux / macOS)
#
# ユーザーが Python (fastmcp) で書いた MCP server を本体が別プロセスとして起動するための土台を入れる:
#   uv (Python パッケージ管理) → Python (uv 管理) → 配置先ディレクトリ → .env の設定
# server ごとの venv は本体が保存時に作るので、このスクリプトは 1 回だけ実行すればよい。
#
# 使い方:
#   curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-mcp.sh | bash
#   curl -fsSL .../install-mcp.sh | bash -s -- --python 3.13 --dir /opt/db/mcp
#
# 環境変数: DB_INSTALL_DIR (本体の配置先、既定 ~/.local/db)、MCP_PYTHON_VER (既定 3.13)
set -e

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="$INSTALL_DIR/.env"
PYTHON_VER="${MCP_PYTHON_VER:-3.13}"
MCP_DIR="$INSTALL_DIR/mcp"
PREWARM=1

while [ $# -gt 0 ]; do
    case "$1" in
        --python) PYTHON_VER="$2"; shift 2 ;;
        --dir) MCP_DIR="$2"; shift 2 ;;
        --no-prewarm) PREWARM=0; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
    esac
done

echo "=============================================="
echo " DigitalBase Custom MCP runtime installer"
echo "   install dir : $INSTALL_DIR"
echo "   mcp dir     : $MCP_DIR"
echo "   python      : $PYTHON_VER"
echo "=============================================="

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] $INSTALL_DIR が見つかりません。先に本体 (install-linux.sh / install-macos.sh) を導入してください"
    exit 1
fi

# ── uv (= vLLM / SGLang installer と同じ bootstrap) ──
if ! command -v uv &>/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh \
        || { echo "[ERROR] uv のインストールに失敗しました。閉域網なら uv を手動導入して再実行してください"; exit 1; }
fi
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv &>/dev/null; then
    echo "[ERROR] uv が PATH にありません (~/.local/bin/uv を確認)"
    exit 1
fi
echo "[OK] uv $(uv --version 2>/dev/null | awk '{print $2}')"

# ── Python (= uv 管理。system python には触らない) ──
echo "Ensuring Python $PYTHON_VER (uv managed)..."
uv python install "$PYTHON_VER" >/dev/null 2>&1 \
    || { echo "[ERROR] Python $PYTHON_VER の取得に失敗しました (閉域網なら uv python install を手動で)"; exit 1; }
echo "[OK] Python $PYTHON_VER"

# ── 配置先 ──
mkdir -p "$MCP_DIR" || { echo "[ERROR] $MCP_DIR を作成できません"; exit 1; }
[ -w "$MCP_DIR" ] || { echo "[ERROR] $MCP_DIR に書き込めません"; exit 1; }
echo "[OK] $MCP_DIR"

# ── 初回保存を速くするため fastmcp の wheel を uv cache に載せておく (任意) ──
if [ "$PREWARM" = "1" ]; then
    echo "Pre-fetching fastmcp into uv cache (optional)..."
    TMP_VENV="$MCP_DIR/.prewarm"
    rm -rf "$TMP_VENV"
    if uv venv --python "$PYTHON_VER" "$TMP_VENV" >/dev/null 2>&1 \
        && uv pip install --python "$TMP_VENV/bin/python" "fastmcp>=3.4,<4" >/dev/null 2>&1; then
        echo "[OK] fastmcp cached"
    else
        echo "[WARN] fastmcp の事前取得に失敗 (初回の登録時にダウンロードされます)"
    fi
    rm -rf "$TMP_VENV"
fi

# ── .env へ設定を追記 (printf 使用: echo >> は past incident のため禁止) ──
touch "$ENV_FILE"
set_env() {  # 既存キーは置換、無ければ追記
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    else
        [ -z "$(tail -c1 "$ENV_FILE")" ] || printf '\n' >> "$ENV_FILE"   # 末尾改行の無い .env に追記すると前の行と連結する
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}
set_env MCP_MANAGED_DIR "$MCP_DIR"
set_env MCP_MANAGED_AUTO_START true
set_env MCP_PYTHON_VERSION "$PYTHON_VER"

echo ""
echo "=============================================="
echo " Custom MCP runtime installed."
echo "   uv      : $(command -v uv)"
echo "   python  : $PYTHON_VER (uv managed)"
echo "   mcp dir : $MCP_DIR"
echo ""
echo " 次: 本体を再起動し、「データ > カスタム MCP」から server を作成してください。"
echo "=============================================="
