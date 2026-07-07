# DigitalBase - Office画像化 (LibreOffice) インストーラー
# PowerPoint 等の Office 文書を PDF 化して「AI画像解析」で読めるようにするオプション機能
# 使い方: 通常ユーザーの PowerShell で実行 (管理者権限不要)
#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-office.ps1 | iex

$ErrorActionPreference = "Stop"

# soffice 検出 (DigitalBase 本体の find_soffice() と同じ探索順: SOFFICE_PATH → 標準インストール先 → PATH)
function Find-Soffice {
    if ($env:SOFFICE_PATH -and (Test-Path $env:SOFFICE_PATH)) { return $env:SOFFICE_PATH }
    foreach ($p in @(
        "$env:ProgramFiles\LibreOffice\program\soffice.exe",
        "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe"
    )) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command soffice.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  DigitalBase Office画像化 (LibreOffice) インストーラー" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

$existing = Find-Soffice
if ($existing) {
    Write-Host "[OK] 既にインストール済み: $existing" -ForegroundColor Green
    exit 0
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] wingetが見つかりません。公式インストーラで導入してください:" -ForegroundColor Red
    Write-Host "   https://ja.libreoffice.org/download/libreoffice-still/"
    exit 1
}

Write-Host "LibreOfficeをインストールします (ディスク約400-700MB)..." -ForegroundColor Yellow
winget install -e --id TheDocumentFoundation.LibreOffice --silent --accept-package-agreements --accept-source-agreements

$installed = Find-Soffice
if ($installed) {
    Write-Host ""
    Write-Host "[OK] インストール完了: $installed" -ForegroundColor Green
    Write-Host "   管理画面 > 登録管理 の「Office画像化」で検出状態を確認できます (DigitalBaseの再起動は不要)" -ForegroundColor Cyan
} else {
    Write-Host "[ERROR] インストールを確認できませんでした。PC再起動後に再度お試しいただくか、手動確認してください:" -ForegroundColor Red
    Write-Host "   winget list --id TheDocumentFoundation.LibreOffice"
    exit 1
}
