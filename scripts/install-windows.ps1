# AI Server インストーラー for Windows (Vite Edition)
# 使い方: irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex

$ErrorActionPreference = "Stop"

# TLS 1.2 フォールバック (Windows PowerShell 5.1 は既定で TLS 1.0/1.1。aka.ms / api.github.com は TLS 1.2+ 必須)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================================================
# 管理者権限チェック + 自動昇格
# ============================================================
# winget による PostgreSQL/Ollama インストール、`Start-Service postgresql-x64-NN`、
# C:\Program Files\PostgreSQL\NN\lib への vector.dll 配置はすべて
# 管理者権限が必要。非 admin で実行されたら UAC で再起動して新しい
# admin ウィンドウで継続させる (irm | iex 形式は in-memory なので
# スクリプト URL を改めて再 fetch する形)。
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $relaunchUrl = if ($env:DB_INSTALLER_URL) { $env:DB_INSTALLER_URL } else { "https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1" }
    Write-Host ""
    Write-Host "管理者権限が必要です。UAC ダイアログで「はい」を選択してください..." -ForegroundColor Yellow
    Write-Host "新しい管理者ウィンドウでインストールが続行されます。" -ForegroundColor Yellow
    Write-Host ""
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", "irm $relaunchUrl | iex; Read-Host '完了しました。Enter キーで閉じる'"
        ) -ErrorAction Stop
    } catch {
        Write-Host "[エラー] 管理者権限への昇格がキャンセルされました" -ForegroundColor Red
        Write-Host "PowerShell を「管理者として実行」で開き直して再度お試しください" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# 設定
$BASE_URL = if ($env:DB_BASE_URL) { $env:DB_BASE_URL } else { "https://github.com/lmlight-app/dist_vite/releases/latest/download" }
$INSTALL_DIR = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$ARCH = "amd64"  # Windows は x64 のみサポート

# データベース設定 (デフォルト値、.env があればそちらを優先)
$DB_USER = "digitalbase"
$DB_PASSWORD = "digitalbase"
$DB_NAME = "digitalbase"

# 既存 .env から DATABASE_URL を読み取り (アップデート時にカスタム設定を反映)
if (Test-Path "$INSTALL_DIR\.env") {
    $dbUrlLine = Get-Content "$INSTALL_DIR\.env" | Where-Object { $_ -match "^DATABASE_URL=" } | Select-Object -First 1
    if ($dbUrlLine -match "^DATABASE_URL=postgresql://([^:]+):([^@]+)@[^/]+/([^?]+)") {
        $DB_USER = $matches[1]
        $DB_PASSWORD = $matches[2]
        $DB_NAME = $matches[3]
    }
}

# カラー定義（PowerShell）
function Write-Info { param($msg) Write-Host "[情報] $msg" -ForegroundColor Blue }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Error { param($msg) Write-Host "[エラー] $msg" -ForegroundColor Red; exit 1 }
function Write-Warn { param($msg) Write-Host "[警告] $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "║      AI Server インストーラー for Windows             ║" -ForegroundColor Blue
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

Write-Info "アーキテクチャ: $ARCH"
Write-Info "インストール先: $INSTALL_DIR"

# ディレクトリ作成
New-Item -ItemType Directory -Force -Path "$INSTALL_DIR" | Out-Null
New-Item -ItemType Directory -Force -Path "$INSTALL_DIR\logs" | Out-Null

# 既存インストールチェック
if (Test-Path "$INSTALL_DIR\api.exe") {
    Write-Info "既存のインストールを検出しました。アップデート中..."

    # 既存プロセス停止
    Write-Info "既存のプロセスを停止中..."
    Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Success "既存のプロセスを停止しました"
}

# ============================================================
# ステップ 1: バイナリダウンロード
# ============================================================
Write-Info "ステップ 1/5: バイナリをダウンロード中..."

$BACKEND_FILE = "lmlight-vite-windows-$ARCH.exe"
Write-Info "バイナリをダウンロード中... ($BACKEND_FILE)"
Invoke-WebRequest -Uri "$BASE_URL/$BACKEND_FILE" -OutFile "$INSTALL_DIR\api.exe" -UseBasicParsing
Write-Success "バイナリをダウンロードしました"

# ============================================================
# ステップ 2: 依存関係チェック
# ============================================================
Write-Info "ステップ 2/5: 依存関係をチェック中..."

$MISSING_DEPS = @()

# PostgreSQL チェック
if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Success "PostgreSQL が見つかりました"
} else {
    Write-Warn "PostgreSQL が見つかりません"
    $MISSING_DEPS += "postgresql"
}

# Ollama チェック
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Success "Ollama が見つかりました"
} else {
    Write-Warn "Ollama が見つかりません"
    $MISSING_DEPS += "ollama"
}

# Tesseract OCR チェック (オプション: 画像OCR用)
if ((Get-Command tesseract -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe")) {
    Write-Success "Tesseract OCR が見つかりました (画像OCR用)"
} else {
    Write-Warn "Tesseract OCR 未接続 (オプション: 画像OCR用)"
    $MISSING_DEPS += "tesseract"
}

# winget で依存関係をインストール (常に admin で実行されているのでガード不要)
if ($MISSING_DEPS.Count -gt 0) {
    Write-Info "不足している依存関係を自動インストールしますか？ (Y/n)"
    $response = Read-Host
    if ($response -eq "" -or $response -eq "Y" -or $response -eq "y") {
        foreach ($dep in $MISSING_DEPS) {
            switch ($dep) {
                "postgresql" {
                    Write-Info "PostgreSQL をインストール中..."
                    winget install -e --id PostgreSQL.PostgreSQL --silent --accept-package-agreements --accept-source-agreements
                }
                "ollama" {
                    Write-Info "Ollama をインストール中..."
                    $null = winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Success "Ollama をインストールしました"
                    }
                }
                "tesseract" {
                    Write-Info "Tesseract OCR をインストール中..."
                    Write-Warn "Tesseract は手動インストールが必要です: https://github.com/UB-Mannheim/tesseract/wiki"
                }
            }
        }
    }
}

# ============================================================
# ステップ 3: PostgreSQL セットアップ
# ============================================================
Write-Info "ステップ 3/5: PostgreSQL をセットアップ中..."

# PostgreSQL ポート検出
$DB_PORT = "5432"

if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Info "データベースを作成中..."

    # PostgreSQL サービス起動
    $pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pgService -and $pgService.Status -ne "Running") {
        try {
            Start-Service $pgService.Name -ErrorAction Stop
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "PostgreSQL サービスの起動に失敗しました: $_`nサービス '$($pgService.Name)' を手動で起動してから再実行してください"
        }
    }

    # ポート検出 + postgres スーパーユーザーパスワード判定
    # PG の Windows インストーラはパスワード設定を強制するので "postgres"
    # は予測値ではない。候補を順に試して、全部だめなら GUI で聞く。
    $ErrorActionPreference = "Continue"

    function Test-PgConnect {
        param([string]$Password, [string]$Port)
        $env:PGPASSWORD = $Password
        $null = psql -U postgres -p $Port -c "SELECT 1" 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    # まずポート決定 (5432 → 5433)。認証は別途解決するので、ここでは
    # libpq が「password authentication failed」を返してくれれば
    # ポート自体は届いていると判断する。
    function Test-PgPort {
        param([string]$Port)
        $env:PGPASSWORD = "__probe_invalid__"
        $output = psql -U postgres -p $Port -c "SELECT 1" 2>&1
        # exit 0 = trust auth で通った / exit 2 = password auth failed (= ポート生きてる)
        # exit 1 + "could not connect" = ポート死んでる
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($output -match "password authentication failed|fe_sendauth|no password supplied") { return $true }
        return $false
    }

    if (Test-PgPort -Port "5432") {
        $DB_PORT = "5432"
    } elseif (Test-PgPort -Port "5433") {
        $DB_PORT = "5433"
    } else {
        Write-Error "PostgreSQL に接続できません (5432/5433 とも応答なし)。サービスが起動しているか確認してください"
    }
    Write-Info "PostgreSQL ポート: $DB_PORT"

    # postgres パスワード解決
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

    # データベースとユーザー作成 — エラー出力をキャプチャして失敗を可視化
    # (ロール/DB が既存の場合のエラーメッセージはログ目的で出力)
    $createUserOut = psql -U postgres -p $DB_PORT -c "CREATE USER `"$DB_USER`" WITH PASSWORD '$DB_PASSWORD';" 2>&1
    if ($LASTEXITCODE -ne 0 -and $createUserOut -notmatch "already exists") {
        Write-Error "ユーザー作成失敗: $createUserOut"
    }
    $createDbOut = psql -U postgres -p $DB_PORT -c "CREATE DATABASE `"$DB_NAME`" OWNER `"$DB_USER`";" 2>&1
    if ($LASTEXITCODE -ne 0 -and $createDbOut -notmatch "already exists") {
        Write-Error "DB 作成失敗: $createDbOut"
    }
    $null = psql -U postgres -p $DB_PORT -c "ALTER USER `"$DB_USER`" CREATEDB;" 2>&1

    # pgvector拡張 - 自動インストール
    # PostgreSQL インストールパスを検出
    $PG_DIR = $null
    $pgVersions = @("18", "17", "16", "15", "14")
    foreach ($v in $pgVersions) {
        $candidate = "C:\Program Files\PostgreSQL\$v"
        if (Test-Path "$candidate\bin\psql.exe") {
            $PG_DIR = $candidate
            break
        }
    }

    # vector.dll が未配置なら自動ダウンロード
    if ($PG_DIR -and -not (Test-Path "$PG_DIR\lib\vector.dll")) {
        # pgvector DLL は VC++ 2015-2022 Redistributable (msvcp140.dll) に依存
        if (-not (Test-Path "C:\Windows\System32\msvcp140.dll")) {
            Write-Info "VC++ Redistributable が未インストールです。追加中..."
            $vcRedist = "$env:TEMP\vc_redist.x64.exe"
            try {
                Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcRedist -UseBasicParsing
                Start-Process -FilePath $vcRedist -ArgumentList "/install","/quiet","/norestart" -Wait
                Remove-Item -Force $vcRedist -ErrorAction SilentlyContinue
                Write-Success "VC++ Redistributable をインストールしました"
            } catch {
                Write-Warn "VC++ Redistributable の自動インストールに失敗しました。手動で https://aka.ms/vs/17/release/vc_redist.x64.exe を導入してください"
            }
        }

        Write-Info "pgvector をインストール中..."
        $pgMajor = (Split-Path $PG_DIR -Leaf)
        $pgvectorZip = "$env:TEMP\pgvector.zip"
        $pgvectorExtract = "$env:TEMP\pgvector_extract"

        try {
            # GitHub API で PG メジャー版に合う最新リリースを解決
            # (releases/latest は単一PG版のみを指すため、全PG版用の資産は入っていない)
            $apiUrl = "https://api.github.com/repos/andreiramani/pgvector_pgsql_windows/releases"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ "User-Agent" = "lmlight-installer" }
            $match = $releases | Where-Object { $_.tag_name -match "_${pgMajor}(\.|$)" } | Select-Object -First 1
            if (-not $match -or $match.assets.Count -eq 0) {
                throw "PostgreSQL $pgMajor 用の pgvector リリースが見つかりません"
            }
            $pgvectorUrl = $match.assets[0].browser_download_url

            Invoke-WebRequest -Uri $pgvectorUrl -OutFile $pgvectorZip -UseBasicParsing
            if (Test-Path $pgvectorExtract) { Remove-Item -Recurse -Force $pgvectorExtract }
            Expand-Archive -Path $pgvectorZip -DestinationPath $pgvectorExtract -Force

            # DLL とコントロールファイルを配置 — Program Files 配下なので
            # admin 権限がないと Access Denied。-ErrorAction Stop で
            # 失敗を catch に飛ばす。
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector.dll" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\lib\vector.dll" -Force -ErrorAction Stop
            }
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector.control" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\share\extension\vector.control" -Force -ErrorAction Stop
            }
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector--*.sql" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\share\extension\$($_.Name)" -Force -ErrorAction Stop
            }

            # クリーンアップ
            Remove-Item -Force $pgvectorZip -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $pgvectorExtract -ErrorAction SilentlyContinue

            Write-Success "pgvector をインストールしました (タグ: $($match.tag_name))"
        } catch [System.UnauthorizedAccessException] {
            Write-Error "pgvector DLL の配置に失敗 (Access Denied): $($_.Exception.Message)`n$PG_DIR\lib への書き込み権限がありません。管理者として PowerShell を開き直して再実行してください"
        } catch {
            Write-Warn "pgvector の自動インストールに失敗しました: $($_.Exception.Message)"
            Write-Warn "RAG (ベクトル検索) は無効化されます。手動インストール: https://github.com/andreiramani/pgvector_pgsql_windows/releases"
        }
    } elseif ($PG_DIR) {
        Write-Success "pgvector は既にインストール済みです"
    }

    $extensionOut = psql -U postgres -p $DB_PORT -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "pgvector 拡張の有効化に失敗: $extensionOut"
        Write-Warn "RAG (ベクトル検索) は無効化されます"
    }

    $ErrorActionPreference = "Stop"


    # ── DDL は backend 起動時の migrations.py が冪等に作成する ──
    # (= 旧 raw SQL ブロック ~540 行は撤去済み。schema / table / index /
    #  column 追加 / 初期 admin user は全部 Python 側が担当)
    Write-Info "スキーマ / テーブル / 初期 admin user は backend 起動時に自動作成されます"
} else {
    Write-Warn "PostgreSQL がインストールされていないため、データベースセットアップをスキップしました"
}

# ============================================================
# ステップ 4: Ollama セットアップ
# ============================================================
Write-Info "ステップ 4/5: Ollama をセットアップ中..."

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    # .env の OLLAMA_CONTEXT_LENGTH を Windows User scope env に setx
    # (= Ollama Desktop 起動時に env 継承するため)
    $ctxLen = "16384"  # default
    if (Test-Path "$INSTALL_DIR\.env") {
        $line = Get-Content "$INSTALL_DIR\.env" | Where-Object { $_ -match '^OLLAMA_CONTEXT_LENGTH=' } | Select-Object -First 1
        if ($line) { $ctxLen = $line -replace '^OLLAMA_CONTEXT_LENGTH=', '' }
    }
    [Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", $ctxLen, "User")
    $env:OLLAMA_CONTEXT_LENGTH = $ctxLen

    # Ollama が起動していない場合は起動 (現在の env を継承)
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
# ステップ 5: 設定とスクリプト作成
# ============================================================
Write-Info "ステップ 5/5: 設定を作成中..."

# .env ファイル作成 (存在しない場合のみ)
if (-not (Test-Path "$INSTALL_DIR\.env")) {
    $JWT_SECRET = -join ((48..57) + (97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
    $ENV_CONTENT = @"
# AI Server Configuration
# Backend selection (= unified codebase で env で切替)
LLM_BACKEND=ollama

DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}
OLLAMA_BASE_URL=http://localhost:11434
# OLLAMA_NUM_PARALLEL=8
# Ollama daemon の num_ctx (default 2048 → 16384) - document 出力切れ防止
OLLAMA_CONTEXT_LENGTH=16384
# 起動時に Ollama daemon を auto-spawn (= 1-click 起動向け、false にすると外部 daemon 想定)
OLLAMA_AUTO_START=true
LICENSE_FILE_PATH=$INSTALL_DIR\license.lic

# File Storage (pipeline uploads/outputs)
FILES_DIR=$INSTALL_DIR\files

# Server Configuration (API + Web on single port)
API_HOST=0.0.0.0
API_PORT=8000

# Authentication
JWT_SECRET=$JWT_SECRET
AUTH_MODE=local

# Whisper Transcription
# WHISPER_MODEL=tiny

# LDAP (AUTH_MODE=ldap)
# LDAP_HOST=your-ad-server.company.local
# LDAP_PORT=389
# LDAP_USE_SSL=false
# LDAP_BASE_DN=dc=company,dc=local
# LDAP_USER_DN_FORMAT={username}@company.local
# LDAP_BIND_DN=
# LDAP_BIND_PASSWORD=

# OIDC / Azure AD (AUTH_MODE=oidc)
# OIDC_CLIENT_ID=
# OIDC_CLIENT_SECRET=
# OIDC_TENANT_ID=

# Cloud LLM Providers (optional)
# OPENAI_API_KEY=
# OPENAI_BASE_URL=https://api.openai.com/v1
# ANTHROPIC_API_KEY=
# GEMINI_API_KEY=

# Web Search (default OFF)
# WEB_SEARCH_ENABLED=false
# WEB_SEARCH_ENGINE=duckduckgo
# WEB_SEARCH_SEARXNG_URL=http://localhost:8888
# WEB_SEARCH_MAX_RESULTS=3
"@
    Set-Content -Path "$INSTALL_DIR\.env" -Value $ENV_CONTENT -Encoding UTF8
    Write-Success ".env ファイルを作成しました"
} else {
    Write-Info ".env ファイルは既存のため、スキップしました"
}

# 起動スクリプト作成
$START_SCRIPT = @'
# AI Server 起動スクリプト
$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Set-Location $INSTALL_DIR

# .env 読み込み
if (Test-Path "$INSTALL_DIR\.env") {
    Get-Content "$INSTALL_DIR\.env" | ForEach-Object {
        if ($_ -match "^([^#][^=]+)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
        }
    }
}

# Tesseract OCR (画像OCR用)
if (Test-Path "C:\Program Files\Tesseract-OCR\tesseract.exe") {
    $env:PATH = "C:\Program Files\Tesseract-OCR;$env:PATH"
    $env:TESSDATA_PREFIX = "C:\Program Files\Tesseract-OCR\tessdata"
}

# FFmpeg PATH 設定 (文字起こし用・オプション)
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

# PostgreSQL チェック
$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService -and $pgService.Status -ne "Running") {
    Write-Host "PostgreSQL を起動中..."
    Start-Service $pgService.Name
    Start-Sleep -Seconds 2
}

# Ollama チェック
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Write-Host "Ollama を起動中..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

# 既存プロセス終了
Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force
Start-Sleep -Seconds 1

if (-not $env:API_PORT) { $env:API_PORT = "8000" }

# API 起動 (single process: API + Web frontend)
Write-Host "API を起動中..."
$apiProcess = Start-Process -FilePath "$INSTALL_DIR\api.exe" -WorkingDirectory $INSTALL_DIR -NoNewWindow -PassThru
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "AI Server が起動しました！" -ForegroundColor Green
Write-Host ""
Write-Host "  http://localhost:$($env:API_PORT)" -ForegroundColor Cyan

# LAN IP 表示
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1).IPAddress
if ($lanIp) { Write-Host "  LAN:  http://${lanIp}:$($env:API_PORT)" -ForegroundColor Cyan }

# mDNS hostname 表示 (Windows 10 1709+)
$mdnsName = "$([System.Net.Dns]::GetHostName()).local"
Write-Host "  mDNS: http://${mdnsName}:$($env:API_PORT)" -ForegroundColor Cyan

Write-Host ""
Write-Host "  Ctrl+C で停止" -ForegroundColor Yellow
Write-Host ""

# Ctrl+C ハンドラー
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
}

try {
    # プロセス終了まで待機
    Wait-Process -Id $apiProcess.Id -ErrorAction SilentlyContinue
} finally {
    Write-Host "Stopped"
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
}
'@

Set-Content -Path "$INSTALL_DIR\start.ps1" -Value $START_SCRIPT -Encoding UTF8

# 停止スクリプト作成
$STOP_SCRIPT = @'
# AI Server 停止スクリプト
Write-Host "AI Server を停止中..."

Get-Process -Name "api" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*db*" } | Stop-Process -Force

Write-Host "AI Server を停止しました" -ForegroundColor Green
'@

Set-Content -Path "$INSTALL_DIR\stop.ps1" -Value $STOP_SCRIPT -Encoding UTF8

# トグルスクリプト作成（macOSと同様の動作）
$TOGGLE_SCRIPT = @'
# AI Server トグルスクリプト
# 起動中ならStop、停止中ならStart

$INSTALL_DIR = "$env:LOCALAPPDATA\db"
Set-Location $INSTALL_DIR

# .env 読み込み
$API_PORT = 8000
if (Test-Path "$INSTALL_DIR\.env") {
    Get-Content "$INSTALL_DIR\.env" | ForEach-Object {
        if ($_ -match "^API_PORT=(.*)$") { $API_PORT = $matches[1] }
    }
}

# ヘルスチェック
$isRunning = $false
try {
    $response = Invoke-WebRequest -Uri "http://localhost:$API_PORT/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    $isRunning = $true
} catch { }

if ($isRunning) {
    # 起動中 → 停止
    & "$INSTALL_DIR\stop.ps1"

    # トースト通知
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText01
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
    $xml.GetElementsByTagName("text").Item(0).AppendChild($xml.CreateTextNode("AI Server stopped")) | Out-Null
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("AI Server")
    $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} else {
    # 停止中 → 起動
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$INSTALL_DIR\start.ps1`"" -WindowStyle Hidden

    # API起動待ち (最大30秒)
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

        # トースト通知
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
Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     AI Server のインストールが完了しました！          ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

if ($MISSING_DEPS.Count -gt 0) {
    Write-Warn "不足している依存関係: $($MISSING_DEPS -join ', ')"
    Write-Host ""
    Write-Host "  winget でインストール:"
    if ($MISSING_DEPS -contains "nodejs") { Write-Host "    winget install OpenJS.NodeJS.LTS" }
    if ($MISSING_DEPS -contains "postgresql") { Write-Host "    winget install PostgreSQL.PostgreSQL" }
    if ($MISSING_DEPS -contains "ollama") { Write-Host "    winget install Ollama.Ollama" }
    if ($MISSING_DEPS -contains "tesseract") { Write-Host "    Tesseract: https://github.com/UB-Mannheim/tesseract/wiki  # オプション: 画像OCR用" }
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
Write-Host "  ライセンス購入: https://digital-base.co.jp/services/localllm/lmlight-purchase"
Write-Host ""
