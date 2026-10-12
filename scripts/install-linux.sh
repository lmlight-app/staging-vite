#!/bin/bash
# DigitalBase installer for Linux
#
#   curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-linux.sh | bash
#   curl -fsSL .../install-linux.sh | bash -s -- --engine vllm                  # GPU (NVIDIA)。AMD は --platform rocm、Intel は --platform xpu
#   curl -fsSL .../install-linux.sh | bash -s -- --version 26.1010.3
#   curl -fsSL .../install-linux.sh | bash -s -- --bundle /media/usb/db [--engine vllm]   # make an offline bundle (installs nothing here)
#   bash /media/usb/db/install-linux.sh                                          # offline host: install or update from the bundle
set -e

if [ -z "$HOME" ] || [ "$HOME" = "/" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME="/root"
    export HOME
fi

BASE_URL="${DB_BASE_URL:-https://github.com/lmlight-app/dist_vite/releases/latest/download}"
VERSION_BASE_URL="https://github.com/lmlight-app/dist_vite/releases/download/"
INSTALL_DIR="${DB_INSTALL_DIR:-$HOME/.local/db}"
SCRIPTS_URL="${DB_SCRIPTS_URL:-https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/}"
MIN_SETUP_VERSION="26.1012"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; *) echo "[ERROR] unsupported CPU: $ARCH"; exit 1 ;; esac
BINARY_NAME="lmlight-vite-linux-$ARCH"

DB_VERSION="${DB_VERSION:-latest}"
OFFLINE_DIR="${DB_WHEELHOUSE:-}"
OFFLINE=0
BUNDLE_DIR=""
PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --version) DB_VERSION="${2:?--version requires latest|YY.MMDD[.N]|xYYYYMMDD[.N][-linux]}"; shift ;;
        --offline)
            OFFLINE=1
            if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then OFFLINE_DIR="$2"; shift; fi ;;
        --wheelhouse) OFFLINE_DIR="${2:?--wheelhouse requires DIR}"; shift ;;
        --bundle) BUNDLE_DIR="${2:?--bundle requires DIR}"; shift ;;
        -h|--help)
            echo "Usage: install-linux.sh [--engine ollama|vllm|sglang] [--platform cuda|rocm|xpu] [--version VERSION] [--offline DIR | --bundle DIR [--with-models]] [other options of 'api setup']"
            exit 0 ;;
        *) PASS+=("$1") ;;
    esac
    shift
done
[ "$OFFLINE" -eq 0 ] || [ -n "$OFFLINE_DIR" ] || { echo "[ERROR] --offline requires DIR (or --wheelhouse DIR)"; exit 2; }
if [ -z "$OFFLINE_DIR" ] && [ -z "$BUNDLE_DIR" ] && [ -f "$0" ] && [ -f "$(dirname "$0")/bundle.json" ]; then
    OFFLINE_DIR="$(dirname "$0")"
fi
[ -z "$BUNDLE_DIR" ] || [ -z "$OFFLINE_DIR" ] || { echo "[ERROR] --bundle cannot be combined with --offline"; exit 2; }
[ -z "$OFFLINE_DIR" ] || { OFFLINE=1; OFFLINE_DIR="$(cd "$OFFLINE_DIR" && pwd -P)"; }
printf '%s' "$DB_VERSION" | grep -Eq '^(latest|[0-9]{2}\.[0-9]{4}(\.[0-9]+)?|x[0-9]{8}(\.[0-9]+)?(-[a-z0-9]+)?)$' \
    || { echo "[ERROR] --version must be latest, a version (YY.MMDD[.N]), or a release tag (xYYYYMMDD[.N][-linux])"; exit 2; }

TARGET_VERSION=""
if [ "$DB_VERSION" != "latest" ]; then
    [ "$OFFLINE" -eq 0 ] || { echo "[ERROR] --version cannot be combined with --offline (the offline directory decides the version)"; exit 2; }
    RELEASE_REF="$DB_VERSION"
# BEGIN staging-only
    case "$RELEASE_REF" in
        x*) ;;
        *)
            RAW_VERSION="20$(printf '%s' "$RELEASE_REF" | sed -E 's/^([0-9]{2})\.([0-9]{4})/\1\2/')"
            CANDIDATES="$(curl -fsSL "https://api.github.com/repos/lmlight-app/dist_vite/releases?per_page=100" 2>/dev/null \
                | grep -o '"tag_name": *"x'"$RAW_VERSION"'\(-[a-z0-9]*\)\{0,1\}"' | sed -E 's/.*"(x[^"]+)".*/\1/')"
            RELEASE_REF="$(printf '%s\n' "$CANDIDATES" | grep -m1 -- '-linux$' || printf '%s\n' "$CANDIDATES" | grep -m1 -v -- '-' || true)"
            [ -n "$RELEASE_REF" ] || { echo "[ERROR] Version $DB_VERSION was not found in releases; pass the release tag instead (xYYYYMMDD[.N][-linux])"; exit 1; }
            ;;
    esac
# END staging-only
    [ -n "${DB_BASE_URL:-}" ] || BASE_URL="${VERSION_BASE_URL}${RELEASE_REF}"
    TARGET_VERSION="$(printf '%s' "$RELEASE_REF" | sed -E 's/^x20([0-9]{2})([0-9]{4})/\1.\2/; s/-[a-z0-9]+$//')"
fi

TARGET_DIR="$INSTALL_DIR"
if [ -n "$BUNDLE_DIR" ]; then
    mkdir -p "$BUNDLE_DIR"; TARGET_DIR="$(cd "$BUNDLE_DIR" && pwd -P)"
fi
mkdir -p "$TARGET_DIR"
SOURCE="$BASE_URL"
[ "$OFFLINE" -eq 0 ] || SOURCE="$OFFLINE_DIR"
fetch() {
    if [ "$OFFLINE" -eq 1 ]; then
        [ -f "$OFFLINE_DIR/$1" ] || return 1
        cp -f "$OFFLINE_DIR/$1" "$2"
    else
        curl -fL --connect-timeout 30 --max-time 0 --retry 3 --retry-delay 5 "$BASE_URL/$1" -o "$2"
    fi
}
if [ -z "$TARGET_VERSION" ]; then
    MANIFEST="$(mktemp)"
    if fetch latest.json "$MANIFEST" 2>/dev/null; then
        TARGET_VERSION="$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)"
    fi
    rm -f "$MANIFEST"
fi
version_lt() { awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) { p = (i <= n) ? x[i] + 0 : 0; q = (i <= m) ? y[i] + 0 : 0; if (p < q) exit 0; if (p > q) exit 1 } exit 1 }'; }
if [ -n "$TARGET_VERSION" ] && version_lt "$TARGET_VERSION" "$MIN_SETUP_VERSION"; then
    echo "[ERROR] $TARGET_VERSION is older than $MIN_SETUP_VERSION and cannot be installed with this installer"; exit 2
fi

if [ -n "$BUNDLE_DIR" ]; then
    echo "Creating an offline bundle of DigitalBase ${TARGET_VERSION:-latest} ($ARCH) in $TARGET_DIR"
    BIN="$TARGET_DIR/$BINARY_NAME"
else
    echo "Installing DigitalBase ${TARGET_VERSION:-latest} ($ARCH) to $INSTALL_DIR from $SOURCE"
    BIN="$INSTALL_DIR/api.new.$$"
fi
fetch "$BINARY_NAME" "$BIN" || true
if [ ! -s "$BIN" ] || ! head -c 4 "$BIN" | grep -q $'\x7fELF'; then
    rm -f "$BIN"
    echo "[ERROR] Failed to get the binary: $SOURCE/$BINARY_NAME"; exit 1
fi
if [ "${DB_SKIP_SHA256:-0}" = "1" ]; then
    echo "[WARN] sha256 verification skipped (DB_SKIP_SHA256=1)"
else
    SUM="$(mktemp)"
    EXPECTED=""
    fetch "$BINARY_NAME.sha256" "$SUM" 2>/dev/null && EXPECTED="$(awk '{print $1}' "$SUM" | tr 'A-F' 'a-f')"
    rm -f "$SUM"
    if printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
        ACTUAL="$(sha256sum "$BIN" | awk '{print $1}')"
        [ "$EXPECTED" = "$ACTUAL" ] || { rm -f "$BIN"; echo "[ERROR] sha256 mismatch: expected $EXPECTED, got $ACTUAL"; exit 1; }
        echo "[OK] sha256 verified: $ACTUAL"
    else
        echo "[WARN] checksum unavailable ($SOURCE/$BINARY_NAME.sha256), continuing without sha256 verification"
    fi
fi
if [ -n "$BUNDLE_DIR" ]; then
    [ -z "$EXPECTED" ] || printf '%s  %s\n' "$EXPECTED" "$BINARY_NAME" > "$TARGET_DIR/$BINARY_NAME.sha256"
    fetch latest.json "$TARGET_DIR/latest.json" 2>/dev/null || true
    curl -fsSL "${SCRIPTS_URL%/}/install-linux.sh" -o "$TARGET_DIR/install-linux.sh" || { echo "[ERROR] Could not download install-linux.sh"; exit 1; }
    RUN_DIR="$(mktemp -d)"
    cp "$BIN" "$RUN_DIR/api" && chmod +x "$RUN_DIR/api"
    exec "$RUN_DIR/api" setup --bundle "$TARGET_DIR" --product-version "$TARGET_VERSION" "${PASS[@]}"
fi
chmod +x "$BIN"

SETUP=(setup --binary "$BIN" --product-version "$TARGET_VERSION")
[ "$OFFLINE" -eq 0 ] || SETUP+=(--offline "$OFFLINE_DIR")
export DB_INSTALL_DIR="$INSTALL_DIR"
cd "$INSTALL_DIR"
exec "$BIN" "${SETUP[@]}" "${PASS[@]}"
