# AI Server インストーラー for Windows (Vite Edition)
# 使い方: irm https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-windows.ps1 | iex

$ErrorActionPreference = "Stop"

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

# 管理者権限チェック
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "管理者権限で実行していません。一部の機能が制限される場合があります。"
}

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

# winget で依存関係をインストール（オプション）
if ($MISSING_DEPS.Count -gt 0 -and $isAdmin) {
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
        Start-Service $pgService.Name
        Start-Sleep -Seconds 3
    }

    # ポート検出: 5432 → 5433 の順で試行
    $env:PGPASSWORD = "postgres"
    $ErrorActionPreference = "Continue"
    $null = psql -U postgres -p 5432 -c "SELECT 1" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $null = psql -U postgres -p 5433 -c "SELECT 1" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $DB_PORT = "5433"
            Write-Info "PostgreSQL ポート: 5433"
        }
    } else {
        Write-Info "PostgreSQL ポート: 5432"
    }
    # データベースとユーザー作成 (エラーは無視)
    $null = psql -U postgres -p $DB_PORT -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';" 2>$null
    $null = psql -U postgres -p $DB_PORT -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>$null
    $null = psql -U postgres -p $DB_PORT -c "ALTER USER $DB_USER CREATEDB;" 2>$null

    # pgvector拡張 - 自動インストール
    # PostgreSQL インストールパスを検出
    $PG_DIR = $null
    $pgVersions = @("17", "16", "15", "14")
    foreach ($v in $pgVersions) {
        $candidate = "C:\Program Files\PostgreSQL\$v"
        if (Test-Path "$candidate\bin\psql.exe") {
            $PG_DIR = $candidate
            break
        }
    }

    # vector.dll が未配置なら自動ダウンロード
    if ($PG_DIR -and -not (Test-Path "$PG_DIR\lib\vector.dll")) {
        Write-Info "pgvector をインストール中..."
        $pgMajor = (Split-Path $PG_DIR -Leaf)
        $pgvectorUrl = "https://github.com/andreiramani/pgvector_pgsql_windows/releases/latest/download/pgvector_pg${pgMajor}_x64.zip"
        $pgvectorZip = "$env:TEMP\pgvector.zip"
        $pgvectorExtract = "$env:TEMP\pgvector_extract"

        try {
            Invoke-WebRequest -Uri $pgvectorUrl -OutFile $pgvectorZip -UseBasicParsing
            if (Test-Path $pgvectorExtract) { Remove-Item -Recurse -Force $pgvectorExtract }
            Expand-Archive -Path $pgvectorZip -DestinationPath $pgvectorExtract -Force

            # DLL とコントロールファイルを配置
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector.dll" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\lib\vector.dll" -Force
            }
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector.control" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\share\extension\vector.control" -Force
            }
            Get-ChildItem -Path $pgvectorExtract -Recurse -Filter "vector--*.sql" | ForEach-Object {
                Copy-Item $_.FullName "$PG_DIR\share\extension\$($_.Name)" -Force
            }

            # クリーンアップ
            Remove-Item -Force $pgvectorZip -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $pgvectorExtract -ErrorAction SilentlyContinue

            Write-Success "pgvector をインストールしました"
        } catch {
            Write-Warn "pgvector の自動インストールに失敗しました。手動インストールが必要です: https://github.com/pgvector/pgvector#windows"
        }
    } elseif ($PG_DIR) {
        Write-Success "pgvector は既にインストール済みです"
    }

    $null = psql -U postgres -p $DB_PORT -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>$null

    $ErrorActionPreference = "Stop"

    # マイグレーション実行
    Write-Info "データベースマイグレーションを実行中..."

    $SQL_MIGRATION = @"
-- 列挙型
DO `$`$ BEGIN CREATE TYPE "UserRole" AS ENUM ('ADMIN', 'SUPER', 'USER'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "UserStatus" AS ENUM ('ACTIVE', 'INACTIVE'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "MessageRole" AS ENUM ('USER', 'ASSISTANT', 'SYSTEM'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "ShareType" AS ENUM ('PRIVATE', 'TAG'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "DocumentType" AS ENUM ('PDF', 'WEB', 'TEXT', 'CSV', 'EXCEL', 'WORD', 'IMAGE', 'JSON'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;
DO `$`$ BEGIN CREATE TYPE "ApprovalStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END `$`$;

-- Rename from UserSettings if upgrading
DO `$`$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'UserSettings' AND table_schema = 'public') THEN
        ALTER TABLE "UserSettings" RENAME TO "DefaultSetting";
    END IF;
END `$`$;

-- テーブル
CREATE TABLE IF NOT EXISTS "User" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT,
    "email" TEXT NOT NULL UNIQUE,
    "emailVerified" TIMESTAMP(3),
    "image" TEXT,
    "hashedPassword" TEXT,
    "authProvider" TEXT NOT NULL DEFAULT 'local',
    "role" "UserRole" NOT NULL DEFAULT 'USER',
    "status" "UserStatus" NOT NULL DEFAULT 'ACTIVE',
    "lastLoginAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "DefaultSetting" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "userId" TEXT NOT NULL UNIQUE,
    "defaultModel" TEXT,
    "customPrompt" TEXT,
    "historyLimit" INTEGER NOT NULL DEFAULT 2,
    "temperature" DOUBLE PRECISION NOT NULL DEFAULT 0.7,
    "maxTokens" INTEGER NOT NULL DEFAULT 8192,
    "numCtx" INTEGER NOT NULL DEFAULT 32768,
    "topP" DOUBLE PRECISION NOT NULL DEFAULT 0.9,
    "topK" INTEGER NOT NULL DEFAULT 40,
    "repeatPenalty" DOUBLE PRECISION NOT NULL DEFAULT 1.1,
    "reasoningMode" TEXT NOT NULL DEFAULT 'normal',
    "ragTopK" INTEGER NOT NULL DEFAULT 5,
    "ragMinSimilarity" DOUBLE PRECISION NOT NULL DEFAULT 0.45,
    "embeddingModel" TEXT NOT NULL DEFAULT '',
    "chunkSize" INTEGER NOT NULL DEFAULT 500,
    "chunkOverlap" INTEGER NOT NULL DEFAULT 100,
    "visionModel" TEXT,
    "brandColor" TEXT NOT NULL DEFAULT 'default',
    "customLogoText" TEXT DEFAULT 'LL',
    "customLogoImage" TEXT,
    "customTitle" TEXT DEFAULT 'LM LIGHT',
    "sidebarItems" JSONB,
    "sqlConnection" JSONB,
    "toolSettings" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Tag" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL UNIQUE,
    "description" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "UserTag" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "userId" TEXT NOT NULL,
    "tagId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE ("userId", "tagId")
);

CREATE TABLE IF NOT EXISTS "Bot" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "url" TEXT,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Document" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "botId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "type" "DocumentType" NOT NULL DEFAULT 'PDF',
    "url" TEXT,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Chat" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "userId" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "sessionId" TEXT NOT NULL,
    "botId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Message" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "chatId" TEXT NOT NULL,
    "role" "MessageRole" NOT NULL,
    "content" TEXT NOT NULL,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Workflow" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "webhookUrl" TEXT NOT NULL,
    "method" TEXT NOT NULL DEFAULT 'POST',
    "headers" JSONB,
    "body" JSONB,
    "attachments" JSONB,
    "createdBy" TEXT NOT NULL,
    "shareTagId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "WorkflowExecution" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "workflowId" TEXT NOT NULL,
    "executedBy" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    "statusCode" INTEGER,
    "response" TEXT,
    "error" TEXT,
    "duration" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "ApprovalFlow" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "requesterIds" JSONB NOT NULL,
    "notificationWebhookUrl" TEXT,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "ApprovalFlowStep" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "flowId" TEXT NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "label" TEXT,
    "approverIds" JSONB NOT NULL,
    UNIQUE ("flowId", "stepOrder")
);

CREATE TABLE IF NOT EXISTS "ApprovalRequest" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "flowId" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "body" TEXT,
    "attachments" JSONB,
    "requestedBy" TEXT NOT NULL,
    "status" "ApprovalStatus" NOT NULL DEFAULT 'PENDING',
    "currentStep" INTEGER NOT NULL DEFAULT 1,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "ApprovalStepResult" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "requestId" TEXT NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "status" "ApprovalStatus" NOT NULL,
    "approvedBy" TEXT,
    "comment" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE ("requestId", "stepOrder")
);

CREATE TABLE IF NOT EXISTS "SavedSqlConnection" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "host" TEXT NOT NULL DEFAULT 'localhost',
    "port" INTEGER NOT NULL DEFAULT 5432,
    "database" TEXT NOT NULL,
    "dbUser" TEXT NOT NULL,
    "password" TEXT NOT NULL,
    "schema" TEXT NOT NULL DEFAULT 'public',
    "userId" TEXT NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Prompt" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "title" TEXT NOT NULL,
    "content" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "HelpdeskRoom" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "botId" TEXT,
    "model" TEXT,
    "modelParams" JSONB,
    "ragParams" JSONB,
    "systemPrompt" TEXT,
    "aiPaused" BOOLEAN NOT NULL DEFAULT false,
    "notificationWebhookUrl" TEXT,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "HelpdeskMember" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "roomId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "HelpdeskReadState" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "roomId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "memberId" TEXT,
    "lastReadAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "ApiConnection" (
    "id" VARCHAR(255) NOT NULL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "type" VARCHAR(50) NOT NULL,
    "config" JSONB NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "createdBy" VARCHAR(255) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "Pipeline" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "config" JSONB,
    "shareType" TEXT NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" TEXT,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineStep" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "pipelineId" TEXT NOT NULL,
    "stepOrder" INTEGER NOT NULL,
    "name" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "config" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineRun" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "pipelineId" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',
    "startedAt" TIMESTAMP(3),
    "completedAt" TIMESTAMP(3),
    "result" JSONB,
    "error" TEXT,
    "triggeredBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "PipelineSchedule" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "pipelineId" TEXT NOT NULL,
    "cronExpr" TEXT NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "lastRunAt" TIMESTAMP(3),
    "nextRunAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Observability tables (structured logs)
CREATE TABLE IF NOT EXISTS "AppLog" (
    "id" SERIAL PRIMARY KEY,
    "timestamp" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
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

CREATE TABLE IF NOT EXISTS "AuditLog" (
    "id" SERIAL PRIMARY KEY,
    "timestamp" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "userId" VARCHAR(255),
    "action" VARCHAR(20) NOT NULL,
    "resourceType" VARCHAR(50),
    "resourceId" VARCHAR(255),
    "method" VARCHAR(10) NOT NULL,
    "path" TEXT NOT NULL,
    "statusCode" INTEGER,
    "ipAddress" VARCHAR(64),
    "userAgent" TEXT,
    "payload" JSONB
);

-- pgvector schema
CREATE SCHEMA IF NOT EXISTS pgvector;
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

-- Data Lake schema (pipeline-collected structured datasets)
CREATE SCHEMA IF NOT EXISTS datalake;
CREATE TABLE IF NOT EXISTS datalake.datasets (
    "id" VARCHAR(255) PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "description" TEXT,
    "ownerId" VARCHAR(255) NOT NULL,
    "shareType" "ShareType" NOT NULL DEFAULT 'PRIVATE',
    "shareTagId" VARCHAR(255),
    "physicalTable" VARCHAR(63) NOT NULL UNIQUE,
    "columns" JSONB NOT NULL,
    "rowCount" INTEGER NOT NULL DEFAULT 0,
    "sizeBytes" INTEGER NOT NULL DEFAULT 0,
    "sourcePipelineId" VARCHAR(255),
    "lastUpdatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- インデックス
CREATE INDEX IF NOT EXISTS "UserTag_userId_idx" ON "UserTag"("userId");
CREATE INDEX IF NOT EXISTS "UserTag_tagId_idx" ON "UserTag"("tagId");
CREATE INDEX IF NOT EXISTS "Bot_userId_idx" ON "Bot"("userId");
CREATE INDEX IF NOT EXISTS "Bot_shareTagId_idx" ON "Bot"("shareTagId");
CREATE INDEX IF NOT EXISTS "Document_botId_idx" ON "Document"("botId");
CREATE INDEX IF NOT EXISTS "Chat_sessionId_idx" ON "Chat"("sessionId");
CREATE INDEX IF NOT EXISTS "Chat_userId_model_idx" ON "Chat"("userId", "model");
CREATE INDEX IF NOT EXISTS "Chat_userId_idx" ON "Chat"("userId");
CREATE INDEX IF NOT EXISTS "Chat_botId_idx" ON "Chat"("botId");
CREATE INDEX IF NOT EXISTS "Message_chatId_createdAt_idx" ON "Message"("chatId", "createdAt");
CREATE INDEX IF NOT EXISTS "Workflow_createdBy_idx" ON "Workflow"("createdBy");
CREATE INDEX IF NOT EXISTS "Workflow_shareTagId_idx" ON "Workflow"("shareTagId");
CREATE INDEX IF NOT EXISTS "WorkflowExecution_workflowId_createdAt_idx" ON "WorkflowExecution"("workflowId", "createdAt");
CREATE INDEX IF NOT EXISTS "WorkflowExecution_executedBy_idx" ON "WorkflowExecution"("executedBy");
CREATE INDEX IF NOT EXISTS "ApprovalFlow_createdBy_idx" ON "ApprovalFlow"("createdBy");
CREATE INDEX IF NOT EXISTS "ApprovalFlowStep_flowId_idx" ON "ApprovalFlowStep"("flowId");
CREATE INDEX IF NOT EXISTS "ApprovalRequest_flowId_idx" ON "ApprovalRequest"("flowId");
CREATE INDEX IF NOT EXISTS "ApprovalRequest_requestedBy_idx" ON "ApprovalRequest"("requestedBy");
CREATE INDEX IF NOT EXISTS "ApprovalStepResult_requestId_idx" ON "ApprovalStepResult"("requestId");
CREATE INDEX IF NOT EXISTS "SavedSqlConnection_userId_idx" ON "SavedSqlConnection"("userId");
CREATE INDEX IF NOT EXISTS "SavedSqlConnection_shareTagId_idx" ON "SavedSqlConnection"("shareTagId");
CREATE INDEX IF NOT EXISTS "Prompt_userId_idx" ON "Prompt"("userId");
CREATE INDEX IF NOT EXISTS "Prompt_shareTagId_idx" ON "Prompt"("shareTagId");
CREATE INDEX IF NOT EXISTS "HelpdeskRoom_createdBy_idx" ON "HelpdeskRoom"("createdBy");
CREATE INDEX IF NOT EXISTS "HelpdeskMember_roomId_idx" ON "HelpdeskMember"("roomId");
CREATE INDEX IF NOT EXISTS "HelpdeskMember_userId_idx" ON "HelpdeskMember"("userId");
CREATE UNIQUE INDEX IF NOT EXISTS "HelpdeskMember_roomId_userId_key" ON "HelpdeskMember"("roomId", "userId");
CREATE INDEX IF NOT EXISTS "HelpdeskReadState_roomId_idx" ON "HelpdeskReadState"("roomId");
CREATE INDEX IF NOT EXISTS "HelpdeskReadState_userId_idx" ON "HelpdeskReadState"("userId");
CREATE UNIQUE INDEX IF NOT EXISTS "HelpdeskReadState_roomId_userId_key" ON "HelpdeskReadState"("roomId", "userId", "memberId");
CREATE INDEX IF NOT EXISTS "ApiConnection_createdBy_idx" ON "ApiConnection"("createdBy");
CREATE INDEX IF NOT EXISTS "ApiConnection_type_idx" ON "ApiConnection"("type");
CREATE INDEX IF NOT EXISTS "ApiConnection_shareTagId_idx" ON "ApiConnection"("shareTagId");
CREATE INDEX IF NOT EXISTS "Pipeline_createdBy_idx" ON "Pipeline"("createdBy");
CREATE INDEX IF NOT EXISTS "PipelineStep_pipelineId_idx" ON "PipelineStep"("pipelineId");
CREATE INDEX IF NOT EXISTS "PipelineRun_pipelineId_idx" ON "PipelineRun"("pipelineId");
CREATE INDEX IF NOT EXISTS "PipelineRun_status_idx" ON "PipelineRun"("status");
CREATE INDEX IF NOT EXISTS "PipelineSchedule_pipelineId_idx" ON "PipelineSchedule"("pipelineId");
CREATE INDEX IF NOT EXISTS idx_bot_user ON pgvector.embeddings (bot_id, user_id);
CREATE INDEX IF NOT EXISTS idx_document ON pgvector.embeddings (document_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw ON pgvector.embeddings USING hnsw (embedding vector_cosine_ops);

-- Observability indexes
CREATE INDEX IF NOT EXISTS "AppLog_timestamp_idx" ON "AppLog"("timestamp");
CREATE INDEX IF NOT EXISTS "AppLog_level_timestamp_idx" ON "AppLog"("level", "timestamp");
CREATE INDEX IF NOT EXISTS "AppLog_userId_idx" ON "AppLog"("userId");
CREATE INDEX IF NOT EXISTS "AuditLog_timestamp_idx" ON "AuditLog"("timestamp");
CREATE INDEX IF NOT EXISTS "AuditLog_userId_timestamp_idx" ON "AuditLog"("userId", "timestamp");
CREATE INDEX IF NOT EXISTS "AuditLog_resourceType_idx" ON "AuditLog"("resourceType");

-- Data Lake indexes
CREATE UNIQUE INDEX IF NOT EXISTS "datasets_owner_name_key" ON datalake.datasets("ownerId", "name");
CREATE INDEX IF NOT EXISTS "datasets_owner_idx" ON datalake.datasets("ownerId");
CREATE INDEX IF NOT EXISTS "datasets_share_tag_idx" ON datalake.datasets("shareTagId") WHERE "shareType" = 'TAG';

-- Bot columns (upgrade)
DO `$`$ BEGIN
    ALTER TABLE "Bot" ADD COLUMN IF NOT EXISTS "url" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "Bot" ADD COLUMN IF NOT EXISTS "shareTagId" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;

-- Tag columns (upgrade)
DO `$`$ BEGIN
    ALTER TABLE "Tag" ADD COLUMN IF NOT EXISTS "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "Tag" ADD COLUMN IF NOT EXISTS "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;

-- Auth provider column (AD integration, for existing installs)
DO `$`$ BEGIN
    ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "authProvider" TEXT NOT NULL DEFAULT 'local';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "ldapAttributes" JSONB;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;

-- Approval notification webhook URL
DO `$`$ BEGIN
    ALTER TABLE "ApprovalFlow" ADD COLUMN IF NOT EXISTS "notificationWebhookUrl" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;

-- Brand customization columns (upgrade)
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "brandColor" TEXT NOT NULL DEFAULT 'default';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customLogoText" TEXT DEFAULT 'LL';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customLogoImage" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customTitle" TEXT DEFAULT 'LM LIGHT';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "sidebarItems" JSONB;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;
DO `$`$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "toolSettings" JSONB;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END `$`$;

-- SQL dialect abstraction was removed. Drop the column if it exists from an
-- older install and restore NOT NULL on the credential columns.
DO `$`$ BEGIN
    ALTER TABLE "SavedSqlConnection" DROP COLUMN IF EXISTS "dialect";
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN UPDATE "SavedSqlConnection" SET "host" = COALESCE("host", 'localhost') WHERE "host" IS NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN UPDATE "SavedSqlConnection" SET "port" = COALESCE("port", 5432) WHERE "port" IS NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN UPDATE "SavedSqlConnection" SET "dbUser" = COALESCE("dbUser", '') WHERE "dbUser" IS NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN UPDATE "SavedSqlConnection" SET "password" = COALESCE("password", '') WHERE "password" IS NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "SavedSqlConnection" ALTER COLUMN "host" SET NOT NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "SavedSqlConnection" ALTER COLUMN "port" SET NOT NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "SavedSqlConnection" ALTER COLUMN "dbUser" SET NOT NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "SavedSqlConnection" ALTER COLUMN "password" SET NOT NULL;
EXCEPTION WHEN undefined_table THEN null; END `$`$;
-- PostgreSQL schema selection (previously always hard-coded to 'public').
DO `$`$ BEGIN ALTER TABLE "SavedSqlConnection" ADD COLUMN IF NOT EXISTS "schema" TEXT NOT NULL DEFAULT 'public';
EXCEPTION WHEN undefined_table THEN null; END `$`$;

-- Toolable Pipeline (Action) — removed in role-A cleanup (drop if upgrading from an older install)
DO `$`$ BEGIN ALTER TABLE "Pipeline" DROP COLUMN IF EXISTS "exposeAsTool";
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "Pipeline" DROP COLUMN IF EXISTS "toolHint";
EXCEPTION WHEN undefined_table THEN null; END `$`$;
DO `$`$ BEGIN ALTER TABLE "Pipeline" DROP COLUMN IF EXISTS "toolMode";
EXCEPTION WHEN undefined_table THEN null; END `$`$;

-- 管理者ユーザー (admin@local / admin123)
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

-- 権限付与
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON SCHEMA pgvector TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA pgvector TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA pgvector TO $DB_USER;
GRANT ALL PRIVILEGES ON SCHEMA datalake TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA datalake TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA datalake TO $DB_USER;
"@

    $ErrorActionPreference = "Continue"
    $null = $SQL_MIGRATION | psql -q -U postgres -p $DB_PORT -d $DB_NAME 2>$null
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