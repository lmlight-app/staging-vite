#!/bin/bash
# AI Server - Reranker Installer
#
# 使い方:
#   install-reranker.sh [HF モデル]   (既定 BAAI/bge-reranker-v2-m3)
#   install-reranker.sh --remove      (db-reranker.service を停止・削除し、RERANK_ENABLED=false に戻す)
#
# 環境変数: DB_INSTALL_DIR (本体の配置先、既定は db.service の WorkingDirectory、無ければ ~/.local/db)
#           DB_RERANK_PORT (8010), DB_RERANK_GPU_FRACTION (0.10), DB_RERANK_GPU (CUDA_VISIBLE_DEVICES)
#           DB_SERVICE_USER (unit の User=、既定は db.service の User=)
#           HF_HOME (モデルの置き場。既定は .env の HF_HOME、無ければ <db ユーザーの HOME>/.cache/huggingface)

set -e

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/root"
    export HOME
fi

show_usage() {
    echo "使い方: install-reranker.sh [HF モデル (既定 BAAI/bge-reranker-v2-m3)]"
    echo "        install-reranker.sh --remove"
    echo ""
    echo "環境変数: DB_INSTALL_DIR, DB_RERANK_PORT (8010), DB_RERANK_GPU_FRACTION (0.10), DB_RERANK_GPU, DB_SERVICE_USER, HF_HOME"
}

REMOVE=0
case "${1:-}" in
    --remove) REMOVE=1; shift; [ $# -eq 0 ] || { echo "[ERROR] --remove に引数は付けられません: $1"; exit 1; } ;;
    -h|--help) show_usage; exit 0 ;;
    -*) echo "[ERROR] 無効な引数: $1"; echo ""; show_usage; exit 1 ;;
esac
[ $# -le 1 ] || { echo "[ERROR] 引数が多すぎます: $2"; echo ""; show_usage; exit 1; }

# ── 本体 (db.service) の実行ユーザーと配置先 ──
DB_UNIT_FILE="/etc/systemd/system/db.service"
db_unit_get() { [ -f "$DB_UNIT_FILE" ] && sed -n "s/^$1=//p" "$DB_UNIT_FILE" | head -1; }

INSTALL_DIR="${DB_INSTALL_DIR:-$(db_unit_get WorkingDirectory || true)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="$INSTALL_DIR/.env"
VENV="$INSTALL_DIR/venv"
MODEL="${1:-BAAI/bge-reranker-v2-m3}"
PORT="${DB_RERANK_PORT:-8010}"
GPU_FRACTION="${DB_RERANK_GPU_FRACTION:-0.10}"
RERANK_GPU="${DB_RERANK_GPU:-}"
UNIT_NAME="db-reranker.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
USER_UNIT_PATH="$HOME/.config/systemd/user/$UNIT_NAME"

resolve_db_user() {
    local u="${DB_SERVICE_USER:-}"
    if [ -z "$u" ] && [ -f "$DB_UNIT_FILE" ]; then
        u="$(db_unit_get User || true)"
        [ -n "$u" ] || u="root"
    fi
    if [ -z "$u" ] && [ -d "$INSTALL_DIR" ]; then
        u="$(stat -c %U "$INSTALL_DIR" 2>/dev/null || true)"
    fi
    printf '%s' "${u:-$(id -un)}"
}
DB_USER="$(resolve_db_user)"
DB_HOME="$(getent passwd "$DB_USER" 2>/dev/null | cut -d: -f6)"
DB_HOME="${DB_HOME:-$HOME}"

# ── 特権: root か sudo (パスワード無し)。無ければ user unit として自分で動かす (管理画面からは操作できない) ──
HAVE_ROOT=1
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
else
    SUDO=""
    HAVE_ROOT=0
    DB_USER="$(id -un)"
    DB_HOME="$HOME"
fi

# 本体の実行ユーザーとしてコマンドを実行する (uv / HF のキャッシュを service と同じ場所に置くため)。
# 秘密 (HF_TOKEN) は引数の env K=V だと ps に見えるので、export した環境を引き継ぐ (runuser は引き継ぐ、sudo は --preserve-env)
as_db_user() {
    if [ "$(id -un)" = "$DB_USER" ]; then
        env HOME="$DB_HOME" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        runuser -u "$DB_USER" -- env HOME="$DB_HOME" "$@"
    else
        sudo -n -u "$DB_USER" ${HF_TOKEN:+--preserve-env=HF_TOKEN} env HOME="$DB_HOME" "$@"
    fi
}

# ── .env: 所有者・権限を変えないよう、既存ファイルに上書き (tee / cat >) で書く。読めなければ sudo で読む ──
env_cat() { if [ -r "$ENV_FILE" ]; then cat "$ENV_FILE"; else $SUDO cat "$ENV_FILE"; fi; }
env_write() { if [ -w "$ENV_FILE" ]; then cat > "$ENV_FILE"; else $SUDO tee "$ENV_FILE" >/dev/null; fi; }
env_get() { [ -f "$ENV_FILE" ] && env_cat | sed -n "s/^$1=//p" | tail -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
set_env() {
    local key="$1" value="$2" tmp esc
    [ -f "$ENV_FILE" ] || { echo "[WARN] $ENV_FILE がありません。.env に ${key} を書けませんでした"; return 0; }
    tmp="$(mktemp)"
    esc="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
    if env_cat | grep -q "^${key}="; then
        env_cat | sed "s|^${key}=.*|${key}=${esc}|" > "$tmp"
    else
        env_cat > "$tmp"
        # 末尾に改行が無い .env に追記すると前の行と連結するので、先に改行を補う
        [ -z "$(tail -c1 "$tmp")" ] || printf '\n' >> "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    env_write < "$tmp"
    rm -f "$tmp"
    echo ".envを更新: ${key}=${value}"
}
unset_env() {
    local key="$1" tmp
    [ -f "$ENV_FILE" ] && env_cat | grep -q "^${key}=" || return 0
    tmp="$(mktemp)"
    env_cat | sed "/^${key}=/d" > "$tmp"
    env_write < "$tmp"
    rm -f "$tmp"
    echo ".envから削除: ${key}"
}

# ── sudoers: 本体の実行ユーザーが補助サーバーの unit だけを sudo (パスワード無し) で操作できるようにする ──
# 全 unit を常に列挙するので、どのインストーラーが書いても同じ内容になる。
# systemctl は実体のパス (readlink -f) で書く (= 製品も realpath で呼ぶ。merged-usr では /usr/bin/systemctl)
SUDOERS_FILE="/etc/sudoers.d/digitalbase-units"
OLD_POLKIT_RULE="/etc/polkit-1/rules.d/50-digitalbase-units.rules"
systemctl_path() {
    local p
    p="$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)"
    readlink -f "$p" 2>/dev/null || echo "$p"
}
sudoers_content() {
    local user="$1" sc="$2" u v first=1
    echo "# DigitalBase: db.service の実行ユーザーに補助サーバーの unit の操作だけを許可する"
    printf 'Cmnd_Alias DB_AUX_UNITS = '
    for u in db-reranker.service db-media-image.service db-media-video.service db-tts.service; do
        for v in start stop restart "enable --now" "disable --now"; do
            [ "$first" -eq 1 ] || printf ', \\\n    '
            printf '%s %s %s' "$sc" "$v" "$u"
            first=0
        done
    done
    printf '\n%s ALL=(root) NOPASSWD: DB_AUX_UNITS\n' "$user"
}
install_sudoers_rule() {
    local user="$1" visudo tmp
    if $SUDO test -f "$OLD_POLKIT_RULE"; then
        $SUDO rm -f "$OLD_POLKIT_RULE"
        echo "[OK] 旧 polkit rule を削除: $OLD_POLKIT_RULE"
    fi
    if [ "$user" = "root" ]; then
        echo "[OK] 本体は root で動作しているため sudoers の設定は不要です"
        return 0
    fi
    visudo="$(command -v visudo 2>/dev/null || true)"
    [ -n "$visudo" ] || { [ -x /usr/sbin/visudo ] && visudo=/usr/sbin/visudo; }
    if ! command -v sudo >/dev/null 2>&1 || [ -z "$visudo" ]; then
        echo "[WARN] sudo が入っていません。管理画面 (モデル管理 → 補助サーバー) の停止 / 起動ボタンは使えません。"
        echo "   必要なら sudo を入れてから再実行してください (Ubuntu / Debian: apt install sudo、RHEL 系: dnf install sudo)"
        return 0
    fi
    tmp="$(mktemp)"
    sudoers_content "$user" "$(systemctl_path)" > "$tmp"
    chmod 0440 "$tmp"
    # -f 付きの visudo -c は所有者・権限を見ない (構文だけ) ので、一般ユーザーの一時ファイルでも検証できる
    if ! "$visudo" -cf "$tmp" >/dev/null; then
        rm -f "$tmp"
        echo "[WARN] sudoers の検証 (visudo -cf) に失敗したため配置しませんでした。管理画面の停止 / 起動ボタンは使えません。"
        return 0
    fi
    if $SUDO test -f "$SUDOERS_FILE" && $SUDO cmp -s "$tmp" "$SUDOERS_FILE"; then
        echo "[OK] sudoers は設定済みです ($SUDOERS_FILE)"
    else
        $SUDO test -d /etc/sudoers.d || $SUDO install -d -m 755 /etc/sudoers.d
        $SUDO install -o root -g root -m 0440 "$tmp" "$SUDOERS_FILE"
        # 全体 (sudoers + includedir) で読めることを確認。壊れていたら置いたものを外す
        if ! $SUDO "$visudo" -c >/dev/null 2>&1; then
            $SUDO rm -f "$SUDOERS_FILE"
            rm -f "$tmp"
            echo "[WARN] sudoers 全体の検証 (visudo -c) に失敗したため $SUDOERS_FILE を外しました。管理画面の停止 / 起動ボタンは使えません。"
            return 0
        fi
        echo "[OK] sudoers を配置: $SUDOERS_FILE (${user} に db-* 補助サーバーの start / stop / restart / enable / disable を許可)"
    fi
    rm -f "$tmp"
    # /etc/sudoers に @includedir が無いと置いても効かないので、実際に許可されているか見る
    if ! $SUDO sudo -l -U "$user" 2>/dev/null | grep -q "db-media-image.service"; then
        echo "[WARN] $SUDOERS_FILE が sudo に読まれていません (/etc/sudoers に '@includedir /etc/sudoers.d' が無い可能性)。"
        echo "   管理画面の停止 / 起動ボタンは使えません。"
    fi
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        [ -n "$(ss -ltnH "( sport = :$1 )" 2>/dev/null)" ]
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

if [ -n "$RERANK_GPU" ] && ! printf '%s' "$RERANK_GPU" | grep -Eq '^[0-9]+(,[0-9]+)*$'; then
    echo "[ERROR] DB_RERANK_GPU は GPU 番号で指定してください (例: DB_RERANK_GPU=1)"; exit 1
fi
if ! printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "[ERROR] DB_RERANK_PORT は 1〜65535 の数値で指定してください"; exit 1
fi

# ════════════════════════════════════════════
#  --remove
# ════════════════════════════════════════════
if [ "$REMOVE" -eq 1 ]; then
    echo "=============================================="
    echo " Reranker を削除 ($UNIT_NAME)"
    echo "=============================================="
    REMOVED=0
    if [ -f "$UNIT_PATH" ]; then
        if [ "$HAVE_ROOT" -eq 0 ]; then
            echo "[ERROR] $UNIT_PATH の削除には root 権限が必要です (sudo で再実行してください)"
            exit 1
        fi
        $SUDO systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        $SUDO rm -f "$UNIT_PATH"
        $SUDO systemctl daemon-reload
        $SUDO systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
        REMOVED=1
    fi
    if [ -f "$USER_UNIT_PATH" ]; then
        systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$USER_UNIT_PATH"
        systemctl --user daemon-reload 2>/dev/null || true
        REMOVED=1
    fi
    if [ "$REMOVED" -eq 1 ]; then
        echo "[OK] $UNIT_NAME を停止・削除しました"
    else
        echo "[OK] $UNIT_NAME は登録されていません"
    fi
    set_env RERANK_ENABLED false
    unset_env VLLM_RERANK_BASE_URL
    unset_env VLLM_RERANK_MODEL
    echo ""
    echo " AI Server 本体を再起動すると .env の設定が反映されます。"
    echo " (admin 画面「環境変数 (.env)」の「本体を再起動」ボタン)"
    exit 0
fi

echo "=============================================="
echo " Reranker をインストール"
echo "   model: $MODEL"
echo "   port:  $PORT"
echo "=============================================="

if [ ! -x "$VENV/bin/vllm" ]; then
    echo "[ERROR] vLLM が見つかりません: $VENV/bin/vllm"
    echo "   Reranker installer は vLLM edition 専用です (SGLang 版は今後対応、Ollama 版は対象外)。"
    exit 1
fi
if [ "$HAVE_ROOT" -eq 0 ] && [ -f "$UNIT_PATH" ]; then
    echo "[ERROR] $UNIT_NAME は system unit として登録済みです。入れ替えには root 権限が必要です (sudo で再実行してください)"
    exit 1
fi

HF_HOME_VAL="${HF_HOME:-$(env_get HF_HOME || true)}"
HF_HOME_VAL="${HF_HOME_VAL:-$DB_HOME/.cache/huggingface}"
HF_TOKEN="${HF_TOKEN:-$(env_get HF_TOKEN || true)}"
[ -z "$HF_TOKEN" ] || export HF_TOKEN

# ── 途中で失敗したら、止めた既存 unit を戻す ──
STOPPED_EXISTING=0
INSTALLED=0
UNIT_TMP=""
on_exit() {
    local rc=$?
    [ -z "$UNIT_TMP" ] || rm -f "$UNIT_TMP"
    if [ "$rc" -ne 0 ] && [ "$STOPPED_EXISTING" -eq 1 ] && [ "$INSTALLED" -eq 0 ]; then
        echo "[WARN] 失敗したため既存の $UNIT_NAME を起動し直します"
        $SUDO systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
    fi
}
trap on_exit EXIT

# ── 既存の同じ unit は入れ替え (ポート確認の前に止める) ──
if [ "$HAVE_ROOT" -eq 1 ] && [ -f "$UNIT_PATH" ] && $SUDO systemctl is-active --quiet "$UNIT_NAME"; then
    echo "既存の $UNIT_NAME を停止して入れ替えます"
    $SUDO systemctl stop "$UNIT_NAME"
    STOPPED_EXISTING=1
elif [ -f "$USER_UNIT_PATH" ]; then
    systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 || true
fi
if port_in_use "$PORT"; then
    echo "[ERROR] ポート $PORT は既に使われています。別のポートを DB_RERANK_PORT=... で指定してください。"
    echo "   使用中のプロセス: ss -ltnp 'sport = :$PORT'"
    exit 1
fi

# ── モデルの事前ダウンロード (service と同じユーザー・同じ HF_HOME に置く) ──
echo "モデルをダウンロード中: $MODEL (HF_HOME=$HF_HOME_VAL)"
as_db_user HF_HOME="$HF_HOME_VAL" HF_HUB_DISABLE_PROGRESS_BARS=1 "$VENV/bin/python" - "$MODEL" <<'PY' || echo "[WARN] 事前ダウンロードに失敗しました (service の起動時に再取得します)"
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("model downloaded")
PY

UNIT_CONTENT="[Unit]
Description=DB Reranker (vLLM cross-encoder)
After=network-online.target
After=db.service
Wants=network-online.target

[Service]
Type=simple
User=$DB_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV/bin/vllm serve $MODEL --host 127.0.0.1 --port $PORT --gpu-memory-utilization $GPU_FRACTION
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
Environment=\"HF_HOME=$HF_HOME_VAL\"
${RERANK_GPU:+Environment=CUDA_VISIBLE_DEVICES=$RERANK_GPU
}SyslogIdentifier=db-reranker

[Install]
WantedBy=multi-user.target"

if [ "$HAVE_ROOT" -eq 1 ]; then
    UNIT_TMP="$(mktemp)"
    printf '%s\n' "$UNIT_CONTENT" > "$UNIT_TMP"
    $SUDO install -o root -g root -m 644 "$UNIT_TMP" "$UNIT_PATH"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT_NAME" >/dev/null
    $SUDO systemctl restart "$UNIT_NAME"
    INSTALLED=1
    echo "[OK] $UNIT_NAME を登録・起動しました (ブート時は db.service の後に起動)"
    install_sudoers_rule "$DB_USER"
else
    echo "[WARN] root 権限が無いため user unit として登録します (管理画面の停止 / 起動ボタンは使えません)"
    mkdir -p "$HOME/.config/systemd/user"
    printf '%s\n' "$UNIT_CONTENT" | sed -e 's/WantedBy=multi-user.target/WantedBy=default.target/' \
        -e '/^User=/d' -e '/^After=db.service/d' \
        > "$USER_UNIT_PATH"
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME"
    loginctl enable-linger "$(id -un)" 2>/dev/null || true
    INSTALLED=1
    echo "[OK] $UNIT_NAME を user unit として登録・起動しました ($USER_UNIT_PATH)"
fi

set_env RERANK_ENABLED true
set_env VLLM_RERANK_BASE_URL "http://127.0.0.1:${PORT}"
set_env VLLM_RERANK_MODEL "$MODEL"

echo ""
echo "=============================================="
echo " Reranker をインストールしました。"
echo "   model:   $MODEL"
echo "   url:     http://127.0.0.1:${PORT}"
echo "   service: $UNIT_NAME"
echo ""
echo " AI Server 本体を再起動すると .env の設定が反映されます。"
echo " (admin 画面「環境変数 (.env)」の「本体を再起動」ボタン)"
echo " 状態は管理画面の「モデル管理 → 補助サーバー」で確認できます。"
echo "=============================================="
