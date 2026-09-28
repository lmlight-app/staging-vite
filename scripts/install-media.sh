#!/bin/bash
# DigitalBase - 画像 / 動画生成サーバー インストーラー (vLLM-Omni、Linux + systemd のみ)
#
# vLLM-Omni を uvx で起動する systemd unit (db-media-image / db-media-video) を登録する。
# 本体の venv には何も入れない (uvx が専用の環境を作る)。
#
# 使い方:
#   curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-media.sh | bash -s -- --image Tongyi-MAI/Z-Image-Turbo
#   curl -fsSL .../install-media.sh | bash -s -- --video Wan-AI/Wan2.1-T2V-1.3B-Diffusers --gpu 1
#   curl -fsSL .../install-media.sh | bash -s -- --remove image
#
# 起動オプション (FP8・CPU 退避・VAE 分割) はモデルの大きさと GPU メモリから自動で決める。
#
# 環境変数: DB_INSTALL_DIR (本体の配置先、既定は db.service の WorkingDirectory、無ければ ~/.local/db)
#           DB_SERVICE_USER (unit の User=、既定は db.service の User=)
#           HF_HOME (モデルの置き場。既定は .env の HF_HOME、無ければ <db ユーザーの HOME>/.cache/huggingface)
#           HF_TOKEN (gated モデルの取得に使う。既定は .env の HF_TOKEN)

set -e

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/root"
    export HOME
fi

show_usage() {
    cat <<'USAGE'
使用方法:
  install-media.sh --image <HF モデル> [--gpu N] [--port P] [--version X.Y.Z] [--omni-version X.Y.Z]
  install-media.sh --video <HF モデル> [--gpu N] [--port P] [--version X.Y.Z] [--omni-version X.Y.Z]
  install-media.sh --remove image|video

オプション:
  --image <model>       画像生成サーバーを入れる (db-media-image.service、既定ポート 8092)
  --video <model>       動画生成サーバーを入れる (db-media-video.service、既定ポート 8093)
  --gpu N               使う GPU 番号 (CUDA_VISIBLE_DEVICES=N)。省略時はチャットと同じ GPU 0 を共有
                        (起動オプションは、指定した GPU は搭載メモリ、共有の GPU 0 は空きメモリで決める)
  --port P              待ち受けポート (127.0.0.1 のみ)
  --version X.Y.Z       vllm / vllm-omni の版。既定は本体 venv の vllm と同じ版
  --omni-version X.Y.Z  vllm-omni の版だけを別に指定する (既定は --version と同じ)
  --remove image|video  unit を停止・削除し、.env から *_GEN_BASE_URL を消す
  --dry-run             unit / sudoers / .env の変更内容を表示するだけで何もしない (macOS でも実行可)

例:
  install-media.sh --image Tongyi-MAI/Z-Image-Turbo
  install-media.sh --video Wan-AI/Wan2.1-T2V-1.3B-Diffusers --gpu 1
  install-media.sh --remove video
USAGE
}

KIND=""
MODEL=""
GPU=""
PORT=""
VERSION=""
OMNI_VERSION=""
REMOVE=""
DRY_RUN=0

need_arg() { [ -n "${2:-}" ] || { echo "[ERROR] $1 には値が必要です"; echo ""; show_usage; exit 1; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image|--video)
            need_arg "$1" "${2:-}"
            [ -z "$KIND" ] || { echo "[ERROR] --image と --video は同時に指定できません (1 回に 1 つ)"; exit 1; }
            KIND="${1#--}"; MODEL="$2"; shift ;;
        --gpu) need_arg "$1" "${2:-}"; GPU="$2"; shift ;;
        --port) need_arg "$1" "${2:-}"; PORT="$2"; shift ;;
        --version) need_arg "$1" "${2:-}"; VERSION="$2"; shift ;;
        --omni-version) need_arg "$1" "${2:-}"; OMNI_VERSION="$2"; shift ;;
        --remove) need_arg "$1" "${2:-}"; REMOVE="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) show_usage; exit 0 ;;
        *) echo "[ERROR] 無効な引数: $1"; echo ""; show_usage; exit 1 ;;
    esac
    shift
done

if [ -n "$REMOVE" ]; then
    case "$REMOVE" in
        image|video) KIND="$REMOVE" ;;
        *) echo "[ERROR] --remove には image か video を指定してください"; exit 1 ;;
    esac
    [ -z "$MODEL" ] || { echo "[ERROR] --remove と --image / --video は同時に指定できません"; exit 1; }
elif [ -z "$KIND" ]; then
    echo "[ERROR] --image <モデル> / --video <モデル> / --remove image|video のいずれかを指定してください"
    echo ""
    show_usage
    exit 1
fi

case "$KIND" in
    image) UNIT_NAME="db-media-image.service"; DEFAULT_PORT=8092; ENV_PREFIX="IMAGE_GEN"; LABEL="画像生成" ;;
    video) UNIT_NAME="db-media-video.service"; DEFAULT_PORT=8093; ENV_PREFIX="VIDEO_GEN"; LABEL="動画生成" ;;
esac
PORT="${PORT:-$DEFAULT_PORT}"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(uname -s)" != "Linux" ]; then
        echo "[ERROR] install-media.sh は Linux (systemd) 専用です。この OS ($(uname -s)) では使えません。"
        exit 1
    fi
    if [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1; then
        echo "[ERROR] systemd が動いていません (コンテナ等)。install-media.sh は systemd unit として登録するため使えません。"
        exit 1
    fi
fi

# ── 特権: root か sudo (パスワード無し) が必要 (system unit と sudoers を置くため) ──
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
elif [ "$DRY_RUN" -eq 1 ]; then
    SUDO="sudo -n"
else
    echo "[ERROR] root 権限が必要です (system unit と sudoers を配置します)。"
    echo "   sudo が使えるユーザーで実行するか、root で実行してください。"
    exit 1
fi

# ── 本体 (db.service) の実行ユーザーと配置先 ──
DB_UNIT_FILE="/etc/systemd/system/db.service"
db_unit_get() { [ -f "$DB_UNIT_FILE" ] && sed -n "s/^$1=//p" "$DB_UNIT_FILE" | head -1; }

INSTALL_DIR="${DB_INSTALL_DIR:-$(db_unit_get WorkingDirectory || true)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/db}"
ENV_FILE="$INSTALL_DIR/.env"
VENV="$INSTALL_DIR/venv"

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

if [ -n "$GPU" ] && ! printf '%s' "$GPU" | grep -Eq '^[0-9]+(,[0-9]+)*$'; then
    echo "[ERROR] --gpu は GPU 番号で指定してください (例: --gpu 1)"; exit 1
fi
if ! printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "[ERROR] --port は 1〜65535 の数値で指定してください"; exit 1
fi

# ════════════════════════════════════════════
#  --remove
# ════════════════════════════════════════════
if [ -n "$REMOVE" ]; then
    echo "=============================================="
    echo " ${LABEL}サーバーを削除 ($UNIT_NAME)"
    echo "=============================================="
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] systemctl disable --now $UNIT_NAME"
        echo "[dry-run] rm -f $UNIT_PATH && systemctl daemon-reload"
        echo "[dry-run] .env ($ENV_FILE) から ${ENV_PREFIX}_BASE_URL を削除"
        echo "[dry-run] $SUDOERS_FILE は残す (他の補助サーバーと共用)"
        exit 0
    fi
    if [ -f "$UNIT_PATH" ]; then
        $SUDO systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        $SUDO rm -f "$UNIT_PATH"
        $SUDO systemctl daemon-reload
        $SUDO systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
        echo "[OK] $UNIT_NAME を停止・削除しました"
    else
        echo "[OK] $UNIT_NAME は登録されていません"
    fi
    unset_env "${ENV_PREFIX}_BASE_URL"
    echo ""
    echo " AI Server 本体を再起動すると .env の設定が反映されます。"
    echo " (admin 画面「環境変数 (.env)」の「本体を再起動」ボタン)"
    echo " ダウンロード済みのモデルは HF キャッシュに残っています (不要なら huggingface-cli delete-cache で削除)。"
    echo " uvx の実行環境 ($INSTALL_DIR/.cache/media-uv) は image / video で共用のため残しています。"
    exit 0
fi

# ════════════════════════════════════════════
#  install
# ════════════════════════════════════════════
echo "=============================================="
echo " ${LABEL}サーバー (vLLM-Omni) をインストール"
echo "   model: $MODEL"
echo "   port:  $PORT"
echo "=============================================="

if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] DigitalBase がインストールされていません: $INSTALL_DIR"
    echo "   先に DigitalBase をインストールしてください (別の場所なら DB_INSTALL_DIR=... で指定)"
    exit 1
fi

# ── vllm / vllm-omni の版 (vllm-omni は vllm と major.minor を揃える必要がある) ──
if [ -z "$VERSION" ]; then
    if [ -x "$VENV/bin/python" ]; then
        VERSION="$("$VENV/bin/python" -c 'from importlib.metadata import version; print(version("vllm"))' 2>/dev/null || true)"
        VERSION="${VERSION%%+*}"
    fi
    if [ -z "$VERSION" ]; then
        echo "[ERROR] 本体の venv ($VENV) に vllm が見つかりません。--version X.Y.Z で vllm / vllm-omni の版を指定してください。"
        exit 1
    fi
    case "$VERSION" in
        *dev*|*rc*)
            echo "[WARN] 本体の vllm は $VERSION (開発版) です。同じ版の vllm-omni が無い場合は --version X.Y.Z で指定してください。" ;;
    esac
    echo "[OK] vllm の版: $VERSION (本体 venv と同じ)"
fi
OMNI_VERSION="${OMNI_VERSION:-$VERSION}"

# ── uv / uvx (本体の実行ユーザーの ~/.local/bin) ──
UVX=""
for c in "$DB_HOME/.local/bin/uvx" "$HOME/.local/bin/uvx" "$(command -v uvx 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { UVX="$c"; break; }
done
if [ -z "$UVX" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        UVX="$DB_HOME/.local/bin/uvx"
    else
        echo "uv をインストール中 ($DB_USER の ~/.local/bin)..."
        curl -LsSf https://astral.sh/uv/install.sh | as_db_user env UV_NO_MODIFY_PATH=1 sh
        UVX="$DB_HOME/.local/bin/uvx"
        [ -x "$UVX" ] || { echo "[ERROR] uvx が見つかりません ($UVX)。uv のインストールに失敗しました"; exit 1; }
    fi
fi
UV="$(dirname "$UVX")/uv"

HF_HOME_VAL="${HF_HOME:-$(env_get HF_HOME || true)}"
HF_HOME_VAL="${HF_HOME_VAL:-$DB_HOME/.cache/huggingface}"
UV_CACHE="$INSTALL_DIR/.cache/media-uv"
HF_TOKEN="${HF_TOKEN:-$(env_get HF_TOKEN || true)}"
[ -z "$HF_TOKEN" ] || export HF_TOKEN

# 版を == で固定しても uvx は毎回 index に問い合わせる (ネットが無いと起動できない) ので、unit は --offline で
# 起動し、環境はこのインストーラーが同じ引数で先に作っておく (下の「事前準備」)
UVX_ARGS=(--python 3.12 --from "vllm-omni==$OMNI_VERSION" --with "vllm==$VERSION")

unit_content() {
    printf '%s\n' "[Unit]
Description=DB Media ${KIND} generation (vLLM-Omni)
After=network-online.target
After=db.service
Wants=network-online.target

[Service]
Type=simple
User=$DB_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$UVX --offline ${UVX_ARGS[*]} vllm-omni serve $MODEL --omni --host 127.0.0.1 --port $PORT${SERVE_ARGS:+ $SERVE_ARGS}
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
Environment=\"HF_HOME=$HF_HOME_VAL\"
Environment=\"UV_CACHE_DIR=$UV_CACHE\"
${GPU:+Environment=CUDA_VISIBLE_DEVICES=$GPU
}SyslogIdentifier=db-media-${KIND}

[Install]
WantedBy=multi-user.target"
}
SERVE_ARGS=""

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "[dry-run] db ユーザー: $DB_USER (HOME=$DB_HOME)、配置先: $INSTALL_DIR"
    echo "[dry-run] 事前準備: UV_CACHE_DIR=$UV_CACHE $UVX ${UVX_ARGS[*]} vllm-omni --help (その後 --offline で再確認)"
    echo "[dry-run] モデル取得: snapshot_download($MODEL) → HF_HOME=$HF_HOME_VAL${HF_TOKEN:+ (HF_TOKEN あり)}"
    echo "[dry-run] $UNIT_PATH (起動オプションは取得後にモデルの大きさと GPU メモリから自動で付く):"
    unit_content | sed 's/^/    /'
    echo "[dry-run] $SUDOERS_FILE (root:root 0440、visudo -cf で検証してから配置):"
    sudoers_content "$DB_USER" "$(systemctl_path)" | sed 's/^/    /'
    echo "[dry-run] .env: ${ENV_PREFIX}_BASE_URL=http://127.0.0.1:${PORT}/v1 (${ENV_PREFIX}_MODEL / ${ENV_PREFIX}_API は削除)"
    exit 0
fi

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
if [ -f "$UNIT_PATH" ] && $SUDO systemctl is-active --quiet "$UNIT_NAME"; then
    echo "既存の $UNIT_NAME を停止して入れ替えます"
    $SUDO systemctl stop "$UNIT_NAME"
    STOPPED_EXISTING=1
fi
if port_in_use "$PORT"; then
    echo "[ERROR] ポート $PORT は既に使われています。"
    echo "   別のポートを --port で指定してください (例: --port $((PORT + 10)))。"
    echo "   使用中のプロセス: ss -ltnp 'sport = :$PORT'"
    exit 1
fi

# ── GPU の案内 ──
GPU_COUNT=0
command -v nvidia-smi >/dev/null 2>&1 && GPU_COUNT="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)"
if [ -z "$GPU" ]; then
    echo ""
    echo "[INFO] --gpu を指定していないため、チャット (vLLM) と同じ GPU 0 を共有します。"
    echo "   GPU メモリが足りない時は、管理画面 (モデル管理 → 補助サーバー) の停止ボタンでこのサーバーを止めるとメモリが空きます。"
    if [ "${GPU_COUNT:-0}" -gt 1 ]; then
        echo "   この機械には GPU が ${GPU_COUNT} 枚あります。別の GPU を使うなら --gpu 1 などを付けて再実行してください。"
    fi
    echo ""
fi

# ── 事前準備: uvx の環境を作っておく (unit は --offline で起動するので、ここで揃えた物だけを使う) ──
# キャッシュは db ユーザー所有で作る (root の mkdir -p だと親の .cache が root 所有になる)
$SUDO install -d -o "$DB_USER" -g "$(id -gn "$DB_USER")" "$INSTALL_DIR/.cache" "$UV_CACHE"
echo "vLLM-Omni の実行環境を準備中 (vllm-omni==$OMNI_VERSION + vllm==$VERSION、初回は数 GB のダウンロード)..."
if ! as_db_user UV_CACHE_DIR="$UV_CACHE" "$UVX" "${UVX_ARGS[@]}" vllm-omni --help >/dev/null; then
    echo "[ERROR] vLLM-Omni の実行環境を作れませんでした。"
    echo "   vllm-omni==$OMNI_VERSION / vllm==$VERSION の組み合わせが PyPI にあるか確認し、"
    echo "   必要なら --version / --omni-version で版を指定してください (vllm-omni は vllm と major.minor を揃える)。"
    exit 1
fi
if ! as_db_user UV_CACHE_DIR="$UV_CACHE" "$UVX" --offline "${UVX_ARGS[@]}" vllm-omni --help >/dev/null; then
    echo "[ERROR] 作った実行環境を --offline で使えません (unit は --offline で起動します)。UV_CACHE_DIR=$UV_CACHE を確認してください。"
    exit 1
fi
echo "[OK] vLLM-Omni の実行環境 (キャッシュ: $UV_CACHE)"

# ── 置き場所の空き容量 (= 取得途中で disk full にしない) ──
REPO_BYTES="$(as_db_user HF_HOME="$HF_HOME_VAL" UV_CACHE_DIR="$UV_CACHE" "$UV" run --no-project --python 3.12 --with huggingface_hub \
    python -c 'import sys; from huggingface_hub import HfApi; print(sum(f.size or 0 for f in HfApi().model_info(sys.argv[1], files_metadata=True).siblings or []))' \
    "$MODEL" 2>/dev/null || true)"
[ -d "$HF_HOME_VAL" ] || $SUDO install -d -o "$DB_USER" -g "$(id -gn "$DB_USER")" "$HF_HOME_VAL"
FREE_BYTES="$(df -PB1 "$HF_HOME_VAL" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$REPO_BYTES" ] && [ -n "$FREE_BYTES" ] && [ "$REPO_BYTES" -gt "$FREE_BYTES" ]; then
    echo "[ERROR] モデルの置き場所の空きが足りません: 必要 $((REPO_BYTES / 1073741824)) GB / 空き $((FREE_BYTES / 1073741824)) GB ($HF_HOME_VAL)"
    echo "   不要なモデルを消すか、HF_HOME=<空きのあるディレクトリ> を付けて再実行してください。"
    exit 1
fi

# ── モデルの事前ダウンロード (全ファイル。後でオフラインでも起動できるように) ──
echo "モデルをダウンロード中: $MODEL (HF_HOME=$HF_HOME_VAL)"
if ! as_db_user HF_HOME="$HF_HOME_VAL" UV_CACHE_DIR="$UV_CACHE" HF_HUB_DISABLE_PROGRESS_BARS=1 \
        "$UV" run --no-project --python 3.12 --with huggingface_hub python - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("model downloaded")
PY
then
    echo "[ERROR] モデルのダウンロードに失敗しました: $MODEL"
    echo "   モデル名を確認してください。gated モデルは HF_TOKEN (環境変数か .env) が必要です。"
    exit 1
fi

# ── 起動オプション: 常駐する重み (読み込み時の BF16 換算) が GPU メモリに収まるかで決める ──
# 指定した GPU は搭載メモリ、共有する GPU 0 はチャットが使っている分を除いた空きメモリで見る
if [ -n "$GPU" ]; then
    GPU_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i "${GPU%%,*}" 2>/dev/null | head -1 | tr -d ' ')"
else
    GPU_MIB="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i 0 2>/dev/null | head -1 | tr -d ' ')"
fi
PLAN="$(as_db_user HF_HOME="$HF_HOME_VAL" UV_CACHE_DIR="$UV_CACHE" HF_HUB_OFFLINE=1 "$UV" run --no-project --python 3.12 --with huggingface_hub \
        python - "$MODEL" "${GPU_MIB:-0}" "$KIND" <<'PY'
import json, os, struct, sys
from huggingface_hub import snapshot_download

model, gpu_mib, kind = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
root = snapshot_download(model)
# 読み込み時の大きさ (FP32 で配られた重みは BF16 で読むので半分)
WIDTH = {"F32": 2, "F64": 4, "BF16": 2, "F16": 2, "F8_E4M3": 1, "F8_E5M2": 1, "I8": 1, "U8": 1}


def loaded_bytes(path):
    with open(path, "rb") as f:
        header = json.loads(f.read(struct.unpack("<Q", f.read(8))[0]))
    total = 0
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        count = 1
        for dim in meta["shape"]:
            count *= dim
        total += count * min(WIDTH.get(meta["dtype"], 2), 2)
    return total


parts = {}
for dirpath, _, files in os.walk(root):
    for name in files:
        if name.endswith(".safetensors"):
            top = os.path.relpath(dirpath, root).split(os.sep)[0]
            parts[top] = parts.get(top, 0) + loaded_bytes(os.path.join(dirpath, name))
resident = sum(parts.values())
dit = sum(v for k, v in parts.items() if k.startswith("transformer"))
# 生成中の作業領域を 2 割残す
budget = gpu_mib * 1024 * 1024 * 0.8
args = []
if gpu_mib and resident > budget:
    args.append("--diffusion-quantization-config '{\"method\":\"fp8\"}'")
    if resident - dit / 2 > budget:
        args.append("--enable-cpu-offload")
if kind == "video":
    args.append("--vae-use-tiling")
gib = 1024 ** 3
print(f"{resident / gib:.1f}\t{gpu_mib / 1024:.1f}\t{' '.join(args)}")
PY
)" || { echo "[ERROR] 取得したモデルを読めませんでした: $MODEL"; exit 1; }
IFS=$'\t' read -r RESIDENT_GIB GPU_GIB SERVE_ARGS <<< "${PLAN##*$'\n'}"   # 最後の行 (= 前に出る警告文を拾わない)
echo "[INFO] 重み ${RESIDENT_GIB} GB / GPU ${GPU_GIB} GB → 起動オプション: ${SERVE_ARGS:-(なし)}"

# ── systemd unit ──
UNIT_TMP="$(mktemp)"
unit_content > "$UNIT_TMP"
$SUDO install -o root -g root -m 644 "$UNIT_TMP" "$UNIT_PATH"
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$UNIT_NAME" >/dev/null
$SUDO systemctl restart "$UNIT_NAME"
INSTALLED=1
echo "[OK] $UNIT_NAME を登録・起動しました (ブート時は db.service の後に起動)"

install_sudoers_rule "$DB_USER"

# 自前サーバーは OpenAI 形で名乗るモデルを使うので、以前の cloud 向け設定 (_MODEL / _API) は外す
set_env "${ENV_PREFIX}_BASE_URL" "http://127.0.0.1:${PORT}/v1"
unset_env "${ENV_PREFIX}_MODEL"
unset_env "${ENV_PREFIX}_API"

echo ""
echo "=============================================="
echo " ${LABEL}サーバーをインストールしました。"
echo "   model:   $MODEL"
echo "   url:     http://127.0.0.1:${PORT}/v1"
echo "   service: $UNIT_NAME${GPU:+ (GPU $GPU)}"
echo "   options: ${SERVE_ARGS:-(なし)}"
echo ""
echo " モデルの読み込みに数分かかります。状態は管理画面の"
echo " 「モデル管理 → 補助サーバー」で確認できます (ログ: journalctl -u ${UNIT_NAME%.service} -f)。"
echo ""
echo " AI Server 本体を再起動すると .env の設定が反映されます。"
echo " (admin 画面「環境変数 (.env)」の「本体を再起動」ボタン)"
echo "=============================================="
