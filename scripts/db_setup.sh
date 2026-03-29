#!/bin/bash
# AI Server Database Setup for macOS/Linux
set -e

DB_USER="${DB_USER:-lmlight}"
DB_PASS="${DB_PASS:-lmlight}"
DB_NAME="${DB_NAME:-lmlight}"

echo "Setting up AI Server database..."

if ! command -v psql &>/dev/null; then
    echo "❌ psql not found. Please install PostgreSQL first."
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
$PSQL_ADMIN -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true

# Run migrations
echo "Creating tables..."
PGPASSWORD=$DB_PASS psql -q -U $DB_USER -d $DB_NAME -h localhost << 'SQLEOF'
-- Enums
DO $$ BEGIN CREATE TYPE "UserRole" AS ENUM ('ADMIN', 'SUPER', 'USER'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "UserStatus" AS ENUM ('ACTIVE', 'INACTIVE'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "MessageRole" AS ENUM ('USER', 'ASSISTANT', 'SYSTEM'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "ShareType" AS ENUM ('PRIVATE', 'TAG'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "DocumentType" AS ENUM ('PDF', 'WEB', 'TEXT', 'CSV', 'EXCEL', 'WORD', 'IMAGE', 'JSON'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE "ApprovalStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- Tables
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
    "maxTokens" INTEGER NOT NULL DEFAULT 2048,
    "numCtx" INTEGER NOT NULL DEFAULT 8192,
    "topP" DOUBLE PRECISION NOT NULL DEFAULT 0.9,
    "topK" INTEGER NOT NULL DEFAULT 40,
    "repeatPenalty" DOUBLE PRECISION NOT NULL DEFAULT 1.1,
    "reasoningMode" TEXT NOT NULL DEFAULT 'normal',
    "ragTopK" INTEGER NOT NULL DEFAULT 5,
    "ragMinSimilarity" DOUBLE PRECISION NOT NULL DEFAULT 0.45,
    "embeddingModel" TEXT NOT NULL DEFAULT 'embeddinggemma:latest',
    "chunkSize" INTEGER NOT NULL DEFAULT 500,
    "chunkOverlap" INTEGER NOT NULL DEFAULT 100,
    "visionModel" TEXT,
    "brandColor" TEXT NOT NULL DEFAULT 'default',
    "customLogoText" TEXT DEFAULT 'LL',
    "customLogoImage" TEXT,
    "customTitle" TEXT DEFAULT 'LM LIGHT',
    "sidebarItems" JSONB,
    "sqlConnection" JSONB,
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

DO $$ BEGIN
    ALTER TABLE "Bot" ADD COLUMN IF NOT EXISTS "url" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

DO $$ BEGIN
    ALTER TABLE "Bot" ADD COLUMN IF NOT EXISTS "shareTagId" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

DO $$ BEGIN
    ALTER TABLE "Tag" ADD COLUMN IF NOT EXISTS "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN
    ALTER TABLE "Tag" ADD COLUMN IF NOT EXISTS "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

-- Auth provider column (AD integration)
DO $$ BEGIN
    ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "authProvider" TEXT NOT NULL DEFAULT 'local';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

-- Approval notification webhook URL
DO $$ BEGIN
    ALTER TABLE "ApprovalFlow" ADD COLUMN IF NOT EXISTS "notificationWebhookUrl" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

-- Brand customization columns
DO $$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "brandColor" TEXT NOT NULL DEFAULT 'default';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customLogoText" TEXT DEFAULT 'LL';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customLogoImage" TEXT;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "customTitle" TEXT DEFAULT 'LM LIGHT';
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN
    ALTER TABLE "DefaultSetting" ADD COLUMN IF NOT EXISTS "sidebarItems" JSONB;
EXCEPTION WHEN undefined_table THEN null; WHEN duplicate_column THEN null; END $$;

-- Rename from UserSettings if upgrading
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'UserSettings' AND table_schema = 'public') THEN
        ALTER TABLE "UserSettings" RENAME TO "DefaultSetting";
    END IF;
END $$;

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

-- Indexes
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
CREATE INDEX IF NOT EXISTS idx_bot_user ON pgvector.embeddings (bot_id, user_id);
CREATE INDEX IF NOT EXISTS idx_document ON pgvector.embeddings (document_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw ON pgvector.embeddings USING hnsw (embedding vector_cosine_ops);

-- Admin user (admin@local / admin123)
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

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO lmlight;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO lmlight;
GRANT ALL PRIVILEGES ON SCHEMA pgvector TO lmlight;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA pgvector TO lmlight;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA pgvector TO lmlight;
SQLEOF

echo "✅ Database setup complete"
