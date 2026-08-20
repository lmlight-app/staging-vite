#!/bin/bash
# AI Server - Reranker Installer
# RAG 2段検索の再評価 (cross-encoder) server を systemd で常駐させる。
# 前提: vLLM / SGLang edition (共有 venv に vLLM が入っている)。Ollama 版は対象外。

set -e

# curl | bash 実行でも実 uid の home を確実に解決する (install-linux-vllm.sh と同じ)
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
fi

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="$INSTALL_DIR/.env"
VENV="$INSTALL_DIR/venv"
MODEL="${1:-BAAI/bge-reranker-v2-m3}"
PORT="${DB_RERANK_PORT:-8010}"
# 本体 engine と GPU を分け合うため既定は控えめ (bge-reranker-v2-m3 は 568M param ≈ 1.2GB fp16)
GPU_FRACTION="${DB_RERANK_GPU_FRACTION:-0.10}"
# 空きの多い GPU に載せる場合は DB_RERANK_GPU=1 等で指定 (未指定なら CUDA 既定 = GPU0)
RERANK_GPU="${DB_RERANK_GPU:-}"

echo "=============================================="
echo " Installing Reranker ($MODEL) on port $PORT"
echo "=============================================="

# ── 前提チェック: 共有 venv の vLLM ──
if [ ! -x "$VENV/bin/vllm" ]; then
    echo "ERROR: vLLM not found at $VENV/bin/vllm"
    echo "  Reranker installer は vLLM edition 専用です (SGLang 版は今後対応、Ollama 版は対象外)。"
    exit 1
fi

# ── モデルの事前ダウンロード (HF cache へ。失敗しても service 初回起動が再試行) ──
"$VENV/bin/python" - "$MODEL" <<'PY' || echo "WARN: pre-download failed (service will retry at start)"
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("model downloaded")
PY

# ── systemd unit (root 権限があれば system unit、なければ user unit) ──
UNIT_CONTENT="[Unit]
Description=DB Reranker (vLLM cross-encoder)
After=network.target

[Service]
Type=simple
ExecStart=$VENV/bin/vllm serve $MODEL --port $PORT \
  --gpu-memory-utilization $GPU_FRACTION
Restart=always
RestartSec=5
Environment=HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
${RERANK_GPU:+Environment=CUDA_VISIBLE_DEVICES=$RERANK_GPU}

[Install]
WantedBy=multi-user.target"

if [ "$(id -u)" = "0" ]; then
    echo "$UNIT_CONTENT" > /etc/systemd/system/db-reranker.service
    systemctl daemon-reload
    systemctl enable --now db-reranker.service
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    echo "$UNIT_CONTENT" | sudo tee /etc/systemd/system/db-reranker.service >/dev/null
    sudo sed -i "s|^User=.*||" /etc/systemd/system/db-reranker.service
    sudo sed -i "/^\[Service\]/a User=$(id -un)" /etc/systemd/system/db-reranker.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now db-reranker.service
else
    mkdir -p "$HOME/.config/systemd/user"
    echo "$UNIT_CONTENT" | sed 's/WantedBy=multi-user.target/WantedBy=default.target/' \
        > "$HOME/.config/systemd/user/db-reranker.service"
    systemctl --user daemon-reload
    systemctl --user enable --now db-reranker.service
    loginctl enable-linger "$(id -un)" 2>/dev/null || true
fi

# ── .env へ接続設定を追記 (printf 使用: echo >> は past incident のため禁止) ──
touch "$ENV_FILE"
set_env() {  # 既存キーは置換、無ければ追記
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}
set_env RERANK_ENABLED true
set_env VLLM_RERANK_BASE_URL "http://127.0.0.1:${PORT}"
set_env VLLM_RERANK_MODEL "$MODEL"

echo ""
echo "=============================================="
echo " Reranker installed."
echo "   model:   $MODEL"
echo "   url:     http://127.0.0.1:${PORT}"
echo "   service: db-reranker.service"
echo ""
echo " AI Server 本体を再起動すると .env の設定が反映されます。"
echo " (admin 画面「環境変数 (.env)」の「本体を再起動」ボタン)"
echo "=============================================="
