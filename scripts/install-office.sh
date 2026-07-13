#!/bin/bash
# DigitalBase - Office画像化 (LibreOffice) インストーラ
# PowerPoint 等の Office 文書を PDF 化して「AI画像解析」で読めるようにするオプション機能
set -e

TOOLS_DIR="${HOME}/.local/db/tools"

SUDO=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# 日本語 (CJK) フォント確認。soffice の PDF 描画に必須で、無いと日本語が全て □ (豆腐) になり
# AI画像解析が文字を読めない。soffice 導入済み環境でも欠けていることがあるため必ず確認する。
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

# 既に soffice を検出できるなら LibreOffice は入れない (検出順は DigitalBase 本体と同じ)。
# ただしフォント欠落は soffice 導入済みでも起きるため、確認だけは必ず行う。
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

if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends libreoffice-impress
elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y libreoffice-impress
elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y libreoffice-impress
else
    echo "パッケージマネージャが見つかりません。AppImage で手動インストールしてください:"
    echo "  1) https://ja.libreoffice.org/download/appimage/ から Basic AppImage を取得"
    echo "  2) mkdir -p ${TOOLS_DIR} && mv LibreOffice-*.AppImage ${TOOLS_DIR}/"
    echo "  3) cd ${TOOLS_DIR} && chmod +x LibreOffice-*.AppImage && ./LibreOffice-*.AppImage --appimage-extract"
    echo "  4) printf '#!/bin/sh\\nexec ${TOOLS_DIR}/squashfs-root/AppRun \"\$@\"\\n' > ${TOOLS_DIR}/soffice && chmod +x ${TOOLS_DIR}/soffice"
    echo "  5) 日本語フォントも必要です (無いと日本語が □ になります): Noto Sans CJK をインストールしてください"
    exit 1
fi

ensure_cjk_fonts

echo "[OK] インストール完了: $(command -v soffice)"
echo "   管理画面 > 登録管理 の「Office画像化」で検出状態を確認できます (DigitalBase の再起動は不要)"
