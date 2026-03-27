# AI Server Dependency Checker
# Checks if all required dependencies are installed

$ErrorActionPreference = "SilentlyContinue"

function Test-Command {
    param($Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Show-InstallInstructions {
    param(
        [string[]]$MissingDeps
    )

    $host.UI.RawUI.WindowTitle = "AI Server - 依存関係チェック"

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║     AI Server 依存関係チェック                        ║" -ForegroundColor Yellow
    Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if ($MissingDeps.Count -eq 0) {
        Write-Host "[✓] すべての依存関係がインストールされています！" -ForegroundColor Green
        Write-Host ""
        Write-Host "AI Server を起動できます:" -ForegroundColor Cyan
        Write-Host "  スタートメニュー → AI Server → AI Server" -ForegroundColor White
        Write-Host ""
        Write-Host "または、PowerShellで:" -ForegroundColor Cyan
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\start.ps1`"" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host "[!] 以下の依存関係が不足しています:" -ForegroundColor Red
        Write-Host ""

        foreach ($dep in $MissingDeps) {
            switch ($dep) {
                "postgresql" {
                    Write-Host "  [×] PostgreSQL" -ForegroundColor Red
                    Write-Host "      インストール: winget install PostgreSQL.PostgreSQL" -ForegroundColor Gray
                }
                "ollama" {
                    Write-Host "  [×] Ollama" -ForegroundColor Red
                    Write-Host "      インストール: winget install Ollama.Ollama" -ForegroundColor Gray
                }
                "tesseract" {
                    Write-Host "  [×] Tesseract OCR (画像OCR用)" -ForegroundColor Red
                    Write-Host "      ダウンロード: https://github.com/UB-Mannheim/tesseract/wiki" -ForegroundColor Gray
                }
            }
            Write-Host ""
        }

        Write-Host "依存関係をインストール後、再度このスクリプトを実行してください。" -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host "============================================================"
    Write-Host "  ライセンス設定"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "  ライセンスファイルを以下に配置してください:"
    Write-Host "    $PSScriptRoot\..\license.lic"
    Write-Host ""
    Write-Host "  ライセンス購入: https://digital-base.co.jp/services/localllm/lmlight-purchase" -ForegroundColor Cyan
    Write-Host ""

    # Keep window open
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Check each dependency
$MissingDeps = @()

if (-not (Test-Command "psql")) {
    $MissingDeps += "postgresql"
}

if (-not (Test-Command "ollama")) {
    $MissingDeps += "ollama"
}

if (-not (Test-Command "tesseract")) {
    $MissingDeps += "tesseract"
}

# Show results
Show-InstallInstructions -MissingDeps $MissingDeps
