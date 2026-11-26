#!/bin/bash
# 画像の文字認識 (OCR、Tesseract と日本語のデータ)。管理画面 > 登録管理 の「OCR」の「インストール」と同じ内容
#   curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-ocr.sh | sudo bash   (macOS は sudo なし)
set -e

SUDO=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

has_japanese() {
    command -v tesseract >/dev/null 2>&1 && tesseract --list-langs 2>/dev/null | grep -qx jpn
}

if has_japanese; then
    echo "[OK] 既にインストール済み: $(command -v tesseract) (日本語あり)"
    exit 0
fi

echo "OCR (Tesseract と日本語のデータ) をインストールします..."
if [ "$(uname -s)" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 || { echo "[ERROR] Homebrew が見つかりません: https://brew.sh"; exit 1; }
    # Homebrew は root で動かないので、sudo で実行された時は元の利用者で入れる
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" brew install tesseract tesseract-lang
    else
        brew install tesseract tesseract-lang
    fi
elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq tesseract-ocr tesseract-ocr-jpn
elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y tesseract tesseract-langpack-jpn
elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y tesseract-ocr tesseract-ocr-traineddata-japanese
else
    echo "[ERROR] apt / dnf / zypper が見つかりません。Tesseract と日本語のデータを手で入れてください"
    exit 1
fi

if ! has_japanese; then
    echo "[ERROR] Tesseract の日本語のデータ (jpn) が見つかりません: tesseract --list-langs"
    exit 1
fi
echo "[OK] インストール完了: $(command -v tesseract)"
echo "   管理画面 > 登録管理 の「OCR」で検出状態を確認できます (DigitalBase の再起動は不要)"
