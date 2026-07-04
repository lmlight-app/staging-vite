#!/bin/bash
# DigitalBase - Office画像化 (LibreOffice) インストーラ
# PowerPoint 等の Office 文書を PDF 化して「AI画像解析」で読めるようにするオプション機能
set -e

TOOLS_DIR="${HOME}/.local/db/tools"

# 既に検出できるなら何もしない (検出順は DigitalBase 本体と同じ)
if [ -n "$SOFFICE_PATH" ] && [ -x "$SOFFICE_PATH" ]; then
    echo "✅ 既にインストール済み: $SOFFICE_PATH"
    exit 0
fi
if command -v soffice >/dev/null 2>&1; then
    echo "✅ 既にインストール済み: $(command -v soffice)"
    exit 0
fi
if [ -x "${TOOLS_DIR}/soffice" ]; then
    echo "✅ 既にインストール済み: ${TOOLS_DIR}/soffice"
    exit 0
fi

echo "Office画像化 (LibreOffice) をインストールします (ディスク約400-700MB)..."

SUDO=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

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
    exit 1
fi

echo "✅ インストール完了: $(command -v soffice)"
echo "   管理画面 > モデル管理 の「Office画像化」で検出状態を確認できます (DigitalBase の再起動は不要)"
