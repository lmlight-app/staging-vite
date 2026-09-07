#!/bin/bash
# AI Server Installer for Linux (vLLM Edition)
set -e

# HOME 未設定/不正だと $HOME/.local/... が /.local/... に化ける (更新ボタン経由 =
# systemd 環境で HOME 無しが起きる)。実 uid の home を確実に解決してから使う。
if [ -z "$HOME" ] || [ "$HOME" = "/" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/root"
    export HOME
fi

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
# 推論 venv の Python 版。検証済みの版に固定 (上書きは DB_PYTHON_VER)。
PYTHON_VER="${DB_PYTHON_VER:-3.13}"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; esac
BINARY_NAME="lmlight-vite-linux-$ARCH"

# ── 引数 / env (curl ... | bash -s -- --offline --wheelhouse DIR の形で渡す) ──
# 版は latest.json (promote.sh が engine-versions.env から焼き込む) が正。flag / env は上書き用
OFFLINE=0
WHEELHOUSE="${DB_WHEELHOUSE:-}"
VLLM_VERSION="${DB_VLLM_VERSION:-}"
UV_VERSION="${DB_UV_VERSION:-}"
TORCH_INDEX="${DB_TORCH_INDEX:-}"
# latest.json に *_version が無いときの最後の砦 (= engine-versions.env と同じ値。毎回 `uv self update` はしない)
VLLM_VERSION_DEFAULT="latest"
UV_VERSION_DEFAULT="latest"
UV_MIN_VERSION="0.12.1"   # latest 指定時、これ未満の uv は最新へ上げる (= 古い uv が新しい wheel を解決できない事故を防ぐ)
usage() {
    cat << 'USAGE'
Usage: install-linux-vllm.sh [--vllm-version X.Y.Z] [--uv-version X.Y.Z] [--torch-index URL] [--offline --wheelhouse DIR]
  --vllm-version  vLLM: latest | nightly | X.Y.Z   (default: "vllm_version" in latest.json, else latest; env DB_VLLM_VERSION)
  --uv-version    uv: latest | X.Y.Z             (default: "uv_version" in latest.json, else latest; env DB_UV_VERSION)
  --torch-index   PyTorch wheel index URL (default: "torch_index" in latest.json; empty = uv --torch-backend=auto)
  --offline       no network: binary / checksum / uv / wheels are taken from --wheelhouse DIR
  --wheelhouse    directory with the pre-staged files (env DB_WHEELHOUSE). See "Offline install" in README
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --offline) OFFLINE=1 ;;
        --wheelhouse) WHEELHOUSE="${2:?--wheelhouse requires DIR}"; shift ;;
        --vllm-version) VLLM_VERSION="${2:?--vllm-version requires latest|nightly|X.Y.Z}"; shift ;;
        --uv-version) UV_VERSION="${2:?--uv-version requires latest|X.Y.Z}"; shift ;;
        --torch-index) TORCH_INDEX="${2:?--torch-index requires URL}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

# offline に必要な事前配置物 (= 不足時はこの一覧で案内する)
offline_manifest() {
    cat << EOF

Pre-stage the following files in ${WHEELHOUSE:-<wheelhouse DIR>} (fetch on an online machine with the same arch / CUDA):
  $BINARY_NAME             backend binary      $BASE_URL/$BINARY_NAME
  $BINARY_NAME.sha256      checksum            $BASE_URL/$BINARY_NAME.sha256
  latest.json              version manifest    $BASE_URL/latest.json   (optional if --vllm-version is given)
  uv                       uv binary $UV_VERSION  https://github.com/astral-sh/uv/releases (uv-<arch>-unknown-linux-gnu.tar.gz, extract 'uv')
  *.whl                    wheels:  pip download "vllm==${VLLM_VERSION:-<version>}" --dest . [--extra-index-url <torch index>]
  hf-cache.tar             (optional) tar of ~/.cache/huggingface holding the models to serve
  python$PYTHON_VER               must already be installed on this host (uv cannot download interpreters offline)
EOF
}
if [ "$OFFLINE" -eq 1 ]; then
    if [ -z "$WHEELHOUSE" ] || [ ! -d "$WHEELHOUSE" ]; then
        echo "[ERROR] --offline requires --wheelhouse DIR (existing directory)"; offline_manifest; exit 2
    fi
    WHEELHOUSE="$(cd "$WHEELHOUSE" && pwd -P)"
    export UV_OFFLINE=1 UV_NO_PROGRESS=1
fi

echo " Installing AI Server vLLM Edition ($ARCH) to $INSTALL_DIR"

# ── Privilege helper: support root-without-sudo (minimal GPU containers) ──
# 最小 CUDA コンテナは root 直 + sudo 未インストールが普通。
# sudo を無条件に前提にすると apt / postgres bootstrap / symlink が黙って失敗する
# (2>/dev/null || true で握り潰される) ので、root か sudo かを判定して分岐する。
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""                       # already root: no sudo needed
elif command -v sudo &>/dev/null; then
    SUDO="sudo"
else
    SUDO=""
    echo "[WARN] root でも sudo でもありません。特権操作 (apt / postgres / symlink) が失敗する可能性があります。"
fi
# 非対話実行 (TTY 無し = self-update 等) では sudo に password prompt させない (-n)。
# 必要な特権操作は下の各所で「導入済みなら skip」してから呼ぶので、PAM ログも汚れない。
[ -t 0 ] || { [ -n "$SUDO" ] && SUDO="sudo -n"; }

# Run psql as the postgres superuser. Handles: non-root+sudo, root w/o sudo (su), fallback.
pg_admin() {
    if [ -n "$SUDO" ]; then
        $SUDO -u postgres psql "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        su postgres -c "psql $(printf '%q ' "$@")"
    else
        psql "$@"
    fi
}

mkdir -p "$INSTALL_DIR"

# 更新手順の記録 (= admin の update/status が末尾を表示する。日時は UTC)
UPDATE_LOG="$INSTALL_DIR/update.log"
log() { echo "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$UPDATE_LOG"; }

# 公開 .sha256 (release.yml が sha256sum 形式で生成し promote.sh が同居させる) と照合。
# 不一致は中断 (= 改竄/途中欠損 binary を稼働させない)。取得不能は警告して続行 (= checksum の配布漏れで導入を止めない。DB_SKIP_SHA256=1 は検証自体を省略)
verify_sha256() {
    local file="$1" src="$2" expected="" actual=""
    if [ "${DB_SKIP_SHA256:-0}" = "1" ]; then log "[WARN] sha256 verification skipped (DB_SKIP_SHA256=1)"; return 0; fi
    if [ -f "$src" ]; then
        expected="$(awk '{print $1}' "$src")"
    else
        expected="$(curl -fsSL --retry 3 --retry-delay 5 "$src" 2>/dev/null | awk '{print $1}')"
    fi
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    if ! printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
        log "[WARN] checksum unavailable ($src), continuing without sha256 verification"; return 0
    fi
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
        rm -f "$file"; log "[ERROR] sha256 mismatch for $(basename "$src" .sha256): expected $expected, got $actual"; exit 1
    fi
    log "[OK] sha256 verified: $actual"
}

# 旧 binary を api.prev に残してから差し替える (= db rollback で戻せる)。hard link なので容量も時間もゼロ
install_binary() {
    chmod +x "$INSTALL_DIR/api.new"
    if [ -f "$INSTALL_DIR/api" ]; then
        rm -f "$INSTALL_DIR/api.prev"
        ln -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev" 2>/dev/null || cp -f "$INSTALL_DIR/api" "$INSTALL_DIR/api.prev"
    fi
    mv -f "$INSTALL_DIR/api.new" "$INSTALL_DIR/api"
    log "[OK] binary installed (previous kept as api.prev for 'db rollback')"
}


# ── 版マニフェスト latest.json → 版指定を解決 (latest | nightly | X.Y.Z。無ければ同梱既定 latest) ──
if [ "$OFFLINE" -eq 1 ]; then
    MANIFEST_FILE="$WHEELHOUSE/latest.json"
else
    MANIFEST_FILE="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 5 "$BASE_URL/latest.json" -o "$MANIFEST_FILE" 2>/dev/null \
        || log "[WARN] Could not fetch $BASE_URL/latest.json"
fi
manifest_get() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$MANIFEST_FILE" 2>/dev/null | head -1; }
[ -n "$VLLM_VERSION" ] || VLLM_VERSION="$(manifest_get vllm_version)"
[ -n "$UV_VERSION" ] || UV_VERSION="$(manifest_get uv_version)"
[ -n "$TORCH_INDEX" ] || TORCH_INDEX="$(manifest_get torch_index)"
if [ -z "$UV_VERSION" ]; then
    log "[WARN] latest.json has no \"uv_version\"; using bundled default uv $UV_VERSION_DEFAULT"
    UV_VERSION="$UV_VERSION_DEFAULT"
fi
if [ -z "$VLLM_VERSION" ]; then
    log "[WARN] latest.json has no \"vllm_version\"; using bundled default vLLM $VLLM_VERSION_DEFAULT (override: --vllm-version latest|nightly|X.Y.Z)"
    VLLM_VERSION="$VLLM_VERSION_DEFAULT"
fi
log "[UPDATE] target: app $(manifest_get version), vLLM $VLLM_VERSION, uv $UV_VERSION, torch index ${TORCH_INDEX:-auto}"

# 更新時: 稼働中の旧プロセスを止める (systemd unit → 従来 stop.sh の順。binary 上書きの text busy 防止)
# DB_NO_SERVICE=1 (= run.sh 経由の self-update、unit の内側で実行中) では unit を触らない (自壊防止)
WAS_ACTIVE=0
if [ -z "$DB_NO_SERVICE" ]; then
    { systemctl is-active --quiet db 2>/dev/null || systemctl is-active --quiet digitalbase 2>/dev/null; } && WAS_ACTIVE=1
    command -v systemctl &>/dev/null && $SUDO systemctl stop db digitalbase 2>/dev/null || true
    [ -f "$INSTALL_DIR/stop.sh" ] && "$INSTALL_DIR/stop.sh" 2>/dev/null || true
fi
# 停止確認: 同 dir 起動の api が残っていれば中断 (稼働 binary への上書きは破損リスク)
if [ -d "$INSTALL_DIR" ]; then
    _RP="$(cd "$INSTALL_DIR" && pwd -P)"
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$_RP/api" 2>/dev/null); do
        if [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$_RP" ]; then
            echo "[ERROR] 稼働中のプロセスを停止できませんでした。先に停止してから再実行してください:"
            echo "   sudo systemctl stop db   (または $INSTALL_DIR/stop.sh)"
            exit 1
        fi
    done
fi

# Download unified backend binary (= api/ 統一、LLM_BACKEND=vllm で vllm mode)
echo " Downloading AI Server backend..."

BINARY_URL="$BASE_URL/$BINARY_NAME"

# 一時ファイルへ DL (offline は wheelhouse から copy) → sha256 検証 → 旧 binary を api.prev に退避 → mv
# (= 失敗・中断時に稼働 binary を壊さない)
if [ "$OFFLINE" -eq 1 ]; then
    log "[UPDATE] start (offline): $WHEELHOUSE/$BINARY_NAME"
    [ -f "$WHEELHOUSE/$BINARY_NAME" ] || { log "[ERROR] $BINARY_NAME not found in $WHEELHOUSE"; offline_manifest; exit 1; }
    cp -f "$WHEELHOUSE/$BINARY_NAME" "$INSTALL_DIR/api.new"
    SHA_SRC="$WHEELHOUSE/$BINARY_NAME.sha256"
else
    log "[UPDATE] start: $BINARY_URL"
    curl -fL --connect-timeout 30 --max-time 0 --retry 3 --retry-delay 5 \
        "$BINARY_URL" -o "$INSTALL_DIR/api.new" || true
    SHA_SRC="$BINARY_URL.sha256"
fi
if [ ! -s "$INSTALL_DIR/api.new" ] || ! head -c 4 "$INSTALL_DIR/api.new" | grep -q $'\x7fELF'; then
    rm -f "$INSTALL_DIR/api.new"
    log "[ERROR] Failed to download backend: $BINARY_URL"
    exit 1
fi
verify_sha256 "$INSTALL_DIR/api.new" "$SHA_SRC"
install_binary

# Python venv for vLLM (separate from PyInstaller binary。文字起こしは binary 同梱の pywhispercpp で、venv の whisper は読まれない)
echo "Setting up Python environment for vLLM..."

# uv: latest (既定) = 無ければ最新を入れ、居れば最低版 UV_MIN_VERSION 未満のときだけ最新へ上げる (= 毎回 self update はしない、
# 新しい uv を入れている環境を巻き戻さない)。X.Y.Z = その版に固定 (違えば入れ替え)
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
UV_HAVE="$(uv --version 2>/dev/null | awk '{print $2}' || true)"
uv_too_old() { [ -z "$UV_HAVE" ] || { [ "$(printf '%s\n%s\n' "$UV_MIN_VERSION" "$UV_HAVE" | sort -V | head -1)" = "$UV_HAVE" ] && [ "$UV_HAVE" != "$UV_MIN_VERSION" ]; }; }
if [ "$UV_VERSION" = "latest" ] && ! uv_too_old; then
    log "[OK] uv $UV_HAVE"
elif [ "$UV_VERSION" = "latest" ] && [ "$OFFLINE" -eq 0 ]; then
    log "Installing uv latest (found: ${UV_HAVE:-none}, minimum $UV_MIN_VERSION)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    hash -r
    log "[OK] uv $(uv --version 2>/dev/null | awk '{print $2}')"
elif [ "$UV_VERSION" != "latest" ] && [ "$UV_HAVE" = "$UV_VERSION" ]; then
    log "[OK] uv $UV_VERSION"
elif [ "$OFFLINE" -eq 1 ]; then
    [ -f "$WHEELHOUSE/uv" ] || { log "[ERROR] uv binary not found in $WHEELHOUSE"; offline_manifest; exit 1; }
    mkdir -p "$HOME/.local/bin" && install -m 755 "$WHEELHOUSE/uv" "$HOME/.local/bin/uv"
    hash -r
    log "[OK] uv $(uv --version 2>/dev/null | awk '{print $2}') (from wheelhouse)"
else
    log "Installing uv $UV_VERSION (found: ${UV_HAVE:-none})..."
    curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | sh
    hash -r
    UV_HAVE="$(uv --version 2>/dev/null | awk '{print $2}' || true)"
    [ "$UV_HAVE" = "$UV_VERSION" ] || log "[WARN] uv on PATH is ${UV_HAVE:-none} (expected $UV_VERSION)"
fi

# Build/runtime deps: python3-dev (native ext builds), ffmpeg (Whisper),
# tesseract-ocr (image/PDF OCR), ninja-build (FlashInfer JIT compile — prebuilt
# kernel の無い新 GPU アーキで vLLM 起動時に必須). Non-fatal — minimal containers
# may need manual install (see README); we warn instead of aborting so the rest can proceed.
# 全 deps 導入済みなら package manager を呼ばない (= 更新時は sudo 不要で静かに素通り)
DEPS_PRESENT=1
command -v ffmpeg >/dev/null 2>&1 || DEPS_PRESENT=0
command -v tesseract >/dev/null 2>&1 || DEPS_PRESENT=0
command -v ninja >/dev/null 2>&1 || DEPS_PRESENT=0
if command -v dpkg >/dev/null 2>&1; then
    dpkg -s python3-dev >/dev/null 2>&1 || DEPS_PRESENT=0
elif command -v rpm >/dev/null 2>&1; then
    rpm -q python3-devel >/dev/null 2>&1 || DEPS_PRESENT=0
fi
DEPS_OK=1
if [ "$DEPS_PRESENT" -eq 1 ]; then
    :  # already installed — skip privileged install entirely
elif [ "$OFFLINE" -eq 1 ]; then
    DEPS_OK=0  # offline では package manager を呼ばない (= 事前に OS package を入れておく)
elif command -v apt-get &>/dev/null; then
    $SUDO apt-get update -qq || DEPS_OK=0
    $SUDO apt-get install -y -qq python3-dev ffmpeg tesseract-ocr ninja-build || DEPS_OK=0
elif command -v dnf &>/dev/null; then
    $SUDO dnf install -y python3-devel ffmpeg tesseract ninja-build || DEPS_OK=0
elif command -v yum &>/dev/null; then
    $SUDO yum install -y python3-devel ffmpeg tesseract ninja-build || DEPS_OK=0
else
    DEPS_OK=0
fi
[ "$DEPS_OK" -eq 1 ] || echo "[WARN] 一部の system 依存 (python3-dev / ffmpeg / tesseract-ocr / ninja-build) を入れられませんでした。機能が失敗する場合は README を参照し手動導入してください。"

# ── Python venv は不変 (immutable): 毎回 venv.new を空から作って install し、検証が通ったら venv と入れ替える。
# 旧 venv は venv.prev に残し `db rollback` で binary と一緒に戻せる。長生き venv への上書き更新はしない
# (= 「版は満たすが CUDA build が違う」残骸が構造的に出ない)。wheel は uv cache に残すので 2 回目以降は速い ──
VENV="$INSTALL_DIR/venv"; VENV_NEW="$INSTALL_DIR/venv.new"; VENV_PREV="$INSTALL_DIR/venv.prev"
rm -rf "$VENV_NEW"
# offline では interpreter を download できないので system の python$PYTHON_VER 必須 (--no-python-downloads で明示的に落とす)
VENV_ARGS=(--python "$PYTHON_VER")
[ "$OFFLINE" -eq 1 ] && VENV_ARGS+=(--no-python-downloads)
# 古い uv が python$PYTHON_VER を取れない (= 配布一覧に無い) ときは uv を最新へ上げて 1 回だけやり直す (online のみ)
if ! uv venv "${VENV_ARGS[@]}" "$VENV_NEW"; then
    [ "$OFFLINE" -eq 0 ] || { log "[ERROR] Could not create venv with python$PYTHON_VER (offline: install it on this host)"; exit 1; }
    log "[WARN] uv $(uv --version 2>/dev/null | awk '{print $2}') could not set up python$PYTHON_VER. Upgrading uv to latest and retrying..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    hash -r
    rm -rf "$VENV_NEW"
    uv venv "${VENV_ARGS[@]}" "$VENV_NEW" || { log "[ERROR] Could not create venv with python$PYTHON_VER"; exit 1; }
fi
echo "vllm" > "$VENV_NEW/.db-edition"
echo "$VLLM_VERSION" > "$VENV_NEW/.db-engine-spec"

# vLLM: latest.json の vllm_version (latest | nightly | X.Y.Z) に従って install する。既定 latest。
# torch index は torch_index があれば --extra-index-url、無ければ uv の --torch-backend=auto (CUDA ドライバ版から自動選択)。
# offline は wheelhouse の wheel だけで解決する (--no-index)。空の venv に入れるので torch 一族は常に同じ解決で揃う
PIP_ARGS=(--python "$VENV_NEW/bin/python")
if [ "$OFFLINE" -eq 1 ]; then
    PIP_ARGS+=(--no-index --find-links "$WHEELHOUSE")
elif [ -n "$TORCH_INDEX" ]; then
    PIP_ARGS+=(--extra-index-url "$TORCH_INDEX")
else
    PIP_ARGS+=(--torch-backend=auto)
fi
install_engine() {
    case "$VLLM_VERSION" in
        latest)  uv pip install -U "${PIP_ARGS[@]}" "vllm" ;;
        nightly) uv pip install -U --prerelease=allow --index-strategy unsafe-best-match "${PIP_ARGS[@]}" \
                     --extra-index-url https://wheels.vllm.ai/nightly "vllm" ;;
        *)       uv pip install "${PIP_ARGS[@]}" "vllm==$VLLM_VERSION" ;;
    esac
}
# 失敗したら venv.new を捨てて終了 (= 稼働中の venv には触らない)
venv_fail() { log "[ERROR] $1 (existing venv left untouched)"; rm -rf "$VENV_NEW"; exit 1; }
log "Installing vLLM $VLLM_VERSION..."
install_engine || venv_fail "vLLM install failed"

# torchaudio は transformers が import 時に読むが、当製品では音声入力モデル以外に不要。torch と CUDA build が合わない wheel
# しか取れなかった (= index に同 build が無い) ときは外して先へ進む (エンジンは動く、音声入力モデルだけ使えない)
if ! "$VENV_NEW/bin/python" -c "import torchaudio" >/dev/null 2>&1; then
    log "[WARN] torchaudio is unusable (CUDA build mismatch with torch); removing it. Audio-input models will not be available."
    uv pip uninstall --python "$VENV_NEW/bin/python" torchaudio >/dev/null 2>&1 || true
fi
# 検証: import と、固定版なら版一致
"$VENV_NEW/bin/python" -c "import vllm" >/dev/null 2>&1 || venv_fail "vllm is not importable after install"
VLLM_INSTALLED="$("$VENV_NEW/bin/python" -c "import importlib.metadata as m; print(m.version('vllm'))" 2>/dev/null || true)"
case "$VLLM_VERSION" in
    latest|nightly) ;;
    *) [ "$VLLM_INSTALLED" = "$VLLM_VERSION" ] || venv_fail "vLLM $VLLM_INSTALLED is installed, expected $VLLM_VERSION" ;;
esac
log "[OK] vLLM $VLLM_INSTALLED"

# 入れ替え: venv → venv.prev、venv.new → venv (稼働中プロセスは先に止めてある)
rm -rf "$VENV_PREV"
[ -d "$VENV" ] && mv "$VENV" "$VENV_PREV"
mv "$VENV_NEW" "$VENV"
log "[OK] venv swapped (previous kept as venv.prev for 'db rollback')"

# offline: 事前に固めたモデルキャッシュがあれば展開 (= 初回起動の HuggingFace download を不要にする)
if [ "$OFFLINE" -eq 1 ] && [ -f "$WHEELHOUSE/hf-cache.tar" ]; then
    HF_DIR="${HF_HOME:-$HOME/.cache/huggingface}"
    mkdir -p "$HF_DIR" && tar -xf "$WHEELHOUSE/hf-cache.tar" -C "$HF_DIR"
    log "[OK] model cache extracted to $HF_DIR"
fi

# wheel cache は次回の venv 再構築で使うので残す。参照されなくなった分だけ掃除 (モデルの HF cache は runtime が読むので触らない)
uv cache prune >/dev/null 2>&1 || true

echo "[OK] Python venv ready"

# Vite Edition: frontend is embedded in the API binary, no app.tar.gz needed

# DB 接続情報は env で上書き可 (DB_USER/DB_PASS/DB_NAME)、既定 digitalbase。
# 既存 .env がある場合は下の Database setup でその DATABASE_URL を正とする。
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

# config の既定値でカバーされる項目は書かない (= .env は既定と異なるものだけ。行が消えても
# 既定値で復帰でき、設定の正が config.py に一本化される)。path 系は install dir 依存なので残す。
# 既存 .env の backend が本 edition と違うままだと起動しないため、検出して警告する
# (installer は .env を書き換えない方針)。
if [ -f "$INSTALL_DIR/.env" ]; then
    CURRENT_BACKEND=$(grep -E "^LLM_BACKEND=" "$INSTALL_DIR/.env" | tail -1 | cut -d= -f2)
    if [ -n "$CURRENT_BACKEND" ] && [ "$CURRENT_BACKEND" != "vllm" ]; then
        echo ""
        echo "[WARN] .env は LLM_BACKEND=$CURRENT_BACKEND のままです。この edition を使うには:"
        echo "       $INSTALL_DIR/.env の LLM_BACKEND を vllm に変更して db restart してください"
        echo ""
    fi
fi
[ ! -f "$INSTALL_DIR/.env" ] && cat > "$INSTALL_DIR/.env" << EOF
LLM_BACKEND=vllm
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
JWT_SECRET=$(openssl rand -hex 32)
VLLM_AUTO_START=true
VLLM_EMBED_MODEL=Qwen/Qwen3-Embedding-0.6B
VLLM_GPU_MEMORY_UTILIZATION_CHAT=0.70
VLLM_GPU_MEMORY_UTILIZATION_EMBED=0.10
WHISPER_MODEL=base
LICENSE_FILE_PATH=$INSTALL_DIR/license.lic
FILES_DIR=$INSTALL_DIR/files
EOF

# Database setup - parse DATABASE_URL from .env if it exists (for updates with custom DB config)
if [ -f "$INSTALL_DIR/.env" ]; then
    _DB_URL=$(grep -E "^DATABASE_URL=" "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)
    if [ -n "$_DB_URL" ]; then
        export DB_USER=$(echo "$_DB_URL" | sed -n 's|.*://\([^:]*\):.*|\1|p')
        export DB_PASS=$(echo "$_DB_URL" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
        export DB_NAME=$(echo "$_DB_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')
    fi
fi
# ── DB bootstrap (= superuser でしかできない 3 つだけ。schema / table / index /
# column 追加 / 初期 admin user は backend 起動時の migrations.py が冪等に作成) ──
echo "Setting up database..."
DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

if ! command -v psql &>/dev/null; then
    echo "[ERROR] PostgreSQL がインストールされていません (pgvector 対応版・16 以降)。README 参照:"
    echo "   apt install -y postgresql postgresql-\$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)-pgvector"
    exit 1
fi
# 未起動なら自動起動を試みる (systemd 無しコンテナは pg_ctlcluster、それ以外は systemctl)
if ! pg_isready -q 2>/dev/null; then
    if command -v pg_ctlcluster &>/dev/null; then
        PGVER=$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1)
        [ -n "$PGVER" ] && $SUDO pg_ctlcluster "$PGVER" main start 2>/dev/null || true
    elif command -v systemctl &>/dev/null; then
        $SUDO systemctl start postgresql 2>/dev/null || true
    fi
fi
if ! pg_isready -q 2>/dev/null; then
    echo "[ERROR] PostgreSQL に接続できません (localhost:5432)。手動起動してください:"
    echo "   pg_ctlcluster <ver> main start   # systemd 無しコンテナ"
    echo "   systemctl start postgresql       # systemd 環境"
    exit 1
fi

# 既に app 資格情報で接続でき pgvector も有効なら bootstrap 全体を skip
# (= 更新時は pg_admin/sudo を一切呼ばず PAM ログを汚さない)
if [ "$(PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null)" = "1" ]; then
    echo "[OK] Database already configured; setup skipped"
else
    # role (冪等)
    if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
        pg_admin -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "[WARN] CREATE USER $DB_USER に失敗"
    fi
    # database (冪等)
    if [ -z "$(pg_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
        pg_admin -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "[WARN] CREATE DATABASE $DB_NAME に失敗"
    fi
    pg_admin -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
    if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
        echo "[WARN] pgvector 拡張の有効化に失敗しました。RAG 機能を使う場合は:"
        echo "   apt install -y postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector"
    fi
    echo "[OK] Database setup complete (schemas and tables are created automatically on first startup)"
fi

# 正準起動 (= systemd ExecStart と start.sh の共用。env 読込 + 前処理 + exec api)
cat > "$INSTALL_DIR/run.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# アップデート要求 marker (= 管理画面の更新ボタン。api が marker を置いて self-exit し、
# systemd の Restart=always でここに再入する。unit 操作権限が不要な self-update)
# 進行中 .update-running / 結果 .update-result / 手順 update.log は admin の update/status が読む。
# installer は旧 binary を api.prev に残すので、失敗・起動不能時は `db rollback` で戻す
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
if [ -f .update-running ] && [ ! -f .update-requested ]; then
    # 前回の installer が途中で落ちた (= systemd stop / 電源断)。結果だけ残して通常起動へ
    echo "$(_ts) [UPDATE] previous update was interrupted" >> update.log
    printf 'result=interrupted\nexit_code=\nfinished_at=%s\n' "$(_ts)" > .update-result
    rm -f .update-running
fi
if [ -f .update-requested ]; then
    UPDATE_URL=$(head -1 .update-requested)
    # 2 行目 (任意) = 推論エンジンの版指定 (latest | nightly | X.Y.Z)。admin > モデル管理 の「版を変更」が書く
    ENGINE_SPEC=$(sed -n 2p .update-requested)
    rm -f .update-requested
    touch .update-running
    # installer に自分の設置 dir を教える (= $HOME/.local/db 以外の設置でも同じ dir を更新する)
    DB_INSTALL_DIR="$(pwd -P)"; export DB_INSTALL_DIR
    if [ -n "$ENGINE_SPEC" ]; then DB_VLLM_VERSION="$ENGINE_SPEC"; DB_SGLANG_VERSION="$ENGINE_SPEC"; export DB_VLLM_VERSION DB_SGLANG_VERSION; fi
    echo "$(_ts) [UPDATE] running installer: $UPDATE_URL" >> update.log
    echo "[UPDATE] running installer: $UPDATE_URL"
    RC=1
    if curl -fsSL "$UPDATE_URL" -o .update-installer.sh; then
        # installer 自身が手順を update.log に書くので、生ログは別ファイルに取り失敗時だけ末尾を寄せる
        if DB_NO_SERVICE=1 bash .update-installer.sh > .update-installer.out 2>&1; then RC=0; else RC=$?; fi
        if [ "$RC" -ne 0 ]; then
            echo "[UPDATE] installer failed (rc=$RC, see update.log)"
            tail -n 40 .update-installer.out >> update.log
        fi
    else
        echo "$(_ts) [UPDATE] installer download failed: $UPDATE_URL" >> update.log
        echo "[UPDATE] installer download failed: $UPDATE_URL"
    fi
    if [ "$RC" -eq 0 ]; then
        echo "$(_ts) [UPDATE] result: ok" >> update.log
        printf 'result=ok\nexit_code=0\nfinished_at=%s\n' "$(_ts)" > .update-result
    else
        echo "$(_ts) [UPDATE] result: failed (rc=$RC). Previous binary is api.prev: db rollback" >> update.log
        printf 'result=failed\nexit_code=%s\nfinished_at=%s\n' "$RC" "$(_ts)" > .update-result
    fi
    rm -f .update-installer.sh .update-running
fi

# CUDA 13+: Triton bundled ptxas is CUDA 12, need system ptxas
CUDA_MAJOR=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K\d+' || true)
[ "${CUDA_MAJOR:-0}" -ge 13 ] && [ -f /usr/local/cuda/bin/ptxas ] && export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas

# PyInstaller 親プロセス由来の変数を除去 (= 再起動で spawn された新プロセスが
# 旧プロセスの一時展開 dir を再利用して即死するのを防ぐ)
unset _MEIPASS2 _PYI_ARCHIVE_FILE _PYI_PARENT_PROCESS_LEVEL _PYI_APPLICATION_HOME_DIR

exec ./api
EOF
chmod +x "$INSTALL_DIR/run.sh"

cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && source .env; set +a

# systemd 管理中は二重起動しない (= unit 経由に誘導)
if systemctl is-active --quiet db 2>/dev/null; then
    echo "db.service が稼働中です。操作は: db {start|stop|restart|status|logs}"
    exit 1
fi

# Check dependencies

pg_isready -q 2>/dev/null || { echo "[ERROR] PostgreSQL not running"; exit 1; }

# Check NVIDIA GPU (vLLM requires CUDA)
if ! command -v nvidia-smi &>/dev/null; then
    echo "[WARN] nvidia-smi not found. vLLM requires NVIDIA GPU with CUDA."
fi

# Stop existing (= pidfile 優先、fallback は同 dir 起動の api のみ = 他 install を巻き添えにしない)
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
# 旧プロセスの完全終了を待つ (graceful shutdown 中に起動すると bind 失敗で新プロセスが死ぬ)
for _ in $(seq 1 30); do
    ALIVE=0
    for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
        [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && ALIVE=1
    done
    [ "$ALIVE" -eq 0 ] && break
    sleep 1
done

echo "Starting AI Server (vLLM Edition)..."

# Single process: API + Web frontend (run.sh は exec するので PID = api 本体)
./run.sh &
API_PID=$!
echo "$API_PID" > api.pid

echo "[OK] Started - http://localhost:${API_PORT:-8000}"

# Show LAN IP
LAN_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
[ -n "$LAN_IP" ] && echo "LAN: http://$LAN_IP:${API_PORT:-8000}"

# Show mDNS hostname if Avahi is running
if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    echo "mDNS: http://$(hostname).local:${API_PORT:-8000}"
fi

# vLLM 起動状態は Python (api 側) が single source of truth で log 出力する
# shell では予言せず、URL だけ案内
echo ""
echo "vLLM endpoints: chat=${VLLM_BASE_URL:-http://localhost:8080}, embed=${VLLM_EMBED_BASE_URL:-http://localhost:8081}"

echo ""
echo "Press Ctrl+C to stop"

trap "kill $API_PID 2>/dev/null; rm -f api.pid; echo 'Stopped'" EXIT
wait
EOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
# systemd 管理中は unit を止める (止められなければ偽の Stopped を出さない)
if systemctl is-active --quiet db 2>/dev/null; then
    SCTL="systemctl"; [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && SCTL="sudo -n systemctl"
    $SCTL stop db && { echo "Stopped (systemd)"; exit 0; }
    echo "Failed to stop db.service (root required): sudo systemctl stop db"; exit 1
fi
# Kill start.sh first (which will trigger its trap to kill API/Web)
pkill -f "db/start\.sh" 2>/dev/null
sleep 1
# Clean up any remaining processes (= pidfile 優先、fallback は同 dir 起動の api のみ)
[ -f api.pid ] && kill "$(cat api.pid)" 2>/dev/null && rm -f api.pid
HERE="$(pwd -P)"
for p in $(pgrep -fx "./api" 2>/dev/null; pgrep -fx "$HERE/api" 2>/dev/null); do
    [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && kill "$p" 2>/dev/null
done
echo "Stopped"
EOF
chmod +x "$INSTALL_DIR/stop.sh"

# ── systemd unit (サーバ標準: ブート自動起動 + クラッシュ自動復帰 + 確実な再起動) ──
SYSTEMD_OK=0
# DB_NO_SERVICE=1 (= self-update) では unit 再登録も skip (既存 unit のまま run.sh が exec ./api する)
if [ -z "$DB_NO_SERVICE" ] && [ -d /run/systemd/system ] && command -v systemctl &>/dev/null && { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; }; then
    UNIT_TMP=$(mktemp)
    cat > "$UNIT_TMP" << UNIT
[Unit]
Description=DigitalBase AI Server
After=network-online.target postgresql.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/run.sh
Restart=always
RestartSec=5
# vLLM/SGLang を chat/embed/vision 分 SIGTERM→SIGKILL する時間 (= 途中で SIGKILL されると GPU が孤児化)。
# pkg/db.service と同値。systemd は行末コメント非対応なので値と同じ行に書かない
TimeoutStopSec=180
LimitNOFILE=65535
SyslogIdentifier=db

[Install]
WantedBy=multi-user.target
UNIT
    if $SUDO install -o root -g root -m 644 "$UNIT_TMP" /etc/systemd/system/db.service \
        && $SUDO systemctl daemon-reload; then
        rm -f "$UNIT_TMP"
        $SUDO systemctl enable db >/dev/null 2>&1 || true
        $SUDO systemctl disable digitalbase >/dev/null 2>&1 || true  # 旧unitのboot起動を止める(二重bind防止)
        SYSTEMD_OK=1
        echo "[OK] systemd unit 登録 (db.service = ブート自動起動 + クラッシュ自動復帰)"
    else
        rm -f "$UNIT_TMP"
        echo "[WARN] systemd unit の登録に失敗しました (従来の start.sh 起動で動作します)"
    fi
fi

# Create db CLI script (= systemd unit があれば systemctl 管理、無ければ従来 script)
# 設置先は install 時に焼き込む (= $HOME 依存だと sudo / systemd 経由で別 dir を見る)
cat > "$INSTALL_DIR/db" << EOF
#!/bin/bash
DB_HOME="\${DB_HOME:-$INSTALL_DIR}"
EOF
cat >> "$INSTALL_DIR/db" << 'EOF'
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# 直前の binary (api.prev) と venv (venv.prev、どちらも installer が更新時に退避) と入れ替える。もう一度実行すると元に戻る。
# update.log / .update-result にも記録 (= admin の update/status に出る)
rollback_binary() {
    if [ ! -f "$DB_HOME/api.prev" ]; then
        echo "[ERROR] No previous binary to roll back to ($DB_HOME/api.prev not found)"; return 1
    fi
    mv -f "$DB_HOME/api" "$DB_HOME/api.rollback" \
        && mv -f "$DB_HOME/api.prev" "$DB_HOME/api" \
        && mv -f "$DB_HOME/api.rollback" "$DB_HOME/api.prev" || return 1
    # venv も一緒に戻す (installer が venv.prev に退避)。無ければ binary だけ
    if [ -d "$DB_HOME/venv.prev" ]; then
        mv "$DB_HOME/venv" "$DB_HOME/venv.rollback" \
            && mv "$DB_HOME/venv.prev" "$DB_HOME/venv" \
            && mv "$DB_HOME/venv.rollback" "$DB_HOME/venv.prev" \
            && echo "$(_ts) [ROLLBACK] venv <-> venv.prev swapped" >> "$DB_HOME/update.log" \
            || echo "[WARN] venv rollback failed (binary rolled back)"
    fi
    rm -f "$DB_HOME/.update-requested"
    printf 'result=rolled_back\nexit_code=0\nfinished_at=%s\n' "$(_ts)" > "$DB_HOME/.update-result"
    echo "$(_ts) [ROLLBACK] api <-> api.prev swapped" >> "$DB_HOME/update.log"
    echo "[OK] Rolled back to the previous binary (run 'db rollback' again to undo)"
}
if [ -f /etc/systemd/system/db.service ] && [ -d /run/systemd/system ]; then
    SCTL="systemctl"; JCTL="journalctl"
    [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && { SCTL="sudo systemctl"; JCTL="sudo journalctl"; }
    case "$1" in
        start)    $SCTL start db ;;
        stop)     $SCTL stop db ;;
        restart)  $SCTL restart db ;;
        rollback) $SCTL stop db && rollback_binary && $SCTL start db ;;
        status)   $SCTL status db --no-pager ;;
        logs)     $JCTL -u db -f ;;
        *)        echo "Usage: db {start|stop|restart|rollback|status|logs}"; exit 1 ;;
    esac
    exit $?
fi
case "$1" in
    start)    "$DB_HOME/start.sh" ;;
    stop)     "$DB_HOME/stop.sh" ;;
    rollback) "$DB_HOME/stop.sh"; rollback_binary && "$DB_HOME/start.sh" ;;
    *)        echo "Usage: db {start|stop|rollback}"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/db"

# Create symlink to /usr/local/bin (root: direct, non-root: sudo)。既に正しければ skip (= sudo 不要)
if [ "$(readlink /usr/local/bin/db 2>/dev/null)" = "$INSTALL_DIR/db" ]; then
    :
elif [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[WARN] Run: sudo ln -sf $INSTALL_DIR/db /usr/local/bin/db"
else
    $SUDO ln -sf "$INSTALL_DIR/db" /usr/local/bin/db 2>/dev/null || echo "[WARN] Run: ln -sf $INSTALL_DIR/db /usr/local/bin/db"
fi

echo ""
if [ "$SYSTEMD_OK" -eq 1 ] && [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
    $SUDO systemctl start db 2>/dev/null && echo "[OK] 更新完了、db.service を再開しました" || true
fi
echo "Done. Edit $INSTALL_DIR/.env then run: db start"
[ "$SYSTEMD_OK" -eq 1 ] && echo "      (systemd 管理: ブート時自動起動。ログは db logs / journalctl -u db)"
echo "      Models are cached at ~/.cache/huggingface/hub/"