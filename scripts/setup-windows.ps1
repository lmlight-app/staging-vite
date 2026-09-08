#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/setup-windows.ps1 | iex
#

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PGVECTOR_URL = if ($env:PGVECTOR_BASE_URL) { $env:PGVECTOR_BASE_URL } else { "https://github.com/lmlight-app/dist_vite/releases/download/pgvector-latest" }

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

Write-Host "Setting up AI Server environment for Windows (PostgreSQL / pgvector / Ollama)..."

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限が必要です。PowerShell を「管理者として実行」で開き直してから再実行してください (pgvector の DLL 配置のため)。"
}

$MISSING_DEPS = @()

function Add-PgBinToPath {
    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
        $pgRoot = Get-ChildItem "C:\Program Files\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path "$($_.FullName)\bin\psql.exe" } |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if ($pgRoot) { $env:PATH = "$pgRoot\bin;$env:PATH" }
    }
}
Add-PgBinToPath

if (Get-Command psql -ErrorAction SilentlyContinue) { Write-Success "PostgreSQL OK" } else { Write-Warn "PostgreSQL 未検出 → winget で導入します"; $MISSING_DEPS += "postgresql" }
if (Get-Command ollama -ErrorAction SilentlyContinue) { Write-Success "Ollama OK" } else { Write-Warn "Ollama 未検出 → winget で導入します"; $MISSING_DEPS += "ollama" }
if ((Get-Command tesseract -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe")) { Write-Success "Tesseract OCR OK (画像OCR用)" } else { Write-Warn "Tesseract OCR 未検出 (オプション: 画像OCR用)"; $MISSING_DEPS += "tesseract" }

foreach ($dep in $MISSING_DEPS) {
    switch ($dep) {
        "postgresql" {
            Write-Info "PostgreSQL を winget で導入中..."
            winget install -e --id PostgreSQL.PostgreSQL --silent --accept-package-agreements --accept-source-agreements
            Add-PgBinToPath
        }
        "ollama" {
            Write-Info "Ollama を winget で導入中..."
            $null = winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements 2>&1
        }
        "tesseract" {
            Write-Warn "Tesseract は手動導入が必要です (日本語データを含めてください): https://github.com/UB-Mannheim/tesseract/wiki"
        }
    }
}

Write-Info "pgvector をセットアップ中..."

$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService -and $pgService.Status -ne "Running") {
    try { Start-Service $pgService.Name -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { Write-Warn "PostgreSQL サービスの起動に失敗しました。手動で起動してください。" }
}

$PG_DIR = $null
$pgBase = "C:\Program Files\PostgreSQL"
if (Test-Path $pgBase) {
    $PG_DIR = Get-ChildItem $pgBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\bin\psql.exe" } |
        Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $PG_DIR) {
    $psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
    if ($psqlCmd) { $PG_DIR = Split-Path (Split-Path $psqlCmd.Source -Parent) -Parent }
}

if (-not $PG_DIR) {
    Write-Warn "PostgreSQL が見つからないため pgvector 配置をスキップしました。PostgreSQL を導入後に再実行してください。"
} elseif (Test-Path "$PG_DIR\lib\vector.dll") {
    Write-Success "pgvector は既に配置済みです"
} else {
    $pgMajor = (Split-Path $PG_DIR -Leaf)
    Write-Info "pgvector DLL を取得・配置中 (PostgreSQL $pgMajor)..."
    try {
        $zip = "$env:TEMP\pgvector.zip"; $extr = "$env:TEMP\pgvector_extract"
        Invoke-WebRequest -Uri "$PGVECTOR_URL/pgvector-pg$pgMajor-windows-x64.zip" -OutFile $zip -UseBasicParsing
        if (Test-Path $extr) { Remove-Item -Recurse -Force $extr }
        Expand-Archive -Path $zip -DestinationPath $extr -Force
        Get-ChildItem -Path $extr -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($extr.Length).TrimStart('\')
            $dst = Join-Path $PG_DIR $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -Force $_.FullName $dst -ErrorAction Stop
        }
        Remove-Item $zip, $extr -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "pgvector を配置しました"
    } catch {
        Write-Warn "pgvector の配置に失敗しました: $($_.Exception.Message) — RAG (ベクトル検索) は無効化されます。"
    }
}

Write-Host ""
Write-Success "環境設定が完了しました。続けて通常ユーザーの PowerShell で本体をインストールしてください:"
Write-Host "   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex"
