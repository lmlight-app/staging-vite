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

    # マイグレーション実行 (schema 分離: public / approval / helpdesk / vision / log / datalake / pgvector)
    Write-Info "データベースマイグレーションを実行中..."

    $SQL_MIGRATION = @"
-- ── Schemas ─────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS approval;
CREATE SCHEMA IF NOT EXISTS helpdesk;
CREATE SCHEMA IF NOT EXISTS vision;
CREATE SCHEMA IF NOT EXISTS log;
CREATE SCHEMA IF NOT EXISTS datalake;
CREATE SCHEMA IF NOT EXISTS pgvector;

-- ── 既存環境からの schema 移動 (public.X → target.X) ─────────────────────────
-- legacy customer 上は ApprovalFlow 等が public schema に残ってる可能性がある。
-- 下の CREATE TABLE IF NOT EXISTS で空テーブルが先にできると ALTER SET SCHEMA
-- が target 衝突で失敗するため、CREATE より前に移動する。
ALTER TABLE IF EXISTS public."ApprovalFlow" SET SCHEMA approval;
ALTER TABLE IF EXISTS public."ApprovalFlowStep" SET SCHEMA approval;
ALTER TABLE IF EXISTS public."ApprovalRequest" SET SCHEMA approval;
ALTER TABLE IF EXISTS public."ApprovalStepResult" SET SCHEMA approval;
ALTER TABLE IF EXISTS public."HelpdeskRoom" SET SCHEMA helpdesk;
ALTER TABLE IF EXISTS public."HelpdeskMember" SET SCHEMA helpdesk;
ALTER TABLE IF EXISTS public."HelpdeskReadState" SET SCHEMA helpdesk;
ALTER TABLE IF EXISTS public."YoloModel" SET SCHEMA vision;
ALTER TABLE IF EXISTS public."VisionAutomationRule" SET SCHEMA vision;
ALTER TABLE IF EXISTS public."AppLog" SET SCHEMA log;
ALTER TABLE IF EXISTS public."AuditLog" SET SCHEMA log;

-- ── Enums ───────────────────────────────────────────────────────────────────
DO `$`$ BEGIN CREATE TYPE "UserRole" AS ENUM ('ADMIN', 'SUPER', 'USER'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "UserStatus" AS ENUM ('ACTIVE', 'INACTIVE'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "MessageRole" AS ENUM ('USER', 'ASSISTANT', 'SYSTEM'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "ShareType" AS ENUM ('PRIVATE', 'TAG'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "DocumentType" AS ENUM ('PDF', 'WEB', 'TEXT', 'CSV', 'EXCEL', 'WORD', 'IMAGE', 'JSON'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "ApprovalStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;

-- ── public schema (主要 entity) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "User" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255),
    "email" VARCHAR(255) NOT NULL UNIQUE,
    "emailVerified" TIMESTAMP,
    "image" VARCHAR(255),
    "hashedPassword" VARCHAR(255),
    "authProvider" VARCHAR(255) NOT NULL DEFAULT 'local',
    "role" "UserRole" NOT NULL DEFAULT 'USER',
    "status" "UserStatus" NOT NULL DEFAULT 'ACTIVE',
    "ldapAttributes" JSONB,
    "lastLoginAt" TIMESTAMP,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Tag" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL UNIQUE,
    "description" TEXT,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "UserTag" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "userId" VARCHAR(255) NOT NULL,
    "tagId" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "UserTag_userId_tagId_key" UNIQUE ("userId", "tagId")
);

CREATE TABLE IF NOT EXISTS "LdapGroupMapping" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "ldapGroupDn" VARCHAR(500) NOT NULL UNIQUE,
    "tagId" VARCHAR(255),
    "role" "UserRole",
    "description" TEXT,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Bot" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "userId" VARCHAR(255) NOT NULL,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "url" TEXT,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Document" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "botId" VARCHAR(255) NOT NULL,
    "name" VARCHAR(255) NOT NULL,
    "type" "DocumentType" NOT NULL DEFAULT 'PDF',
    "url" TEXT,
    "metadata" JSONB,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Chat" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "userId" VARCHAR(255) NOT NULL,
    "model" VARCHAR(255) NOT NULL,
    "sessionId" VARCHAR(255) NOT NULL,
    "botId" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL,
    "updatedAt" TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS "Message" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "chatId" VARCHAR(255) NOT NULL,
    "role" "MessageRole" NOT NULL,
    "content" TEXT NOT NULL,
    "metadata" JSONB,
    "createdAt" TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS "DefaultSetting" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "userId" VARCHAR(255) NOT NULL UNIQUE,
    "defaultModel" VARCHAR(255),
    "customPrompt" TEXT,
    "historyLimit" INTEGER NOT NULL DEFAULT 2,
    "temperature" DOUBLE PRECISION NOT NULL DEFAULT 0.7,
    "maxTokens" INTEGER NOT NULL DEFAULT 8192,
    "numCtx" INTEGER NOT NULL DEFAULT 32768,
    "topP" DOUBLE PRECISION NOT NULL DEFAULT 0.9,
    "topK" INTEGER NOT NULL DEFAULT 40,
    "repeatPenalty" DOUBLE PRECISION NOT NULL DEFAULT 1.1,
    "reasoningMode" VARCHAR(255) NOT NULL DEFAULT 'normal',
    "ragTopK" INTEGER NOT NULL DEFAULT 5,
    "ragMinSimilarity" DOUBLE PRECISION NOT NULL DEFAULT 0.45,
    "embeddingModel" VARCHAR(255) NOT NULL DEFAULT '',
    "chunkSize" INTEGER NOT NULL DEFAULT 500,
    "chunkOverlap" INTEGER NOT NULL DEFAULT 100,
    "visionModel" VARCHAR(255),
    "visionPrompt" TEXT,
    "brandColor" VARCHAR(255) NOT NULL DEFAULT 'default',
    "customLogoText" TEXT DEFAULT 'LL',
    "customLogoImage" TEXT,
    "customTitle" TEXT DEFAULT 'LM LIGHT',
    "sidebarItems" JSONB,
    "sqlConnection" JSONB,
    "toolSettings" JSONB,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "SystemSetting" (
    "id" VARCHAR(64) NOT NULL PRIMARY KEY DEFAULT 'default',
    "brandColor" VARCHAR(255) NOT NULL DEFAULT 'default',
    "customLogoText" TEXT DEFAULT 'LL',
    "customLogoImage" TEXT,
    "customTitle" TEXT DEFAULT 'LM LIGHT',
    "sidebarItems" JSONB,
    "allowedIframeOrigins" JSONB,
    "embedEnabled" BOOLEAN NOT NULL DEFAULT false,
    "updatedBy" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Prompt" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "title" VARCHAR(255) NOT NULL,
    "content" TEXT NOT NULL,
    "userId" VARCHAR(255) NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "SavedSqlConnection" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "dbType" VARCHAR(32) NOT NULL DEFAULT 'postgresql',
    "host" VARCHAR(255) NOT NULL DEFAULT 'localhost',
    "port" INTEGER NOT NULL DEFAULT 5432,
    "database" VARCHAR(255) NOT NULL,
    "dbUser" VARCHAR(255) NOT NULL,
    "password" VARCHAR(255) NOT NULL,
    "schema" VARCHAR(255) NOT NULL DEFAULT 'public',
    "userId" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "ApiConnection" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "type" VARCHAR(50) NOT NULL,
    "config" JSONB NOT NULL,
    "mcpEnabled" BOOLEAN NOT NULL DEFAULT false,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Pipeline" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "config" JSONB,
    "createdBy" VARCHAR(255) NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineStep" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "pipelineId" VARCHAR(255) NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "name" VARCHAR(255) NOT NULL,
    "type" VARCHAR(50) NOT NULL,
    "config" JSONB NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineRun" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "pipelineId" VARCHAR(255) NOT NULL,
    "status" VARCHAR(20) NOT NULL DEFAULT 'pending',
    "startedAt" TIMESTAMP,
    "completedAt" TIMESTAMP,
    "result" JSONB,
    "error" TEXT,
    "triggeredBy" VARCHAR(255) NOT NULL,
    "runAs" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineSchedule" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "pipelineId" VARCHAR(255) NOT NULL,
    "cronExpr" VARCHAR(100) NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "lastRunAt" TIMESTAMP,
    "nextRunAt" TIMESTAMP,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "SharedDirAcl" (
    "path" VARCHAR(512) NOT NULL PRIMARY KEY,
    "shareTagId" VARCHAR(255) NOT NULL,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 多 protocol ファイル接続 (SFTP/SMB/FTP/S3/GCS/Azure/WebDAV/HTTP の credential 接続)。
-- OAuth 系 (GDrive/OneDrive/Dropbox/Box/SharePoint) は OAuthConnection を流用。
CREATE TABLE IF NOT EXISTS "FileConnection" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "type" VARCHAR(32) NOT NULL,
    "config" JSONB NOT NULL,
    "ownerId" VARCHAR(255) NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "OAuthConnection" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "userId" VARCHAR(255) NOT NULL,
    "provider" VARCHAR(64) NOT NULL,
    "accountLabel" VARCHAR(255) NOT NULL DEFAULT 'default',
    "accountEmail" VARCHAR(255),
    "accessToken" TEXT NOT NULL,
    "refreshToken" TEXT,
    "expiresAt" TIMESTAMP,
    "scopes" JSONB,
    "connectionConfig" JSONB,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "OAuthConnection_user_provider_label_key" UNIQUE ("userId", "provider", "accountLabel")
);

CREATE TABLE IF NOT EXISTS "SqlDashboard" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "layout" JSONB NOT NULL,
    "refreshInterval" INTEGER,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── approval schema ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS approval."ApprovalFlow" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "requesterIds" JSONB NOT NULL,
    "notificationWebhookUrl" TEXT,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS approval."ApprovalFlowStep" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "flowId" VARCHAR(255) NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "label" TEXT,
    "approverIds" JSONB NOT NULL,
    CONSTRAINT "ApprovalFlowStep_flowId_stepOrder_key" UNIQUE ("flowId", "stepOrder")
);

CREATE TABLE IF NOT EXISTS approval."ApprovalRequest" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "flowId" VARCHAR(255) NOT NULL,
    "title" VARCHAR(255) NOT NULL,
    "body" TEXT,
    "attachments" JSONB,
    "requestedBy" VARCHAR(255) NOT NULL,
    "status" "ApprovalStatus" NOT NULL DEFAULT 'PENDING',
    "currentStep" INTEGER NOT NULL DEFAULT 1,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS approval."ApprovalStepResult" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "requestId" VARCHAR(255) NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "status" "ApprovalStatus" NOT NULL,
    "approvedBy" VARCHAR(255),
    "comment" TEXT,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ApprovalStepResult_requestId_stepOrder_key" UNIQUE ("requestId", "stepOrder")
);

-- ── helpdesk schema ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS helpdesk."HelpdeskRoom" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "botId" VARCHAR(255),
    "model" VARCHAR(255),
    "modelParams" JSONB,
    "ragParams" JSONB,
    "systemPrompt" TEXT,
    "aiPaused" BOOLEAN NOT NULL DEFAULT false,
    "notificationWebhookUrl" TEXT,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS helpdesk."HelpdeskMember" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "roomId" VARCHAR(255) NOT NULL,
    "userId" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS helpdesk."HelpdeskReadState" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "roomId" VARCHAR(255) NOT NULL,
    "userId" VARCHAR(255) NOT NULL,
    "memberId" VARCHAR(255),
    "lastReadAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── vision schema ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vision."YoloModel" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "version" VARCHAR(64) NOT NULL,
    "fileName" VARCHAR(255) NOT NULL,
    "baseModel" VARCHAR(255),
    "classes" JSONB,
    "metricsJson" JSONB,
    "notes" TEXT,
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vision."VisionAutomationRule" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "sourceConfig" JSONB NOT NULL,
    "detectConfig" JSONB NOT NULL,
    "triggerCondition" JSONB NOT NULL,
    "pipelineId" VARCHAR(255),
    "notifyConfig" JSONB,
    "schedule" VARCHAR(64),
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── log schema ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS log."AppLog" (
    "id" SERIAL PRIMARY KEY,
    "timestamp" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "level" VARCHAR(10) NOT NULL,
    "logger" VARCHAR(255),
    "message" TEXT NOT NULL,
    "module" VARCHAR(255),
    "func" VARCHAR(255),
    "line" INTEGER,
    "userId" VARCHAR(255),
    "requestId" VARCHAR(64),
    "extra" JSONB
);

CREATE TABLE IF NOT EXISTS log."AuditLog" (
    "id" SERIAL PRIMARY KEY,
    "timestamp" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "userId" VARCHAR(255),
    "userEmail" VARCHAR(255),
    "userName" VARCHAR(255),
    "requestId" VARCHAR(64),
    "action" VARCHAR(30) NOT NULL,
    "resourceType" VARCHAR(50),
    "resourceId" VARCHAR(255),
    "method" VARCHAR(10) NOT NULL,
    "path" TEXT NOT NULL,
    "statusCode" INTEGER,
    "ipAddress" VARCHAR(64),
    "userAgent" TEXT,
    "payload" JSONB
);

-- ── datalake schema (pipeline 収集 dataset) ────────────────────────────────
CREATE TABLE IF NOT EXISTS datalake.datasets (
    "id" VARCHAR(255) PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "ownerId" VARCHAR(255) NOT NULL,
    "physicalTable" VARCHAR(63) NOT NULL UNIQUE,
    "columns" JSONB NOT NULL,
    "rowCount" INTEGER NOT NULL DEFAULT 0,
    "sizeBytes" INTEGER NOT NULL DEFAULT 0,
    "sourcePipelineId" VARCHAR(255),
    "lastUpdatedAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── pgvector schema (RAG embedding) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgvector.embeddings (
    id SERIAL PRIMARY KEY,
    bot_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    document_id VARCHAR(255) NOT NULL,
    chunk_id INTEGER NOT NULL,
    content TEXT NOT NULL,
    embedding vector,
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- ── Indexes ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS "UserTag_userId_idx" ON "UserTag"("userId");
CREATE INDEX IF NOT EXISTS "UserTag_tagId_idx" ON "UserTag"("tagId");
CREATE INDEX IF NOT EXISTS "LdapGroupMapping_tagId_idx" ON "LdapGroupMapping"("tagId");
CREATE INDEX IF NOT EXISTS "Bot_userId_idx" ON "Bot"("userId");
CREATE INDEX IF NOT EXISTS "Bot_shareTagId_idx" ON "Bot"("shareTagId");
CREATE INDEX IF NOT EXISTS "Document_botId_idx" ON "Document"("botId");
CREATE INDEX IF NOT EXISTS "Chat_sessionId_idx" ON "Chat"("sessionId");
CREATE INDEX IF NOT EXISTS "Chat_userId_model_idx" ON "Chat"("userId", "model");
CREATE INDEX IF NOT EXISTS "Chat_userId_idx" ON "Chat"("userId");
CREATE INDEX IF NOT EXISTS "Chat_botId_idx" ON "Chat"("botId");
CREATE INDEX IF NOT EXISTS "Message_chatId_createdAt_idx" ON "Message"("chatId", "createdAt");
CREATE INDEX IF NOT EXISTS "SavedSqlConnection_userId_idx" ON "SavedSqlConnection"("userId");
CREATE INDEX IF NOT EXISTS "Prompt_userId_idx" ON "Prompt"("userId");
CREATE INDEX IF NOT EXISTS "Prompt_shareTagId_idx" ON "Prompt"("shareTagId");
CREATE INDEX IF NOT EXISTS "ApiConnection_createdBy_idx" ON "ApiConnection"("createdBy");
CREATE INDEX IF NOT EXISTS "ApiConnection_type_idx" ON "ApiConnection"("type");
CREATE INDEX IF NOT EXISTS "Pipeline_createdBy_idx" ON "Pipeline"("createdBy");
CREATE INDEX IF NOT EXISTS "Pipeline_shareTagId_idx" ON "Pipeline"("shareTagId");
CREATE INDEX IF NOT EXISTS "PipelineStep_pipelineId_idx" ON "PipelineStep"("pipelineId");
CREATE INDEX IF NOT EXISTS "PipelineRun_pipelineId_idx" ON "PipelineRun"("pipelineId");
CREATE INDEX IF NOT EXISTS "PipelineRun_status_idx" ON "PipelineRun"("status");
CREATE INDEX IF NOT EXISTS "PipelineSchedule_pipelineId_idx" ON "PipelineSchedule"("pipelineId");

CREATE INDEX IF NOT EXISTS "ApprovalFlow_createdBy_idx" ON approval."ApprovalFlow"("createdBy");
CREATE INDEX IF NOT EXISTS "ApprovalFlowStep_flowId_idx" ON approval."ApprovalFlowStep"("flowId");
CREATE INDEX IF NOT EXISTS "ApprovalRequest_flowId_idx" ON approval."ApprovalRequest"("flowId");
CREATE INDEX IF NOT EXISTS "ApprovalRequest_requestedBy_idx" ON approval."ApprovalRequest"("requestedBy");
CREATE INDEX IF NOT EXISTS "ApprovalStepResult_requestId_idx" ON approval."ApprovalStepResult"("requestId");

CREATE INDEX IF NOT EXISTS "HelpdeskRoom_createdBy_idx" ON helpdesk."HelpdeskRoom"("createdBy");
CREATE INDEX IF NOT EXISTS "HelpdeskMember_roomId_idx" ON helpdesk."HelpdeskMember"("roomId");
CREATE INDEX IF NOT EXISTS "HelpdeskMember_userId_idx" ON helpdesk."HelpdeskMember"("userId");
CREATE UNIQUE INDEX IF NOT EXISTS "HelpdeskMember_roomId_userId_key" ON helpdesk."HelpdeskMember"("roomId", "userId");
CREATE INDEX IF NOT EXISTS "HelpdeskReadState_roomId_idx" ON helpdesk."HelpdeskReadState"("roomId");
CREATE INDEX IF NOT EXISTS "HelpdeskReadState_userId_idx" ON helpdesk."HelpdeskReadState"("userId");
-- memberId 含めて 3 列 uniq (NULL=room-level、設定時=per-member)
CREATE UNIQUE INDEX IF NOT EXISTS "HelpdeskReadState_roomId_userId_key" ON helpdesk."HelpdeskReadState"("roomId", "userId", "memberId");

CREATE INDEX IF NOT EXISTS "AppLog_timestamp_idx" ON log."AppLog"("timestamp");
CREATE INDEX IF NOT EXISTS "AppLog_level_timestamp_idx" ON log."AppLog"("level", "timestamp");
CREATE INDEX IF NOT EXISTS "AppLog_userId_idx" ON log."AppLog"("userId");
CREATE INDEX IF NOT EXISTS "AuditLog_timestamp_idx" ON log."AuditLog"("timestamp");
CREATE INDEX IF NOT EXISTS "AuditLog_userId_timestamp_idx" ON log."AuditLog"("userId", "timestamp");
CREATE INDEX IF NOT EXISTS "AuditLog_resourceType_idx" ON log."AuditLog"("resourceType");

CREATE UNIQUE INDEX IF NOT EXISTS "datasets_owner_name_key" ON datalake.datasets("ownerId", "name");
CREATE INDEX IF NOT EXISTS "datasets_owner_idx" ON datalake.datasets("ownerId");

CREATE INDEX IF NOT EXISTS idx_bot_user ON pgvector.embeddings (bot_id, user_id);
CREATE INDEX IF NOT EXISTS idx_document ON pgvector.embeddings (document_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw ON pgvector.embeddings USING hnsw (embedding vector_cosine_ops);

-- ── 初期 admin user (admin@local / admin123) ────────────────────────────────
INSERT INTO "User" ("id", "email", "name", "hashedPassword", "role", "status", "updatedAt")
VALUES (
    'admin-user-id',
    'admin@local',
    'Admin',
    '`$2b`$12`$AIctg50Pbt418E7ir3HlUOP1HWKO4PSP01HfIsx8v6Ab.Td7G5h72',
    'ADMIN',
    'ACTIVE',
    CURRENT_TIMESTAMP
) ON CONFLICT ("id") DO NOTHING;
"@

    $ErrorActionPreference = "Continue"
    # DB owner (= digitalbase) として実行することで作成 object の owner も
    # digitalbase になり、追加 GRANT が不要になる (db_setup.sh と挙動を統一)。
    $env:PGPASSWORD = $DB_PASSWORD
    $null = $SQL_MIGRATION | psql -q -U $DB_USER -p $DB_PORT -d $DB_NAME 2>$null
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    $ErrorActionPreference = "Stop"
    Write-Success "データベースマイグレーションが完了しました"
} else {
    Write-Warn "PostgreSQL がインストールされていないため、データベースセットアップをスキップしました"
}

# ============================================================
# ステップ 4: Ollama セットアップ
# ============================================================
Write-Info "ステップ 4/5: Ollama をセットアップ中..."

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    # Ollama が起動していない場合は起動
    $ollamaProcess = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if (-not $ollamaProcess) {
        Write-Info "Ollama を起動中..."
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
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
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}
OLLAMA_BASE_URL=http://localhost:11434
# OLLAMA_NUM_PARALLEL=8
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