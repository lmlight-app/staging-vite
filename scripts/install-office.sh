#!/bin/bash
set -e

# 本体が自動で探す場所。sudo env DB_INSTALL_DIR=... で実行されても本体の配置先に置く
TOOLS_DIR="${DB_INSTALL_DIR:-${HOME}/.local/db}/tools"
APPIMAGE_URL="https://appimages.libreitalia.org/LibreOffice-still.basic-x86_64.AppImage"

SUDO=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

ensure_cjk_fonts() {
    if command -v fc-list >/dev/null 2>&1 && [ -n "$(fc-list :lang=ja 2>/dev/null | head -1)" ]; then
        return 0
    fi
    echo "日本語フォント (Noto CJK) をインストールします..."
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq fonts-noto-cjk || true
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y google-noto-sans-cjk-ttc-fonts 2>/dev/null \
            || $SUDO dnf install -y google-noto-sans-cjk-fonts || true
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper install -y noto-sans-cjk-fonts 2>/dev/null \
            || $SUDO zypper install -y google-noto-sans-jp-fonts || true
    fi
    if command -v fc-list >/dev/null 2>&1 && [ -z "$(fc-list :lang=ja 2>/dev/null | head -1)" ]; then
        echo "[WARN] 日本語フォントを検出できません。このままでは Office 文書の日本語が □ として描画され、"
        echo "       AI画像解析で内容を読み取れません。Noto Sans CJK 等を手動でインストールしてください。"
    fi
}

if [ -n "$SOFFICE_PATH" ] && [ -x "$SOFFICE_PATH" ]; then
    echo "[OK] 既にインストール済み: $SOFFICE_PATH"
    ensure_cjk_fonts
    exit 0
fi
if command -v soffice >/dev/null 2>&1; then
    echo "[OK] 既にインストール済み: $(command -v soffice)"
    ensure_cjk_fonts
    exit 0
fi
if [ -x "${TOOLS_DIR}/soffice" ]; then
    echo "[OK] 既にインストール済み: ${TOOLS_DIR}/soffice"
    ensure_cjk_fonts
    exit 0
fi

echo "Office画像化 (LibreOffice) をインストールします (ディスク約400-700MB)..."

install_package() {
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq \
            && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends libreoffice-impress
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y libreoffice-impress
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper install -y libreoffice-impress
    else
        return 1
    fi
}

# RHEL 10 は LibreOffice の RPM を配布しない (Rocky / Alma 10 も同じ想定)。公式の AppImage を展開して tools に置く
install_appimage() {
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) echo "[ERROR] AppImage は x86_64 のみです ($(uname -m))。LibreOffice を入れて SOFFICE_PATH で指定してください"; exit 1 ;;
    esac
    echo "AppImage を取得します (約 300MB)..."
    mkdir -p "$TOOLS_DIR"
    curl -fL --retry 5 --retry-all-errors --retry-delay 3 --progress-bar -o "$TOOLS_DIR/LibreOffice.AppImage" "$APPIMAGE_URL"
    chmod +x "$TOOLS_DIR/LibreOffice.AppImage"
    rm -rf "$TOOLS_DIR/squashfs-root"
    (cd "$TOOLS_DIR" && ./LibreOffice.AppImage --appimage-extract >/dev/null)
    rm -f "$TOOLS_DIR/LibreOffice.AppImage"
    # AppRun は新しいプロファイルの初回に rc=81 (再起動の要求) で何もせず終わる。本体は変換ごとに新しいプロファイルを使うので、再起動を処理する program/soffice を呼ぶ
    program="$(ls -d "$TOOLS_DIR"/squashfs-root/opt/libreoffice*/program 2>/dev/null | head -1)"
    [ -x "$program/soffice" ] || { echo "[ERROR] AppImage の中に soffice が見つかりません"; exit 1; }
    printf '#!/bin/sh\nexec "%s/soffice" "$@"\n' "$program" > "$TOOLS_DIR/soffice"
    chmod +x "$TOOLS_DIR/soffice"
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        chown -R "$SUDO_USER" "$TOOLS_DIR"
    fi
    # --version は通っても変換できないことがあるので、本体と同じ呼び方で確かめる
    check="$(mktemp -d)"
    printf 'DigitalBase\n' > "$check/check.txt"
    "$TOOLS_DIR/soffice" --headless --norestore "-env:UserInstallation=file://$check/profile" --convert-to pdf --outdir "$check" "$check/check.txt" > /dev/null 2>&1 || true
    if [ ! -s "$check/check.pdf" ]; then
        rm -rf "$check"
        echo "[ERROR] LibreOffice で変換できません"
        exit 1
    fi
    rm -rf "$check"
}

if [ "$(uname -s)" != "Linux" ]; then
    echo "[ERROR] LibreOffice を入れてから再実行してください: brew install --cask libreoffice"
    exit 1
fi

if ! install_package; then
    echo "[WARN] パッケージから入れられないので、AppImage に切り替えます"
    install_appimage
fi

ensure_cjk_fonts

echo "[OK] インストール完了: $(command -v soffice || echo "$TOOLS_DIR/soffice")"
echo "   管理画面 > 登録管理 の「Office画像化」で検出状態を確認できます (DigitalBase の再起動は不要)"
