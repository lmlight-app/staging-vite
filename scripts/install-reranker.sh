#!/bin/bash
# AI Server - Reranker Installer

set -e

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
fi

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="$INSTALL_DIR/.env"
VENV="$INSTALL_DIR/venv"
MODEL="${1:-BAAI/bge-reranker-v2-m3}"
PORT="${DB_RERANK_PORT:-8010}"
GPU_FRACTION="${DB_RERANK_GPU_FRACTION:-0.10}"
RERANK_GPU="${DB_RERANK_GPU:-}"

echo "=============================================="
echo " Installing Reranker ($MODEL) on port $PORT"
echo "=============================================="

if [ ! -x "$VENV/bin/vllm" ]; then
    echo "ERROR: vLLM not found at $VENV/bin/vllm"
    echo "  Reranker installer は vLLM edition 専用です (SGLang 版は今後対応、Ollama 版は対象外)。"
    exit 1
fi

"$VENV/bin/python" - "$MODEL" <<'PY' || echo "WARN: pre-download failed (service will retry at start)"
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("model downloaded")
PY

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

touch "$ENV_FILE"
set_env() {
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
