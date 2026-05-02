<#
AI Server post-install script.

Run by the Inno Setup wizard after the backend EXE has been copied
to {app}\api.exe. Brings up the rest of the stack:

  1. winget install PostgreSQL (if not already installed)
  2. winget install Ollama (if not already installed)
  3. Download pgvector DLL into PG's lib/extension dirs
  4. Start PostgreSQL service
  5. Create digitalbase DB / user, enable pgvector extension
  6. Apply DDL via the embedded inline schema
  7. Start `ollama serve` in the background
  8. Write %LOCALAPPDATA%\db\.env

Idempotent — safe to re-run. Used by the EXE installer; the legacy
`irm | iex` flow continues to use install-windows.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallDir,
    [string] $DbUser     = "digitalbase",
    [string] $DbPassword = "digitalbase",
    [string] $DbName     = "digitalbase"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Info    { param($msg) Write-Host "[情報] $msg" -ForegroundColor Blue }
function Write-Success { param($msg) Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[警告] $msg" -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "[エラー] $msg" -ForegroundColor Red }

$logFile = Join-Path $InstallDir "post-install.log"
Start-Transcript -Path $logFile -Append | Out-Null

Write-Info "AI Server post-install を開始します"
Write-Info "InstallDir: $InstallDir"


# ─── 1. winget で PostgreSQL / Ollama をインストール ─────────────────

# Existing .env wins over the defaults so re-runs preserve any custom
# credentials the user already set.
$envPath = Join-Path $InstallDir ".env"
if (Test-Path $envPath) {
    $dbUrlLine = Get-Content $envPath | Where-Object { $_ -match "^DATABASE_URL=" } | Select-Object -First 1
    if ($dbUrlLine -match "^DATABASE_URL=postgresql://([^:]+):([^@]+)@[^/]+/([^?]+)") {
        $DbUser     = $matches[1]
        $DbPassword = $matches[2]
        $DbName     = $matches[3]
        Write-Info "既存 .env から DB 設定を引き継ぎ: user=$DbUser db=$DbName"
    }
}

function Ensure-WingetPackage {
    param([string]$Id, [string]$DisplayName, [string]$Probe, [bool]$Required = $true)
    if ($Probe -and (Get-Command $Probe -ErrorAction SilentlyContinue)) {
        Write-Success "$DisplayName 既にインストール済み"
        return $true
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        if ($Required) {
            Write-Err "winget が見つかりません。$DisplayName を手動でインストールしてください: $Id"
            return $false
        }
        Write-Warn "winget が見つかりません。$DisplayName を手動でインストールしてください: $Id"
        return $false
    }
    Write-Info "$DisplayName をインストール中... (数分かかる場合があります)"
    # Capture output so failure modes (e.g. UAC denied, network blocked,
    # already installed under a different ID) can be surfaced rather
    # than swallowed. winget's exit codes:
    #   0           = success
    #   -1978335189 = no applicable upgrade
    #   0x8A150010  = no installer for this architecture
    $wingetOutput = & winget install -e --id $Id --silent `
        --accept-package-agreements --accept-source-agreements 2>&1
    $wingetExit = $LASTEXITCODE
    if ($wingetExit -eq 0) {
        Write-Success "$DisplayName をインストールしました"
        # Refresh PATH so subsequent Get-Command picks up the new exe in
        # this same session — winget updates the registry but the
        # current process keeps its old PATH snapshot.
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path", "User")
        return $true
    } else {
        Write-Err "$DisplayName のインストールに失敗 (winget exit=$wingetExit)"
        Write-Err ($wingetOutput | Out-String).TrimEnd()
        if ($Required) {
            Write-Err "$DisplayName は必須です。インストーラーを管理者として再実行してください"
        }
        return $false
    }
}

$pgInstalled     = Ensure-WingetPackage -Id "PostgreSQL.PostgreSQL" -DisplayName "PostgreSQL" -Probe "psql"   -Required $true
$ollamaInstalled = Ensure-WingetPackage -Id "Ollama.Ollama"         -DisplayName "Ollama"     -Probe "ollama" -Required $false

if (-not $pgInstalled) {
    Write-Err "PostgreSQL が利用できないため post-install を中断します"
    Stop-Transcript | Out-Null
    exit 1
}


# ─── 2. PostgreSQL 起動 + DB / user 作成 ─────────────────────────────

# Pick whichever PG service the installer registered. PG installs by
# major version so the service name is `postgresql-x64-{NN}`.
$pgService = Get-Service "postgresql-x64-*" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $pgService) {
    Write-Err "PostgreSQL サービスが見つかりません。winget インストールが完了していない可能性があります"
    Stop-Transcript | Out-Null
    exit 1
}

if ($pgService.Status -ne "Running") {
    Write-Info "PostgreSQL サービスを起動中: $($pgService.Name)"
    try {
        Start-Service $pgService.Name -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-Err "PostgreSQL サービスの起動に失敗しました: $_"
        Write-Err "管理者として再実行するか、サービスマネージャーから手動で '$($pgService.Name)' を起動してください"
        Stop-Transcript | Out-Null
        exit 1
    }
}

# Resolve psql.exe path. winget installs PG to a versioned dir under
# C:\Program Files\PostgreSQL\NN\bin — pick the highest version.
$pgRoot = Get-ChildItem "C:\Program Files\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $pgRoot) { Write-Err "PostgreSQL のインストールディレクトリを検出できませんでした"; Stop-Transcript | Out-Null; exit 1 }
$psql    = Join-Path $pgRoot.FullName "bin\psql.exe"
$pgMajor = $pgRoot.Name


# ─── 3. pgvector DLL の配置 ──────────────────────────────────────────

$vectorDll = Join-Path $pgRoot.FullName "lib\vector.dll"
if (-not (Test-Path $vectorDll)) {
    Write-Info "pgvector DLL を取得中..."
    try {
        $apiUrl = "https://api.github.com/repos/lmlight-app/dist_vite/releases"
        $headers = @{ "User-Agent" = "AI-Server-Installer" }
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        $asset = $releases | ForEach-Object { $_.assets } | Where-Object {
            $_.name -like "pgvector-pg$pgMajor-*.zip"
        } | Select-Object -First 1
        if (-not $asset) {
            throw "PostgreSQL $pgMajor 用の pgvector アセットが見つかりません"
        }
        $zip   = Join-Path $env:TEMP "pgvector.zip"
        $extr  = Join-Path $env:TEMP "pgvector_extract"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $extr -Force
        # Writes go to C:\Program Files\PostgreSQL\NN\lib (and \share\extension)
        # which is admin-only. Surface the failure instead of swallowing
        # it — silent failure here means RAG is dead but the installer
        # claims success.
        Get-ChildItem -Path $extr -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($extr.Length).TrimStart('\')
            $dst = Join-Path $pgRoot.FullName $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -Force $_.FullName $dst -ErrorAction Stop
        }
        Remove-Item $zip, $extr -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "pgvector をインストールしました"
    } catch [System.UnauthorizedAccessException] {
        Write-Err "pgvector DLL の配置に失敗 (Access Denied): $_"
        Write-Err "$($pgRoot.FullName)\lib への書き込み権限がありません。管理者として再実行してください"
        Stop-Transcript | Out-Null
        exit 1
    } catch {
        Write-Warn "pgvector の取得に失敗しました: $_"
        Write-Warn "AI Server は起動しますが、ベクトル検索機能 (RAG) は無効化されます"
    }
}


# ─── 4. DB / user 作成 + DDL 適用 ────────────────────────────────────

# PG super-user password handling:
# The PG Windows installer forces the user to set a password during
# install — it is NOT predictably "postgres". We try a few common
# defaults; if none work, prompt interactively (Inno Setup runs the
# script with a console attached when not /silent).
function Test-PgSuperPassword {
    param([string]$Password)
    $env:PGPASSWORD = $Password
    $null = & $psql -U postgres -d postgres -h localhost -p 5432 -tAc "SELECT 1" 2>&1
    return ($LASTEXITCODE -eq 0)
}

$pgSuperPassword = $null
$candidates = @("postgres", $DbPassword, "")  # "" = trust auth (rare on Windows)
foreach ($candidate in $candidates) {
    if (Test-PgSuperPassword -Password $candidate) {
        $pgSuperPassword = $candidate
        Write-Info "PostgreSQL 管理者認証 OK"
        break
    }
}

if ($null -eq $pgSuperPassword) {
    Write-Warn "postgres スーパーユーザーへの自動接続に失敗しました"
    # Inno Setup runs us with `runhidden` so Read-Host has nowhere to go.
    # Pop a Windows Forms password dialog so the user can supply the
    # password they set when PG was first installed.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    function Show-PasswordPrompt {
        param([string]$Message)
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "PostgreSQL 管理者パスワード"
        $form.Size = New-Object System.Drawing.Size(420, 180)
        $form.StartPosition = "CenterScreen"
        $form.Topmost = $true
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Message
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
        $form.Controls.Add($okButton)
        $form.AcceptButton = $okButton

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = "キャンセル"
        $cancelButton.Location = New-Object System.Drawing.Point(312, 100)
        $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
        $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($cancelButton)
        $form.CancelButton = $cancelButton

        $form.Add_Shown({ $textBox.Focus() | Out-Null })
        $result = $form.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return $textBox.Text
        }
        return $null
    }

    for ($i = 1; $i -le 3; $i++) {
        $msg = "PostgreSQL インストール時に設定した postgres ユーザーのパスワードを入力してください (試行 $i/3)"
        $plain = Show-PasswordPrompt -Message $msg
        if ($null -eq $plain) {
            Write-Err "ユーザーがパスワード入力をキャンセルしました"
            break
        }
        if (Test-PgSuperPassword -Password $plain) {
            $pgSuperPassword = $plain
            Write-Info "PostgreSQL 管理者認証 OK"
            break
        }
        [System.Windows.Forms.MessageBox]::Show("認証失敗。再入力してください。", "AI Server", "OK", "Warning") | Out-Null
    }
}

if ($null -eq $pgSuperPassword) {
    Write-Err "PostgreSQL の postgres スーパーユーザーに接続できません"
    Write-Err "pg_hba.conf を確認するか、postgres ユーザーのパスワードをリセットしてから再実行してください"
    Stop-Transcript | Out-Null
    exit 1
}

$env:PGPASSWORD = $pgSuperPassword

# Create role + DB (idempotent via IF NOT EXISTS shape).
$bootstrap = @"
DO `$`$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$DbUser') THEN
        CREATE ROLE "$DbUser" LOGIN PASSWORD '$DbPassword' CREATEDB SUPERUSER;
    END IF;
END `$`$;
"@
$bootstrapOutput = $bootstrap | & $psql -U postgres -d postgres -h localhost -p 5432 -v ON_ERROR_STOP=1 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "ロール作成に失敗: $($bootstrapOutput | Out-String)"
    Stop-Transcript | Out-Null
    exit 1
}

# CREATE DATABASE doesn't fit in a DO block — check first.
$dbExists = & $psql -U postgres -d postgres -h localhost -p 5432 -tAc `
    "SELECT 1 FROM pg_database WHERE datname='$DbName'" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "DB 存在確認に失敗: $dbExists"
    Stop-Transcript | Out-Null
    exit 1
}
if ($dbExists -ne "1") {
    $createDbOutput = & $psql -U postgres -d postgres -h localhost -p 5432 -c "CREATE DATABASE `"$DbName`" OWNER `"$DbUser`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "DB 作成に失敗: $($createDbOutput | Out-String)"
        Stop-Transcript | Out-Null
        exit 1
    }
}

# Enable pgvector. The full DDL sweep happens at backend startup via
# SQLAlchemy create_all() + the legacy _add_missing_columns list, so we
# just need the DB itself + the extension here.
$extOutput = & $psql -U postgres -d $DbName -h localhost -p 5432 `
    -c "CREATE EXTENSION IF NOT EXISTS vector" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "pgvector 拡張の有効化に失敗: $($extOutput | Out-String)"
    Write-Warn "RAG (ベクトル検索) は無効化されます"
} else {
    Write-Success "PostgreSQL DB / user / pgvector をセットアップしました"
}


# ─── 5. .env 生成 (既存があればスキップ) ─────────────────────────────

if (-not (Test-Path $envPath)) {
    $jwtSecret = -join ((48..57) + (97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
    $env_content = @"
# AI Server configuration
DATABASE_URL=postgresql://${DbUser}:${DbPassword}@localhost:5432/${DbName}
OLLAMA_BASE_URL=http://localhost:11434
LICENSE_FILE_PATH=$InstallDir\license.lic

FILES_DIR=$InstallDir\files

API_HOST=0.0.0.0
API_PORT=8000

JWT_SECRET=$jwtSecret
JWT_EXPIRE_DAYS=365

AUTH_MODE=local
"@
    Set-Content -Path $envPath -Value $env_content -Encoding UTF8
    Write-Success ".env を生成しました"
} else {
    Write-Info ".env は既存のものを維持します"
}


# ─── 6. Ollama serve をバックグラウンド起動 ─────────────────────────

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
        Write-Info "Ollama を起動中..."
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    Write-Success "Ollama 起動済み (モデルは初回チャット時に手動で `ollama pull <name>` で取得してください)"
}


# ─── 7. CLI launcher (`db start` / `db stop`) ───────────────────────
#
# Mirrors what install-windows.ps1 does at the tail end: drop a tiny
# .bat into $InstallDir that PowerShell-launches start/stop scripts,
# then add $InstallDir to the user PATH so `db start` is callable
# from any shell (cmd / pwsh) anywhere.

$startPs1 = Join-Path $InstallDir "start.ps1"
$stopPs1  = Join-Path $InstallDir "stop.ps1"
$dbBat    = Join-Path $InstallDir "db.bat"

# start.ps1 — bring up PG service + Ollama serve + api.exe.
# Mirrors the legacy install-windows.ps1 launcher. Trimmed to the
# essentials; PG / Ollama detect-and-start, then exec api.exe and
# wait. Ctrl+C in the terminal stops the api process.
$startScript = @'
$ErrorActionPreference = "Stop"
$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Set-Location $INSTALL_DIR

# Load .env
if (Test-Path "$INSTALL_DIR\.env") {
    Get-Content "$INSTALL_DIR\.env" | ForEach-Object {
        if ($_ -match "^([^#=]+)=(.*)$") {
            [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
        }
    }
}

Write-Host "AI Server を起動中..." -ForegroundColor Blue

$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService -and $pgService.Status -ne "Running") {
    Start-Service $pgService.Name
    Start-Sleep -Seconds 2
}

if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

if (-not $env:API_PORT) { $env:API_PORT = "8000" }
$apiProcess = Start-Process -FilePath "$INSTALL_DIR\api.exe" -WorkingDirectory $INSTALL_DIR -NoNewWindow -PassThru
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "  http://localhost:$($env:API_PORT)" -ForegroundColor Cyan
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1).IPAddress
if ($lanIp) { Write-Host "  LAN:  http://${lanIp}:$($env:API_PORT)" -ForegroundColor Cyan }
Write-Host "  Ctrl+C で停止" -ForegroundColor Yellow
Write-Host ""

try {
    Wait-Process -Id $apiProcess.Id -ErrorAction SilentlyContinue
} finally {
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
}
'@

$stopScript = @'
$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Get-Process -Name "api" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*\db\*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "AI Server を停止しました" -ForegroundColor Green
'@

$batScript = @"
@echo off
if "%1"=="start" powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\db\start.ps1"
if "%1"=="stop"  powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\db\stop.ps1"
if "%1"==""      echo Usage: db {start^|stop}
"@

Set-Content -Path $startPs1 -Value $startScript -Encoding UTF8
Set-Content -Path $stopPs1  -Value $stopScript  -Encoding UTF8
Set-Content -Path $dbBat    -Value $batScript   -Encoding ASCII

# Add InstallDir to user PATH so `db start` works from any shell.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    Write-Success "PATH に '$InstallDir' を追加しました — 新しいターミナルから `db start` が使えます"
}

Write-Success "AI Server の post-install が完了しました"
Stop-Transcript | Out-Null
