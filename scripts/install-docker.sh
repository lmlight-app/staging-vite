#!/bin/bash
# DigitalBase Docker installer (= docker compose の薄い wrapper。構成の正本は docker-compose.yml)
#
#   curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-docker.sh | bash
#   curl -fsSL .../install-docker.sh | GPU=1 bash           # vLLM も container で同梱 (NVIDIA GPU)
#   curl -fsSL .../install-docker.sh | APP_PORT=8080 bash   # 初回だけ .env に書く
#
# やること: Docker と compose の確認 → compose ファイルを INSTALL_DIR に置く → .env が無ければ雛形から作る → pull → up。
# 再実行 = 更新 (compose ファイルは最新に差し替え、.env と data/ postgres-data/ はそのまま)。
set -euo pipefail

INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/digitalbase}"
BASE_URL="${DB_SCRIPTS_URL:-https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts}"
GPU="${GPU:-0}"                       # 1 = docker-compose.vllm.yml を重ねる
EDITION="${EDITION:-}"                # ollama | vllm。空なら GPU=1 の時 vllm、それ以外 ollama (初回の .env にだけ効く)
APP_PORT="${APP_PORT:-}"              # 初回の .env にだけ効く

[ -z "$EDITION" ] && { [ "$GPU" = "1" ] && EDITION=vllm || EDITION=ollama; }

echo "============================================"
echo "  DigitalBase Docker Installer"
echo "============================================"
echo "  install dir : $INSTALL_DIR"
echo "  edition     : $EDITION$([ "$GPU" = "1" ] && echo ' (vLLM を container で同梱)')"
echo ""

# ── 1. preflight ──────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || {
    echo "[ERROR] Docker が install されていません: https://docs.docker.com/get-docker/"
    exit 1
}
docker info >/dev/null 2>&1 || {
    echo "[ERROR] Docker daemon が起動していません (Linux: sudo systemctl start docker / Mac・Win: Docker Desktop を起動)"
    exit 1
}
docker compose version >/dev/null 2>&1 || {
    echo "[ERROR] docker compose (v2) がありません: https://docs.docker.com/compose/install/"
    exit 1
}
COMPOSE_VER=$(docker compose version --short 2>/dev/null | sed 's/^v//')
if [ "$(printf '%s\n' "2.24.0" "$COMPOSE_VER" | sort -V | head -1)" != "2.24.0" ]; then
    echo "[WARN] docker compose $COMPOSE_VER は古い可能性があります (2.24 以降を推奨: .env が無い時の起動に必要)"
fi
if [ "$GPU" = "1" ] && ! docker info 2>/dev/null | grep -qi nvidia; then
    echo "[WARN] NVIDIA Container Toolkit が見つかりません。GPU=1 は nvidia runtime が要ります: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/"
fi

# ── 2. compose ファイル (常に最新へ差し替え) ───────────────────────────
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/postgres-data"
cd "$INSTALL_DIR"
for f in docker-compose.yml docker-compose.vllm.yml docker.env.example; do
    curl -fsSL "$BASE_URL/$f" -o "$f.tmp" || { echo "[ERROR] $f を取得できません ($BASE_URL)"; rm -f "$f.tmp"; exit 1; }
    mv "$f.tmp" "$f"
done

# ── 3. .env (初回だけ雛形から作る。既存は触らない) ──────────────────────
if [ ! -f .env ]; then
    cp docker.env.example .env
    sed -i.bak "s|^#LLM_BACKEND=.*|LLM_BACKEND=$EDITION|" .env
    [ -n "$APP_PORT" ] && sed -i.bak "s|^#APP_PORT=.*|APP_PORT=$APP_PORT|" .env
    rm -f .env.bak
    echo "[OK] .env を作成: $INSTALL_DIR/.env"
else
    echo "[INFO] 既存の .env を保持: $INSTALL_DIR/.env"
fi
PORT=$(sed -n 's/^APP_PORT=\(.*\)$/\1/p' .env | tail -1)
PORT="${PORT:-8000}"

# ── 4. 起動 (再実行なら更新) ──────────────────────────────────────────
FILES="-f docker-compose.yml"
[ "$GPU" = "1" ] && FILES="$FILES -f docker-compose.vllm.yml"
# shellcheck disable=SC2086
docker compose $FILES pull
# shellcheck disable=SC2086
docker compose $FILES up -d

echo ""
echo -n "起動待ち"
for i in $(seq 1 60); do
    if curl -fs -m 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then echo " [OK]"; break; fi
    echo -n "."; sleep 2
    [ "$i" = 60 ] && echo " (まだ応答がありません: docker compose logs -f app で確認)"
done

echo ""
echo "============================================"
echo "  [OK] DigitalBase"
echo "============================================"
echo "  URL      : http://localhost:$PORT   (admin@local / admin123)"
echo "  設定     : $INSTALL_DIR/.env"
echo "  データ   : $INSTALL_DIR/data, $INSTALL_DIR/postgres-data"
echo "  ライセンス: $INSTALL_DIR/data/license.lic に置く (または 管理画面 > ライセンス から upload)"
echo ""
echo "  操作 (cd $INSTALL_DIR):"
echo "    docker compose logs -f app   # ログ"
echo "    docker compose down          # 停止 (データは残る)"
echo "    docker compose up -d         # 起動"
echo "    更新: この installer を再実行 (= pull して up)"
[ "$GPU" = "1" ] && echo "    GPU 版は docker compose に -f docker-compose.yml -f docker-compose.vllm.yml を付ける"
echo "============================================"
