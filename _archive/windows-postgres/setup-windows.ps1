#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/setup-windows.ps1 | iex
#

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PGVECTOR_URL = if ($env:PGVECTOR_BASE_URL) { $env:PGVECTOR_BASE_URL } else { "https://github.com/lmlight-app/dist_vite/releases/download/pgvector-latest" }
# winget の PostgreSQL はメジャーバージョンごとの ID (PostgreSQL.PostgreSQL.18 など)。pgvector の DLL を配っている中で新しいものを既定にする
$PG_MAJOR = if ($env:DB_PG_MAJOR) { $env:DB_PG_MAJOR } else { "18" }
$DB_USER = if ($env:DB_USER) { $env:DB_USER } else { "digitalbase" }
$DB_PASSWORD = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { "digitalbase" }
$DB_NAME = if ($env:DB_NAME) { $env:DB_NAME } else { "digitalbase" }
$PG_SUPER_PASSWORD = $null

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

Write-Host "Setting up AI Server environment for Windows (PostgreSQL / pgvector)..."

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
if ((Get-Command tesseract -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe")) { Write-Success "Tesseract OCR OK (画像OCR用)" } else { Write-Warn "Tesseract OCR 未検出 (オプション: 画像OCR用)"; $MISSING_DEPS += "tesseract" }

foreach ($dep in $MISSING_DEPS) {
    switch ($dep) {
        "postgresql" {
            Write-Info "PostgreSQL $PG_MAJOR を winget で導入中 (数分かかります)..."
            # 黙って入れると postgres のパスワードが分からなくなるので、ここで決めて渡す (終わりに表示する)
            $PG_SUPER_PASSWORD = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
            $wingetOut = winget install -e --id "PostgreSQL.PostgreSQL.$PG_MAJOR" --silent --accept-package-agreements --accept-source-agreements --custom "--superpassword $PG_SUPER_PASSWORD --enable-components server,commandlinetools --disable-components pgAdmin,stackbuilder" 2>&1
            $wingetExit = $LASTEXITCODE
            Add-PgBinToPath
            if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
                # -1978335189 = winget は「入っている」と言うが実体が無い (消し残りの登録など)
                Write-Error "PostgreSQL $PG_MAJOR の導入に失敗しました (winget exit=$wingetExit)。`n$(($wingetOut | Select-Object -Last 5) -join "`n")`nアプリと機能に PostgreSQL が残っていれば消してから、もう一度実行してください"
            }
            if ($wingetExit -ne 0) { $PG_SUPER_PASSWORD = $null }
            Write-Success "PostgreSQL $PG_MAJOR を導入しました"
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
        try {
            Invoke-WebRequest -Uri "$PGVECTOR_URL/pgvector-pg$pgMajor-windows-x64.zip" -OutFile $zip -UseBasicParsing
        } catch {
            throw "PostgreSQL $pgMajor 用の pgvector がまだ配られていません。PostgreSQL 15〜18 を使ってください ($($_.Exception.Message))"
        }
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

# 自分で PostgreSQL を入れた時は postgres のパスワードを知っているので、DigitalBase 用のユーザー・DB・pgvector までここで作る
# (install-windows.ps1 は通常ユーザーで動き、作ってあれば postgres のパスワードを聞かずに進む)
if ($PG_SUPER_PASSWORD -and $PG_DIR) {
    $psql = Join-Path $PG_DIR "bin\psql.exe"
    $env:PGPASSWORD = $PG_SUPER_PASSWORD
    $sql = "DO `$`$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER') THEN CREATE ROLE `"$DB_USER`" LOGIN PASSWORD '$DB_PASSWORD' CREATEDB; END IF; END `$`$;"
    $out = & $psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Error "DB ユーザーの作成に失敗しました: $out" }
    if ((& $psql -h 127.0.0.1 -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'") -ne "1") {
        $out = & $psql -h 127.0.0.1 -U postgres -d postgres -c "CREATE DATABASE `"$DB_NAME`" OWNER `"$DB_USER`"" 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error "データベースの作成に失敗しました: $out" }
    }
    $out = & $psql -h 127.0.0.1 -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Success "データベース $DB_NAME と pgvector を用意しました" } else { Write-Warn "pgvector を有効にできませんでした — RAG (ベクトル検索) は無効になります: $out" }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Warn "PostgreSQL の postgres ユーザーのパスワード: $PG_SUPER_PASSWORD (この画面にだけ出します。控えておいてください)"
}

Write-Host ""
Write-Success "環境設定が完了しました。続けて通常ユーザーの PowerShell で本体をインストールしてください:"
Write-Host "   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex"
