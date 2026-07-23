#!/bin/bash
set -euo pipefail

# ── pgbouncer config generation ──────────────────────────────────────────────
# Odoo (all tenants) connects to 127.0.0.1:6432 with ONE frontend credential
# (the platform user). pgbouncer maps each tenant database to that tenant's
# least-privilege PostgreSQL user (v2 Fix #4) and pools/caps connections to
# Cloud SQL (v2 Fix #2).
#
# Required env:
#   DB_HOST, DB_PORT          — Cloud SQL private IP / port
#   DB_USER, DB_PASSWORD      — platform frontend+fallback credential
# Optional env:
#   PGB_TENANTS               — "db:pg_user:PASSWORD_ENV_VAR;db2:user2:ENV2;..."
#                               each PASSWORD_ENV_VAR is injected from Secret Manager
#   PGB_LISTEN_PORT (6432), PGB_DEFAULT_POOL_SIZE (5), PGB_MAX_CLIENT_CONN (500),
#   PGB_MAX_DB_CONNECTIONS (10)

: "${DB_HOST:?DB_HOST is required}"
: "${DB_USER:?DB_USER is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"

DB_PORT="${DB_PORT:-5432}"
LISTEN_PORT="${PGB_LISTEN_PORT:-6432}"
DEFAULT_POOL_SIZE="${PGB_DEFAULT_POOL_SIZE:-5}"
MAX_CLIENT_CONN="${PGB_MAX_CLIENT_CONN:-500}"
MAX_DB_CONNECTIONS="${PGB_MAX_DB_CONNECTIONS:-10}"

INI=/etc/pgbouncer/pgbouncer.ini
AUTH=/etc/pgbouncer/userlist.txt

# Frontend auth: only the platform user may connect to the pooler (loopback only).
printf '"%s" "%s"\n' "${DB_USER}" "${DB_PASSWORD}" > "${AUTH}"
chmod 600 "${AUTH}"

{
  echo "[databases]"
  # Per-tenant entries: backend logs in as the tenant's own PG user.
  if [ -n "${PGB_TENANTS:-}" ]; then
    IFS=';' read -ra TENANTS <<< "${PGB_TENANTS}"
    for entry in "${TENANTS[@]}"; do
      [ -n "$entry" ] || continue
      IFS=':' read -r t_db t_user t_pass_env <<< "$entry"
      t_pass="${!t_pass_env:-}"
      if [ -z "$t_pass" ]; then
        echo "[pgbouncer-init] WARN: env ${t_pass_env} empty for db ${t_db}; falling back to platform user" >&2
        continue
      fi
      echo "${t_db} = host=${DB_HOST} port=${DB_PORT} dbname=${t_db} user=${t_user} password=${t_pass}"
    done
  fi
  # Fallback (postgres system db, un-mapped tenants): platform user credentials.
  echo "* = host=${DB_HOST} port=${DB_PORT}"
  echo ""
  echo "[pgbouncer]"
  echo "listen_addr = 0.0.0.0"
  echo "listen_port = ${LISTEN_PORT}"
  echo "auth_type = plain"
  echo "auth_file = ${AUTH}"
  # Odoo needs session-level features (LISTEN/NOTIFY for the bus, advisory
  # locks, savepoints across requests) → session pooling, not transaction.
  echo "pool_mode = session"
  echo "server_reset_query = DISCARD ALL"
  echo "default_pool_size = ${DEFAULT_POOL_SIZE}"
  echo "min_pool_size = 0"
  echo "max_client_conn = ${MAX_CLIENT_CONN}"
  echo "max_db_connections = ${MAX_DB_CONNECTIONS}"
  echo "server_idle_timeout = 300"
  echo "ignore_startup_parameters = extra_float_digits,options"
  echo "log_connections = 0"
  echo "log_disconnections = 0"
} > "${INI}"
chmod 600 "${INI}"

echo "[pgbouncer-init] Starting pgbouncer on :${LISTEN_PORT} → ${DB_HOST}:${DB_PORT} ($(grep -c '^[a-z]' "${INI}" || true) db entries)"
exec pgbouncer "${INI}"
