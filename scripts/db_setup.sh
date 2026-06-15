#!/bin/bash
# AI Server Database Setup for macOS/Linux
#
# superuser/owner でしかできない部分だけを担当する:
#   role / database / pgvector 拡張 / schema 作成。
# テーブル・index・ENUM・初期 admin user・既存環境からの ALTER は、backend 起動時の
# migrations.py が database.py のモデルから Base.metadata.create_all() で冪等に生成する
# (= ここで DDL を二重管理しない。それがスキーマのドリフト原因になるため)。
set -e

DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

echo "Setting up AI Server database..."

if ! command -v psql &>/dev/null; then
    echo "❌ PostgreSQL がインストールされていません。"
    echo ""
    echo "インストールしてから再度 install を実行してください (pgvector 対応・16 以降):"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   Homebrew:     brew install postgresql@16 pgvector && brew services start postgresql@16"
        echo "   または:       Postgres.app (postgresapp.com) / 公式インストーラ (postgresql.org) でも可"
        echo "   ※ brew は必須ではありません。pgvector 対応の PostgreSQL が起動していれば OK"
    else
        echo "   sudo apt install postgresql postgresql-\$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)-pgvector"
        echo "   起動: pg_ctlcluster <ver> main start  または  systemctl start postgresql"
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

# macOS の Homebrew / Postgres.app は "postgres" ロールを作らず、スーパーユーザー =
# ログイン OS ユーザーであることが多い (psql -U postgres は role does not exist で失敗)。
# → postgres ロールがあればそれを、無ければ OS ユーザー (= 既定 superuser) で接続する。
PG_SUPER=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    if psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
        PG_SUPER="postgres"
    fi
fi

# Run psql as the postgres superuser. Covers: macOS (postgres ロール or OS ユーザー),
# Linux non-root+sudo (sudo -u postgres), root-without-sudo container (su).
pg_admin() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        psql ${PG_SUPER:+-U "$PG_SUPER"} "$@"
    elif command -v sudo &>/dev/null && [ "$(id -u)" -ne 0 ]; then
        sudo -u postgres psql "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        su postgres -c "psql $(printf '%q ' "$@")"
    else
        psql -U postgres "$@"
    fi
}

# Create user and database (冪等 — 既存ならスキップ、失敗は警告)。
# -d postgres でメンテナンス DB に接続 (OS ユーザー名の DB は無いことが多いため明示)。
echo "Creating user and database..."
if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "⚠️  CREATE USER $DB_USER に失敗" >&2
fi
if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "⚠️  CREATE DATABASE $DB_NAME に失敗" >&2
fi
pg_admin -d postgres -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "⚠️  pgvector 拡張の有効化に失敗しました。RAG 機能を利用する場合は pgvector を導入してください:" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew install pgvector" >&2
    else
        echo "   sudo apt install postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector" >&2
        echo "   (RHEL/CentOS): sudo dnf install pgvector" >&2
    fi
fi

# ── Schemas only ──────────────────────────────────────────────────────────────
# テーブル / index / ENUM / 初期 admin user / 既存環境からの ALTER は、backend 起動時の
# migrations.py が database.py のモデルから Base.metadata.create_all() で冪等生成する。
# ここでは二重管理（=ドリフトの元）を避け、superuser/owner が事前に用意すべき schema だけ作る。
# schema 一覧は migrations.py と一致させること（public は default で常に存在）。
echo "Creating schemas..."
for sch in approval datalake helpdesk log pgvector vision; do
    pg_admin -d "$DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS $sch AUTHORIZATION \"$DB_USER\";" >/dev/null 2>&1 \
        || echo "⚠️  CREATE SCHEMA $sch に失敗" >&2
done

echo "✅ Database setup complete (= role / database / pgvector / schemas)"
echo "   ※ テーブル・index・初期 admin user (admin@local) はアプリ初回起動時に自動作成されます"
