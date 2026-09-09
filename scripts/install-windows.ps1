
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================================================
# ============================================================

$BASE_URL = if ($env:DB_BASE_URL) { $env:DB_BASE_URL } else { "https://github.com/lmlight-app/dist_vite/releases/latest/download" }
$VERSION_BASE_URL="https://github.com/lmlight-app/dist_vite/releases/download/"
$DB_VERSION = if ($env:DB_VERSION) { $env:DB_VERSION } else { "latest" }
if ($DB_VERSION -notmatch '^(latest|\d{2}\.\d{4}(\.\d+)?|x\d{8}(\.\d+)?(-[a-z0-9]+)?)$') {
    throw "DB_VERSION must be latest, a version (YY.MMDD[.N]), or a release tag (xYYYYMMDD[.N][-windows])"
}
if ($DB_VERSION -ne "latest" -and -not $env:DB_BASE_URL) {
    $releaseRef = $DB_VERSION
# BEGIN staging-only
    if ($releaseRef -notlike "x*") {
        $raw = "20" + ($releaseRef -replace '^(\d{2})\.(\d{4})', '$1$2')
        $tags = (Invoke-RestMethod -Uri "https://api.github.com/repos/lmlight-app/dist_vite/releases?per_page=100" -UseBasicParsing).tag_name |
            Where-Object { $_ -match ('^x' + [regex]::Escape($raw) + '(-[a-z0-9]+)?$') }
        $releaseRef = ($tags | Where-Object { $_ -like "*-windows" } | Select-Object -First 1)
        if (-not $releaseRef) { $releaseRef = ($tags | Where-Object { $_ -notlike "*-*" } | Select-Object -First 1) }
        if (-not $releaseRef) { throw "Version $DB_VERSION was not found in releases; set DB_VERSION to the release tag instead (xYYYYMMDD[.N][-windows])" }
    }
# END staging-only
    $BASE_URL = "$VERSION_BASE_URL$releaseRef"
}
$INSTALL_DIR = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$ARCH = if ($env:DB_ARCH) { $env:DB_ARCH } else { "amd64" }

$DB_USER = if ($env:DB_USER) { $env:DB_USER } else { "digitalbase" }
$DB_PASSWORD = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { "digitalbase" }
$DB_NAME = if ($env:DB_NAME) { $env:DB_NAME } else { "digitalbase" }

if (Test-Path "$INSTALL_DIR\.env") {
    $dbUrlLine = Get-Content "$INSTALL_DIR\.env" | Where-Object { $_ -match "^DATABASE_URL=" } | Select-Object -First 1
    if ($dbUrlLine -match "^DATABASE_URL=postgresql://([^:]+):([^@]+)@[^/]+/([^?]+)") {
        $DB_USER = $matches[1]
        $DB_PASSWORD = $matches[2]
        $DB_NAME = $matches[3]
    }
}

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

Write-Host "Installing AI Server for Windows ($ARCH) to $INSTALL_DIR..."

New-Item -ItemType Directory -Force -Path "$INSTALL_DIR" | Out-Null
New-Item -ItemType Directory -Force -Path "$INSTALL_DIR\logs" | Out-Null

if (Test-Path "$INSTALL_DIR\api.exe") {
    Write-Info "既存のインストールを検出しました。アップデート中..."

    Write-Info "既存のプロセスを停止中..."
    Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Success "既存のプロセスを停止しました"
}

# ============================================================
# ============================================================
Write-Info "ステップ 1/5: バイナリをダウンロード中..."

$BACKEND_FILE = "lmlight-vite-windows-$ARCH.exe"
Write-Info "バイナリをダウンロード中... ($BACKEND_FILE)"
Invoke-WebRequest -Uri "$BASE_URL/$BACKEND_FILE" -OutFile "$INSTALL_DIR\api.exe" -UseBasicParsing
Write-Success "バイナリをダウンロードしました"

# ============================================================
# ============================================================
Write-Info "ステップ 2/5: 依存関係をチェック中..."

$MISSING_DEPS = @()

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pgRoot = Get-ChildItem "C:\Program Files\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\bin\psql.exe" } |
        Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($pgRoot) { $env:PATH = "$pgRoot\bin;$env:PATH" }
}

if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Success "PostgreSQL が見つかりました"
} else {
    Write-Warn "PostgreSQL が見つかりません"
    $MISSING_DEPS += "postgresql"
}

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Success "Ollama が見つかりました"
} else {
    Write-Warn "Ollama が見つかりません"
    $MISSING_DEPS += "ollama"
}

if ((Get-Command tesseract -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe")) {
    Write-Success "Tesseract OCR が見つかりました (画像OCR用)"
} else {
    Write-Warn "Tesseract OCR 未接続 (オプション: 画像OCR用)"
    $MISSING_DEPS += "tesseract"
}

if ($MISSING_DEPS -contains "postgresql" -or $MISSING_DEPS -contains "ollama") {
    Write-Error "前提ソフトが未導入です ($($MISSING_DEPS -join ', '))。`n先に管理者 PowerShell で環境設定を実行してください:`n  irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/setup-windows.ps1 | iex"
}
if ($MISSING_DEPS -contains "tesseract") {
    Write-Warn "Tesseract OCR 未導入 (オプション: 画像OCR用)。必要なら setup-windows.ps1 で導入されます。"
}

$UvExe = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
if (-not (Get-Command uv -ErrorAction SilentlyContinue) -and -not (Test-Path $UvExe)) {
    Write-Info "uv (Python パッケージ管理) をインストールしています (= optional features の前提)..."
    try {
        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" *> $null
        if (Test-Path $UvExe) { Write-Success "uv をインストールしました" } else { throw "uv.exe not found after install" }
    } catch {
        Write-Warn "uv のインストールに失敗しました。後で: powershell -ExecutionPolicy Bypass -c `"irm https://astral.sh/uv/install.ps1 | iex`""
    }
} else {
    Write-Success "uv が見つかりました"
}

# ============================================================
# ============================================================
Write-Info "ステップ 3/5: PostgreSQL をセットアップ中..."

$DB_PORT = "5432"

if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Info "データベースを作成中..."

    $env:PGHOST = "127.0.0.1"

    $pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pgService -and $pgService.Status -ne "Running") {
        try {
            Start-Service $pgService.Name -ErrorAction Stop
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "PostgreSQL サービスの起動に失敗しました: $_`nサービス '$($pgService.Name)' を手動で起動してから再実行してください"
        }
    }

    $ErrorActionPreference = "Continue"

    function Test-PgConnect {
        param([string]$Password, [string]$Port)
        $env:PGPASSWORD = $Password
        $null = psql -U postgres -p $Port -c "SELECT 1" 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    function Test-PgPort {
        param([string]$Port)
        & pg_isready -h 127.0.0.1 -p $Port -q 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    if (Test-PgPort -Port "5432") {
        $DB_PORT = "5432"
    } elseif (Test-PgPort -Port "5433") {
        $DB_PORT = "5433"
    } else {
        Write-Error "PostgreSQL に接続できません (5432/5433 とも応答なし)。サービスが起動しているか確認してください"
    }
    Write-Info "PostgreSQL ポート: $DB_PORT"

    $dbProvisioned = $false
    $env:PGPASSWORD = $DB_PASSWORD
    $null = psql -U $DB_USER -p $DB_PORT -d $DB_NAME -c "SELECT 1" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $dbProvisioned = $true
        Write-Success "既存のデータベース ($DB_USER/$DB_NAME) を検出 - postgres 管理者セットアップをスキップします"
    }

    if (-not $dbProvisioned) {
    $pgSuperPassword = $null
    foreach ($candidate in @("postgres", $DB_PASSWORD, "")) {
        if (Test-PgConnect -Password $candidate -Port $DB_PORT) {
            $pgSuperPassword = $candidate
            break
        }
    }

    if ($null -eq $pgSuperPassword) {
        Write-Warn "postgres スーパーユーザーへの自動接続に失敗しました"
        Write-Info "PostgreSQL インストール時に設定したパスワードを入力してください"
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        for ($i = 1; $i -le 3; $i++) {
            $form = New-Object System.Windows.Forms.Form
            $form.Text = "PostgreSQL 管理者パスワード"
            $form.Size = New-Object System.Drawing.Size(420, 180)
            $form.StartPosition = "CenterScreen"
            $form.Topmost = $true
            $form.FormBorderStyle = "FixedDialog"
            $form.MaximizeBox = $false; $form.MinimizeBox = $false

            $label = New-Object System.Windows.Forms.Label
            $label.Text = "PostgreSQL インストール時に設定した postgres ユーザーのパスワードを入力してください (試行 $i/3)"
            $label.Location = New-Object System.Drawing.Point(12, 15)
            $label.Size = New-Object System.Drawing.Size(380, 40)
            $form.Controls.Add($label)

            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.UseSystemPasswordChar = $true
            $textBox.Location = New-Object System.Drawing.Point(12, 60)
            $textBox.Size = New-Object System.Drawing.Size(380, 24)
            $form.Controls.Add($textBox)

            $okButton = New-Object System.Windows.Forms.Button
            $okButton.Text = "OK"
            $okButton.Location = New-Object System.Drawing.Point(225, 100)
            $okButton.Size = New-Object System.Drawing.Size(80, 28)
            $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Controls.Add($okButton); $form.AcceptButton = $okButton

            $cancelButton = New-Object System.Windows.Forms.Button
            $cancelButton.Text = "キャンセル"
            $cancelButton.Location = New-Object System.Drawing.Point(312, 100)
            $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
            $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Controls.Add($cancelButton); $form.CancelButton = $cancelButton

            $form.Add_Shown({ $textBox.Focus() | Out-Null })
            $result = $form.ShowDialog()
            if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
                Write-Error "ユーザーがパスワード入力をキャンセルしました"
            }
            $plain = $textBox.Text
            if (Test-PgConnect -Password $plain -Port $DB_PORT) {
                $pgSuperPassword = $plain
                break
            }
            [System.Windows.Forms.MessageBox]::Show("認証失敗。再入力してください。", "AI Server", "OK", "Warning") | Out-Null
        }
    }

    if ($null -eq $pgSuperPassword) {
        Write-Error "PostgreSQL の postgres スーパーユーザーに接続できません。pg_hba.conf を確認するか、postgres ユーザーのパスワードをリセットしてから再実行してください"
    }

    $env:PGPASSWORD = $pgSuperPassword
    Write-Success "PostgreSQL 管理者認証 OK"

    $roleExists = psql -U postgres -p $DB_PORT -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>$null
    if (("$roleExists").Trim() -ne "1") {
        $createUserOut = psql -U postgres -p $DB_PORT -c "CREATE USER `"$DB_USER`" WITH PASSWORD '$DB_PASSWORD';" 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warn "ユーザー作成に失敗しました (続行します): $createUserOut" }
    }
    $dbExists = psql -U postgres -p $DB_PORT -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>$null
    if (("$dbExists").Trim() -ne "1") {
        $createDbOut = psql -U postgres -p $DB_PORT -c "CREATE DATABASE `"$DB_NAME`" OWNER `"$DB_USER`";" 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warn "DB 作成に失敗しました (続行します): $createDbOut" }
    }
    $null = psql -U postgres -p $DB_PORT -c "ALTER USER `"$DB_USER`" CREATEDB;" 2>&1
    }


    if ($dbProvisioned) { $env:PGPASSWORD = $DB_PASSWORD; $extUser = $DB_USER } else { $env:PGPASSWORD = $pgSuperPassword; $extUser = "postgres" }
    $extensionOut = psql -U $extUser -p $DB_PORT -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "pgvector 拡張が無効のため RAG (ベクトル検索) は無効化されます (= DLL 未配置 / 権限不足)"
    } else {
        Write-Success "pgvector 拡張 有効"
    }

    if (-not $dbProvisioned) {
    $reassignSql = @"
DO `$`$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname, tablename FROM pg_tables
           WHERE schemaname NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', r.schemaname, r.tablename, '$DB_USER');
  END LOOP;
  FOR r IN SELECT sequence_schema, sequence_name FROM information_schema.sequences
           WHERE sequence_schema NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', r.sequence_schema, r.sequence_name, '$DB_USER');
  END LOOP;
END `$`$;
"@
    $null = $reassignSql | psql -U postgres -p $DB_PORT -d $DB_NAME 2>$null
    }

    $ErrorActionPreference = "Stop"


    Write-Info "スキーマ / テーブル / 初期 admin user は backend 起動時に自動作成されます"
} else {
    Write-Warn "PostgreSQL がインストールされていないため、データベースセットアップをスキップしました"
}

# ============================================================
# ============================================================
Write-Info "ステップ 4/5: Ollama をセットアップ中..."

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    $ctxLen = "16384"  # default
    if (Test-Path "$INSTALL_DIR\.env") {
        $line = Get-Content "$INSTALL_DIR\.env" | Where-Object { $_ -match '^OLLAMA_CONTEXT_LENGTH=' } | Select-Object -First 1
        if ($line) { $ctxLen = $line -replace '^OLLAMA_CONTEXT_LENGTH=', '' }
    }
    [Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", $ctxLen, "User")
    $env:OLLAMA_CONTEXT_LENGTH = $ctxLen

    $ollamaProcess = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if (-not $ollamaProcess) {
        Write-Info "Ollama を起動中 (OLLAMA_CONTEXT_LENGTH=$ctxLen)..."
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    } else {
        Write-Info "Ollama は既に起動中。OLLAMA_CONTEXT_LENGTH 反映には再起動が必要です。"
    }

}

# ============================================================
# ============================================================
Write-Info "ステップ 5/5: 設定を作成中..."

if (-not (Test-Path "$INSTALL_DIR\.env")) {
    $JWT_SECRET = -join ((48..57) + (97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
    $ENV_CONTENT = @"
LLM_BACKEND=ollama
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${DB_PORT}/${DB_NAME}
JWT_SECRET=$JWT_SECRET
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_AUTO_START=true
LICENSE_FILE_PATH=$INSTALL_DIR\license.lic
FILES_DIR=$INSTALL_DIR\files
"@
    Set-Content -Path "$INSTALL_DIR\.env" -Value $ENV_CONTENT -Encoding UTF8
    Write-Success ".env ファイルを作成しました"
} else {
    Write-Info ".env ファイルは既存のため、スキップしました"
}

$START_SCRIPT = @'
$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Set-Location $INSTALL_DIR

if (Test-Path "$INSTALL_DIR\.env") {
    Get-Content "$INSTALL_DIR\.env" | ForEach-Object {
        if ($_ -match "^([^#][^=]+)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
        }
    }
}

if (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe") {
    $env:PATH = "C:\Program Files\Tesseract-OCR;$env:PATH"
    $env:TESSDATA_PREFIX = "C:\Program Files\Tesseract-OCR\tessdata"
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*-full_build\bin",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*\bin",
        "C:\ProgramData\chocolatey\lib\ffmpeg\tools\ffmpeg\bin",
        "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin"
    ) | ForEach-Object {
        $p = Resolve-Path -Path $_ -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and (Test-Path "$($p.Path)\ffmpeg.exe")) { $env:PATH = "$($p.Path);$env:PATH"; return }
    }
}

Write-Host "AI Server を起動中..." -ForegroundColor Blue

$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService -and $pgService.Status -ne "Running") {
    Write-Host "PostgreSQL を起動中..."
    Start-Service $pgService.Name
    Start-Sleep -Seconds 2
}

if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Write-Host "Ollama を起動中..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force
Start-Sleep -Seconds 1

if (-not $env:API_PORT) { $env:API_PORT = "8000" }

Write-Host "API を起動中..."
$apiProcess = Start-Process -FilePath "$INSTALL_DIR\api.exe" -WorkingDirectory $INSTALL_DIR -NoNewWindow -PassThru
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "AI Server が起動しました！" -ForegroundColor Green
Write-Host ""
Write-Host "  http://localhost:$($env:API_PORT)" -ForegroundColor Cyan

$lanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1).IPAddress
if ($lanIp) { Write-Host "  LAN:  http://${lanIp}:$($env:API_PORT)" -ForegroundColor Cyan }

$mdnsName = "$([System.Net.Dns]::GetHostName()).local"
Write-Host "  mDNS: http://${mdnsName}:$($env:API_PORT)" -ForegroundColor Cyan

Write-Host ""
Write-Host "  Ctrl+C で停止" -ForegroundColor Yellow
Write-Host ""

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
}

try {
    Wait-Process -Id $apiProcess.Id -ErrorAction SilentlyContinue
} finally {
    Write-Host "Stopped"
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
}
'@

Set-Content -Path "$INSTALL_DIR\start.ps1" -Value $START_SCRIPT -Encoding UTF8

$STOP_SCRIPT = @'
Write-Host "AI Server を停止中..."

Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force

Write-Host "AI Server を停止しました" -ForegroundColor Green
'@

Set-Content -Path "$INSTALL_DIR\stop.ps1" -Value $STOP_SCRIPT -Encoding UTF8

$TOGGLE_SCRIPT = @'

$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Set-Location $INSTALL_DIR

$API_PORT = 8000
if (Test-Path "$INSTALL_DIR\.env") {
    Get-Content "$INSTALL_DIR\.env" | ForEach-Object {
        if ($_ -match "^API_PORT=(.*)$") { $API_PORT = $matches[1] }
    }
}

$isRunning = $false
try {
    $response = Invoke-WebRequest -Uri "http://localhost:$API_PORT/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    $isRunning = $true
} catch { }

if ($isRunning) {
    & "$INSTALL_DIR\stop.ps1"

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText01
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
    $xml.GetElementsByTagName("text").Item(0).AppendChild($xml.CreateTextNode("AI Server stopped")) | Out-Null
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("AI Server")
    $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} else {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$INSTALL_DIR\start.ps1`"" -WindowStyle Hidden

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$API_PORT/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            $ready = $true
            break
        } catch { }
    }

    if ($ready) {
        Start-Sleep -Seconds 1
        Start-Process "http://localhost:$API_PORT"

        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText01
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
        $xml.GetElementsByTagName("text").Item(0).AppendChild($xml.CreateTextNode("AI Server is running")) | Out-Null
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("AI Server")
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } else {
        [System.Windows.MessageBox]::Show("Failed to start. Check $INSTALL_DIR\logs\", "AI Server")
    }
}
'@

Set-Content -Path "$INSTALL_DIR\toggle.ps1" -Value $TOGGLE_SCRIPT -Encoding UTF8

Write-Host ""
Write-Host "AI Server のインストールが完了しました" -ForegroundColor Green
Write-Host ""

if ($MISSING_DEPS -contains "tesseract") {
    Write-Host ""
    Write-Warn "Tesseract OCR が未導入です (オプション: 画像OCR用)。必要なら setup-windows.ps1 で導入できます。"
    Write-Host ""
}

# Create db.bat CLI
$BAT_CONTENT = @"
@echo off
if "%1"=="start" powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\db\start.ps1"
if "%1"=="stop" powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\db\stop.ps1"
if "%1"=="" echo Usage: db {start^|stop}
"@
Set-Content -Path "$INSTALL_DIR\db.bat" -Value $BAT_CONTENT -Encoding ASCII

# Add to PATH if not already present
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$INSTALL_DIR*") {
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$INSTALL_DIR", "User")
    $env:Path = "$env:Path;$INSTALL_DIR"
    Write-Success "PATH に追加しました"
}
Write-Host ""
Write-Host "起動: db start" -ForegroundColor Blue
Write-Host "停止: db stop" -ForegroundColor Blue
Write-Host "  または" -ForegroundColor Gray
Write-Host "起動: powershell -ExecutionPolicy Bypass -File `"$INSTALL_DIR\start.ps1`"" -ForegroundColor Blue
Write-Host "停止: powershell -ExecutionPolicy Bypass -File `"$INSTALL_DIR\stop.ps1`"" -ForegroundColor Blue
Write-Host ""
Write-Host "URL:      http://localhost:8000" -ForegroundColor Blue
Write-Host ""
Write-Host "============================================================"
Write-Host "  ライセンス設定"
Write-Host "============================================================"
Write-Host ""
Write-Host "  ライセンスファイルを以下に配置してください:"
Write-Host "    $INSTALL_DIR\license.lic"
Write-Host ""
