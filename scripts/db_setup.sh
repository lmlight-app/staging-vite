#!/bin/bash
# AI Server Database Setup for macOS/Linux
# superuser/owner でしかできない部分だけ担当 (role/database/pgvector拡張/schema)。table以降はmigrations.pyが冪等生成
set -e

DB_USER="${DB_USER:-digitalbase}"
DB_PASS="${DB_PASS:-digitalbase}"
DB_NAME="${DB_NAME:-digitalbase}"

echo "Setting up AI Server database..."

if ! command -v psql &>/dev/null; then
    echo "[ERROR] PostgreSQL がインストールされていません。"
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
    echo "[ERROR] PostgreSQL に接続できません (localhost:5432)。"
    echo ""
    echo "起動してから再度 install を実行してください:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew services start postgresql@16"
    else
        echo "   sudo systemctl start postgresql"
    fi
    exit 1
fi

# macOS の Homebrew/Postgres.app は postgres ロール未作成が多い (OSユーザー=superuser)。あれば使う
PG_SUPER=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    if psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
        PG_SUPER="postgres"
    fi
fi

# postgres superuser として psql 実行 (macOS/Linux sudo/rootless container を吸収)
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

# user/database 作成 (冪等、-d postgres でメンテナンスDBに接続)
echo "Creating user and database..."
if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "[WARN] CREATE USER $DB_USER に失敗" >&2
fi
if [ -z "$(pg_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)" ]; then
    pg_admin -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" || echo "[WARN] CREATE DATABASE $DB_NAME に失敗" >&2
fi
pg_admin -d postgres -c "ALTER USER $DB_USER CREATEDB;" >/dev/null 2>&1 || true
if ! pg_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "[WARN] pgvector 拡張の有効化に失敗しました。RAG 機能を利用する場合は pgvector を導入してください:" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   brew install pgvector" >&2
    else
        echo "   sudo apt install postgresql-\$(psql -V | grep -oE '[0-9]+' | head -1)-pgvector" >&2
        echo "   (RHEL/CentOS): sudo dnf install pgvector" >&2
    fi
fi

# schema のみ作成 (table/index は migrations.py が冪等生成、一覧は migrations.py と一致させる)
echo "Creating schemas..."
for sch in approval datalake helpdesk log pgvector vision; do
    pg_admin -d "$DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS $sch AUTHORIZATION \"$DB_USER\";" >/dev/null 2>&1 \
        || echo "[WARN] CREATE SCHEMA $sch に失敗" >&2
done

echo "[OK] Database setup complete (= role / database / pgvector / schemas)"
echo "   ※ テーブル・index・初期 admin user (admin@local) はアプリ初回起動時に自動作成されます"
