#!/bin/bash
# AI Server Database Setup for macOS/Linux
#
# database.py を正解として schema 分離後の DDL を反映。
# schemas: public (主要 entity) / approval / helpdesk / vision / log / datalake / pgvector
# 追加 column / 既存環境からの移行は backend 起動時の migrations.py が冪等に処理する。
set -e

DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

echo "Setting up AI Server database..."

if ! command -v psql &>/dev/null; then
    echo "❌ PostgreSQL がインストールされていません。"
    echo ""
    echo "インストールしてから再度 install を実行してください:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew install postgresql@16"
        echo "   brew services start postgresql@16"
    else
        echo "   sudo apt install postgresql"
        echo "   sudo systemctl start postgresql"
    fi
    exit 1
fi

# Postgres 起動確認 (= ここで止めないと CREATE USER 等が Connection refused で連発する)
if ! pg_isready -q 2>/dev/null; then
    echo "❌ PostgreSQL に接続できません (localhost:5432)。"
    echo ""
    echo "起動してから再度 install を実行してください:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew services start postgresql@16"
    else
        echo "   sudo systemctl start postgresql"
    fi
    exit 1
fi

# Detect OS for psql connection method
if [[ "$OSTYPE" == "darwin"* ]]; then
    PSQL_ADMIN="psql -U postgres"
else
    PSQL_ADMIN="sudo -u postgres psql"
fi

# Create user and database
echo "Creating user and database..."
$PSQL_ADMIN -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
$PSQL_ADMIN -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
$PSQL_ADMIN -c "ALTER USER $DB_USER CREATEDB;" 2>/dev/null || true
if ! $PSQL_ADMIN -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "⚠️  pgvector 拡張の有効化に失敗しました。RAG 機能を利用する場合は pgvector を導入してください:" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew install pgvector" >&2
    else
        echo "   sudo apt install postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector" >&2
        echo "   (RHEL/CentOS): sudo dnf install pgvector" >&2
    fi
fi

# Run migrations
echo "Creating schemas, tables and indexes..."
PGPASSWORD=$DB_PASS psql -q -U $DB_USER -d $DB_NAME -h localhost << 'SQLEOF'
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
ALTER TABLE IF EXISTS public."AppLog" SET SCHEMA log;
ALTER TABLE IF EXISTS public."AuditLog" SET SCHEMA log;
-- YOLO + VisionAutomation は 2026-05 で _archived/ に移動。既存環境のテーブルは残す (dead)。

-- ── Enums ───────────────────────────────────────────────────────────────────
DO $$ BEGIN CREATE TYPE "UserRole" AS ENUM ('ADMIN', 'SUPER', 'USER'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "UserStatus" AS ENUM ('ACTIVE', 'INACTIVE'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "MessageRole" AS ENUM ('USER', 'ASSISTANT', 'SYSTEM'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "ShareType" AS ENUM ('PRIVATE', 'TAG'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "DocumentType" AS ENUM ('PDF', 'WEB', 'TEXT', 'CSV', 'EXCEL', 'WORD', 'IMAGE', 'JSON'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "ApprovalStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END $$;

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
    "fields" JSONB,
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

-- vision schema は _archived/yolo-feature/ に移動済 (YoloModel / VisionAutomationRule)

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
    '$2b$12$AIctg50Pbt418E7ir3HlUOP1HWKO4PSP01HfIsx8v6Ab.Td7G5h72',
    'ADMIN',
    'ACTIVE',
    CURRENT_TIMESTAMP
) ON CONFLICT ("id") DO NOTHING;
SQLEOF

echo "✅ Database setup complete"
