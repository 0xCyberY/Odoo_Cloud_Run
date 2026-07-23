#!/bin/bash
set -euo pipefail

# ── Tenant database hardening (v2 Fixes #2 & #4) ─────────────────────────────
# Runs as a Cloud Run Job after the tenant DB + user are created by Terraform.
# Connects as the platform admin user (odoo_shared) and:
#   1. Restricts CONNECT on the tenant DB to its own least-privilege user
#   2. Transfers DB (and existing object) ownership to the tenant user
#   3. Applies noisy-neighbor limits (statement_timeout, connection limit)
#
# Required env:
#   DB_HOST, DB_PORT, DB_USER, DB_PASSWORD  — platform admin connection
#   TENANT_DB, TENANT_USER                  — tenant database and its PG user
# Optional env:
#   STATEMENT_TIMEOUT_MS (default 3600000), CONNECTION_LIMIT (default 20)

: "${DB_HOST:?DB_HOST is required}"
: "${DB_USER:?DB_USER is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${TENANT_DB:?TENANT_DB is required}"
: "${TENANT_USER:?TENANT_USER is required}"

export PGHOST="${DB_HOST}"
export PGPORT="${DB_PORT:-5432}"
export PGUSER="${DB_USER}"
export PGPASSWORD="${DB_PASSWORD}"

STATEMENT_TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-3600000}"
CONNECTION_LIMIT="${CONNECTION_LIMIT:-20}"

echo "[db-setup] Hardening tenant database '${TENANT_DB}' for user '${TENANT_USER}'..."

# On Cloud SQL there is no real superuser; to ALTER ... OWNER the admin user
# must be a member of the target role. Grant membership to ourselves first.
psql -v ON_ERROR_STOP=1 -d postgres <<SQL
GRANT "${TENANT_USER}" TO CURRENT_USER;
SQL

psql -v ON_ERROR_STOP=1 -d postgres <<SQL
REVOKE CONNECT ON DATABASE "${TENANT_DB}" FROM PUBLIC;
GRANT  CONNECT ON DATABASE "${TENANT_DB}" TO "${TENANT_USER}";
GRANT  CONNECT ON DATABASE "${TENANT_DB}" TO "${DB_USER}";
ALTER DATABASE "${TENANT_DB}" OWNER TO "${TENANT_USER}";
ALTER ROLE "${TENANT_USER}" SET statement_timeout = '${STATEMENT_TIMEOUT_MS}';
ALTER ROLE "${TENANT_USER}" CONNECTION LIMIT ${CONNECTION_LIMIT};
SQL

# Reassign pre-existing objects (tenants initialized before per-tenant users
# existed were owned by the platform admin user). Scoped to the tenant DB.
psql -v ON_ERROR_STOP=1 -d "${TENANT_DB}" <<SQL
REASSIGN OWNED BY "${DB_USER}" TO "${TENANT_USER}";
SQL

# ── Odoo admin credential sync ───────────────────────────────────────────────
# 'odoo -i base' leaves the admin account as admin/admin — unacceptable on a
# public URL. Set the tenant's real login + generated password (Secret Manager).
# Odoo accepts a plaintext value in res_users.password and re-hashes it on the
# first successful login. Skipped gracefully on the pre-init run (no res_users
# table yet); provision.py re-runs this job after the init job.
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    if psql -d "${TENANT_DB}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='res_users'" | grep -q 1; then
        psql -v ON_ERROR_STOP=1 -d "${TENANT_DB}" <<SQL
UPDATE res_users
SET login = '${TENANT_ADMIN_LOGIN:-admin}',
    password = \$odoo_pw\$${ADMIN_PASSWORD}\$odoo_pw\$
WHERE id = 2;  -- id 2 = the admin user created by base
SQL
        echo "[db-setup] Odoo admin credentials synced (login=${TENANT_ADMIN_LOGIN:-admin})."
    else
        echo "[db-setup] res_users not present yet (pre-init run) — admin sync skipped."
    fi
fi

echo "[db-setup] Done: '${TENANT_DB}' owned by '${TENANT_USER}', connect restricted, statement_timeout=${STATEMENT_TIMEOUT_MS}ms, connection_limit=${CONNECTION_LIMIT}."
