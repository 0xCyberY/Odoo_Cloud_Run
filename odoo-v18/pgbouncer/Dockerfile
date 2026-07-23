# pgbouncer sidecar for Odoo Cloud Run services (v2 Fixes #2 & #4).
# Owned in Artifact Registry because Cloud Run cannot pull from Docker Hub.
FROM alpine:3.20

RUN apk add --no-cache pgbouncer bash \
    && mkdir -p /etc/pgbouncer /var/run/pgbouncer \
    && adduser -D -S pgbouncer-usr \
    && chown -R pgbouncer-usr /etc/pgbouncer /var/run/pgbouncer

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER pgbouncer-usr
ENTRYPOINT ["/entrypoint.sh"]
