#!/bin/bash
set -eo pipefail

# ── Dynamic Configuration Generation ─────────────────────────────────────────
# Runs at container startup inside Cloud Run to assemble odoo.conf.
#
# ODOO_MODE selects the service role (v2 architecture):
#   web (default) — pooled HTTP service: threaded, no cron threads, dbfilter=^%h$
#   cron          — single Cron Runner: cron threads enabled, serves all tenant DBs
#   websocket     — gevent worker for /websocket (longpolling, chat, notifications)

ODOO_MODE="${ODOO_MODE:-web}"
HTTP_PORT="${PORT:-8069}"
DB_HOST_EFFECTIVE="${DB_HOST:-localhost}"
DB_USER_EFFECTIVE="${DB_USER:-odoo}"
DB_PASSWORD_EFFECTIVE="${DB_PASSWORD:-odoo}"
DB_PORT_EFFECTIVE="${DB_PORT:-5432}"

# ── Addons path ──────────────────────────────────────────────────────────────
# /opt/extra-addons     — platform modules (session_redis, fs_storage, fs_attachment)
#                         (/opt, NOT /mnt/extra-addons: that path is a VOLUME in
#                         the odoo base image and build-time content is discarded)
# /mnt/platform-addons  — repo-owned modules (gcs_attachment_default)
# /mnt/custom-shared/*  — one sub-directory per addon repo from clients.yaml
#                         (common + all client repos; tenants install only theirs)
ADDONS_PATH="/opt/extra-addons,/mnt/platform-addons"
if [ -d /mnt/custom-shared ]; then
    for dir in /mnt/custom-shared/*/; do
        [ -d "$dir" ] || continue
        ADDONS_PATH="${ADDONS_PATH},${dir%/}"
    done
fi
ADDONS_PATH="${ADDONS_PATH},/usr/lib/python3/dist-packages/odoo/addons"

# Tenant-specific addons mount point (future dedicated tier)
if [ -d "/mnt/client-addons" ]; then
    ADDONS_PATH="/mnt/client-addons,$ADDONS_PATH"
fi

# ── Mode-specific settings ───────────────────────────────────────────────────
MAX_CRON_THREADS_EFFECTIVE=0
# Hostname → database resolution (hybrid): a request Host matches a database
# named after its SUBDOMAIN (%d, e.g. beta.droob.app → beta) OR its FULL host
# (%h, for first-label collisions: super.droob.com → db "super.droob.com").
# clients.yaml validation guarantees exactly one match per host.
DB_FILTER_EFFECTIVE="${DB_FILTER:-^(%d|%h)\$}"
DB_ROUTING_DIRECTIVES="dbfilter = ${DB_FILTER_EFFECTIVE}"

case "$ODOO_MODE" in
  cron)
    # Only the Cron Runner processes scheduled jobs (v2 Fix #8). It services
    # every tenant database listed in ODOO_DATABASES (comma-separated).
    MAX_CRON_THREADS_EFFECTIVE="${MAX_CRON_THREADS:-2}"
    if [ -z "${ODOO_DATABASES:-}" ]; then
        echo "[ERROR] ODOO_MODE=cron requires ODOO_DATABASES (comma-separated tenant DB list)" >&2
        exit 1
    fi
    DB_ROUTING_DIRECTIVES="db_name = ${ODOO_DATABASES}"
    ;;
  websocket|web)
    ;;
  *)
    echo "[ERROR] Unknown ODOO_MODE '$ODOO_MODE' (expected web|cron|websocket)" >&2
    exit 1
    ;;
esac

# Sessions in Redis (camptocamp session_redis) must be loaded server-wide
SERVER_WIDE_MODULES="base,web"
if [ -n "${REDIS_HOST:-}" ]; then
    SERVER_WIDE_MODULES="${SERVER_WIDE_MODULES},session_redis"
fi
# Env-driven database discovery: core list_dbs() only shows databases OWNED by
# the connecting role, and tenant DBs are owned by their own users (Fix #4) —
# without this, every host lands on the database selector.
if [ -n "${ODOO_DATABASES:-}" ]; then
    SERVER_WIDE_MODULES="${SERVER_WIDE_MODULES},platform_dblist"
fi

# ── Write odoo.conf ──────────────────────────────────────────────────────────
mkdir -p /var/lib/odoo
cat <<EOF > /etc/odoo/odoo.conf
[options]
addons_path = ${ADDONS_PATH}
data_dir = /var/lib/odoo
http_port = ${HTTP_PORT}
gevent_port = ${HTTP_PORT}
proxy_mode = True
server_wide_modules = ${SERVER_WIDE_MODULES}

# Database connection (via pgbouncer sidecar on 127.0.0.1:6432 in Cloud Run)
db_host = ${DB_HOST_EFFECTIVE}
db_port = ${DB_PORT_EFFECTIVE}
db_user = ${DB_USER_EFFECTIVE}
db_password = ${DB_PASSWORD_EFFECTIVE}
db_maxconn = ${DB_MAXCONN:-16}

# Multi-tenant isolation & routing
list_db = False
${DB_ROUTING_DIRECTIVES}

# Required by OCA server_environment (dependency of fs_storage)
running_env = ${RUNNING_ENV:-prod}

# Concurrency & scaling (Cloud Run)
# 0 workers = multi-threaded mode: one container instance handles multiple
# concurrent requests with threads, matching Cloud Run's concurrency model.
workers = 0
max_cron_threads = ${MAX_CRON_THREADS_EFFECTIVE}

# Performance limits (aligned with the 3600s ALB/Cloud Run request timeout)
limit_time_cpu = 3600
limit_time_real = 3600
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
EOF

# Restrict odoo.conf permissions so the DB password is not world-readable
chmod 640 /etc/odoo/odoo.conf

# ── Redis Session Storage (camptocamp session_redis) ─────────────────────────
if [ -n "${REDIS_HOST:-}" ]; then
    export ODOO_SESSION_REDIS=1
    export ODOO_SESSION_REDIS_HOST="${REDIS_HOST}"
    export ODOO_SESSION_REDIS_PORT="${REDIS_PORT:-6379}"
    # session_redis 18.0 defaults SSL to ON (camptocamp's platform uses TLS
    # Redis). Memorystore BASIC has no TLS — the handshake hangs ~60s per
    # request. Set REDIS_SSL=1 only if transit encryption is enabled.
    export ODOO_SESSION_REDIS_SSL="${REDIS_SSL:-0}"
    # Only export a password when one is actually set: an EMPTY value makes
    # redis-py send AUTH "" to a no-auth Memorystore, which errors and breaks
    # every HTTP request (sessions are touched on all requests, incl. probes).
    if [ -n "${REDIS_PASSWORD:-}" ]; then
        export ODOO_SESSION_REDIS_PASSWORD="${REDIS_PASSWORD}"
    fi
    export ODOO_SESSION_REDIS_PREFIX="${ODOO_SESSION_REDIS_PREFIX:-odoo-session}"
    echo "Sessions stored in Redis at ${REDIS_HOST}:${REDIS_PORT:-6379}"
fi

# ── Execute Odoo ─────────────────────────────────────────────────────────────
case "$ODOO_MODE" in
  websocket)
    echo "Starting Odoo gevent (websocket) worker on port ${HTTP_PORT}..."
    exec odoo gevent --config=/etc/odoo/odoo.conf "$@"
    ;;
  cron)
    echo "Starting Odoo Cron Runner (max_cron_threads=${MAX_CRON_THREADS_EFFECTIVE}) for DBs: ${ODOO_DATABASES}..."
    exec odoo --config=/etc/odoo/odoo.conf "$@"
    ;;
  *)
    echo "Starting Odoo web on port ${HTTP_PORT} in threaded mode with dbfilter=${DB_FILTER_EFFECTIVE}..."
    exec odoo --config=/etc/odoo/odoo.conf "$@"
    ;;
esac
