# ==============================================================================
# STAGE 1: Base Odoo + Python dependencies + platform modules
# ==============================================================================
# Pin to a specific Odoo 18.0 release tag for reproducible builds.
# Update this tag periodically after testing: https://hub.docker.com/_/odoo/tags
FROM odoo:18.0 AS odoo-base
USER root

# git: clone platform modules; postgresql-client: tenant DB setup job (db-setup.sh)
# --ignore-installed: the odoo base image ships Debian-managed Python packages
# (typing_extensions et al.) that pip cannot uninstall (no RECORD file); install
# fresh copies over them instead of failing.
# pyopenssl: MUST be listed — pip upgrades cryptography as a transitive dep, and
# Debian's old pyOpenSSL cannot import against it ("module 'lib' has no
# attribute 'GEN_EMAIL'"), which kills Odoo's base module. Installing pyopenssl
# from pip keeps the pyOpenSSL↔cryptography pair consistent in /usr/local.
# pandas<3: pandas 3.0 has breaking API changes; stay on 2.x until addons are tested.
# pyjwt onward (through SQLAlchemy below): catalog-repo modules need these —
# either imported directly in code, or declared in a manifest's
# `external_dependencies.python` (which Odoo checks via
# importlib.metadata.version(name) against the EXACT declared string before
# even importing the module, independent of whatever the code actually
# imports — e.g. auto_database_backup's manifest declares both
# "nextcloud-api-wrapper" AND "pyncclient", but its code only ever imports
# `nextcloud_client`, which pyncclient provides; nextcloud-api-wrapper is
# needed purely to satisfy the manifest check). None of this is caught at
# build time — client catalog content (build-addons/, stage 2) isn't
# present yet when this stage's build-time assertions run. First surfaced
# as ModuleNotFoundError: No module named 'jwt' during a real tenant
# onboarding, then 'pyparsing' on the next attempt; the rest were found in
# two passes — diffing every top-level import across the whole cloned
# catalog against this image's installed packages, then parsing every
# manifest's external_dependencies directly (the more reliable signal,
# since Odoo validates those before an install can even start). Package
# name vs. import/declared name differs for several of these:
# guardrails-ai -> `guardrails`, pyncclient -> `nextcloud_client`,
# odoo-test-helper -> `odoo_test_helper`, gtts -> declared as "gTTS".
# See README §16.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages --ignore-installed \
        pyopenssl \
        packaging \
        redis \
        "fsspec>=2025.3.0" \
        gcsfs \
        google-cloud-storage \
        "pandas<3" \
        numpy \
        openpyxl \
        xlrd \
        xlwt \
        pyjwt \
        pyparsing \
        firebase-admin \
        gtts \
        guardrails-ai \
        pyncclient \
        nextcloud-api-wrapper \
        odoo-test-helper \
        pydantic \
        tabulate \
        boto3 \
        dropbox \
        paramiko \
        SQLAlchemy

# Platform modules (public repos, no token required):
#   session_redis            (camptocamp/odoo-cloud-platform) — sessions in Memorystore Redis
#   fs_storage + fs_attachment (OCA/storage)                  — attachments in GCS via fsspec/gcsfs
# IMPORTANT: /opt/extra-addons, NOT /mnt/extra-addons — the odoo base image
# declares VOLUME /mnt/extra-addons, and Docker DISCARDS anything a build step
# writes into a parent-image volume path (this silently emptied the modules
# in v1). The assertions below guard against regressions.
RUN mkdir -p /opt/extra-addons \
    && git clone --depth 1 -b 18.0 https://github.com/camptocamp/odoo-cloud-platform.git /tmp/odoo-cloud-platform \
    && cp -r /tmp/odoo-cloud-platform/session_redis /opt/extra-addons/ \
    && rm -rf /tmp/odoo-cloud-platform \
    && git clone --depth 1 -b 18.0 https://github.com/OCA/storage.git /tmp/oca-storage \
    && cp -r /tmp/oca-storage/fs_storage /tmp/oca-storage/fs_attachment /opt/extra-addons/ \
    && rm -rf /tmp/oca-storage \
    && git clone --depth 1 -b 18.0 https://github.com/OCA/server-env.git /tmp/oca-server-env \
    && cp -r /tmp/oca-server-env/server_environment /opt/extra-addons/ \
    && rm -rf /tmp/oca-server-env

# Build-time assertions: fail the BUILD (not a probe timeout at deploy) if any
# platform module or its Python stack is broken.
RUN test -f /opt/extra-addons/session_redis/__manifest__.py \
    && test -f /opt/extra-addons/fs_storage/__manifest__.py \
    && test -f /opt/extra-addons/fs_attachment/__manifest__.py \
    && test -f /opt/extra-addons/server_environment/__manifest__.py \
    && python3 -c "import OpenSSL.crypto, redis, gcsfs, packaging.requirements; print('python stack OK')" \
    && python3 -c "import odoo; print('odoo imports OK')"

# Repo-owned platform addons (e.g. gcs_attachment_default) — v2 Fix #6:
# owned in the base image and covered by the CI smoke test on every upgrade.
COPY addons/ /mnt/platform-addons/
RUN test -f /mnt/platform-addons/gcs_attachment_default/__manifest__.py \
    && test -f /mnt/platform-addons/platform_dblist/__manifest__.py \
    && test -f /mnt/platform-addons/addon_entitlement/__manifest__.py \
    && test -f /mnt/platform-addons/platform_cron_safety/__manifest__.py

# ==============================================================================
# STAGE 2: Pooled Tier Image — full addon catalog for ALL tenants
# ==============================================================================
# build-addons/ is populated by scripts/prepare_addons.py from clients.yaml
# (common repo + every client's addon repos). All tenants share this image;
# isolation is per-database: each tenant only installs its own modules.
FROM odoo-base AS odoo-pooled
COPY build-addons/ /mnt/custom-shared/

COPY entrypoint.sh /entrypoint.sh
COPY db-setup.sh /db-setup.sh
RUN chmod +x /entrypoint.sh /db-setup.sh \
    && chown -R odoo:odoo /opt/extra-addons /mnt/platform-addons /mnt/custom-shared /etc/odoo

USER odoo
ENTRYPOINT ["/entrypoint.sh"]
