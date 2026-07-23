# Prompt: Generate a DevOps + Security deep-dive deck (Gemini / NotebookLM)

> **How to use this**
> - **NotebookLM:** upload `README.md` (and optionally `docs/architecture-v2.svg`) as **Sources**, then paste everything under the line `=== PROMPT START ===` into the chat / "Customize" box when generating the Audio/Report or a slide outline. NotebookLM will ground the deck in the README; the prompt tells it *how* to structure it.
> - **Gemini (Advanced / Canvas / Slides):** paste the whole prompt below. It is self-contained — it embeds a project brief so Gemini can build the deck even without the repo. If you can attach `README.md`, do so and add: *"Prefer the attached README as the source of truth over the brief."*
> - Ask for the output as a **slide-by-slide outline with speaker notes** first; then, in Google Slides / Canvas, ask it to "turn this into slides."

---

=== PROMPT START ===

You are a principal cloud architect and technical writer. Produce a **comprehensive, presentation-ready slide deck** that explains a production multi-tenant SaaS platform to two internal audiences in the **same deck** but with clearly labelled lenses:

1. **DevOps / Platform Engineering** — how it is built, deployed, operated, scaled, and recovered.
2. **Security / GRC** — the threat model, isolation guarantees, least-privilege design, secrets, network posture, and the known risks and their mitigations.

## Output format (follow exactly)
- Produce a **slide-by-slide outline**. For **every** slide give: a **slide title**, **3–6 concise bullet points** (what appears on the slide), and a **"Speaker notes"** paragraph (4–8 sentences) that a presenter reads aloud to explain the slide in depth.
- Where a diagram helps, include an **ASCII / mermaid diagram** in the slide body and describe it in the notes.
- Tag each slide with an audience chip: **[DevOps]**, **[Security]**, or **[Both]**.
- After each major section, add a **"Q&A — anticipated questions"** slide with **5–8 realistic questions and thorough answers** (the questions a skeptical senior DevOps or security engineer would actually ask).
- End with two dedicated deep Q&A appendices: **"Security review Q&A" (12+ Q/A)** and **"Operations & on-call Q&A" (12+ Q/A)**.
- Keep it technically precise. Do **not** oversimplify or invent features not in the brief. If something is a known weakness, say so plainly — this audience values honesty over polish.
- Target length: **45–60 slides**. Use clear, jargon-correct language. Expand every acronym on first use.

## Required sections and the points each MUST cover in detail

### 1. Title + Executive summary [Both]
Multi-tenant **Odoo 18** ERP hosting on **Google Cloud Run**. One shared container image serving all tenants; tenants isolated **per PostgreSQL database**; per-tenant addon **entitlements enforced at runtime**. Emphasise the three pillars: **cost efficiency (pooled), tenant isolation (defense-in-depth), and operational safety (canary + rollback + IaC)**.

### 2. High-level architecture [Both]
Walk the request path end to end: Internet → tenant domain DNS → **Global External Application Load Balancer** (static IP, Google-managed SSL) → **Cloud CDN** (static assets) → **Cloud Armor** (WAF + per-IP login throttle + per-tenant Host rate limit) → **URL map** (`/websocket*` → websocket service, everything else → pooled service) → Cloud Run. Data plane (private IPs only, Shared VPC, Direct VPC Egress): **Cloud SQL PostgreSQL 16**, **Memorystore Redis**, **per-tenant GCS buckets**, **Secret Manager**. Control plane: **Cloud Tasks** (heavy ops), **Cloud Run Jobs** (db-setup / init / migration), **Cloud Workflows** (sequential fleet migration).

### 3. The three Cloud Run services [DevOps]
One image, three run modes selected by `ODOO_MODE` (entrypoint generates `odoo.conf`):
- **pooled-odoo** — web tier, threaded (`workers=0`), `dbfilter=^(%d|%h)$`, `max_cron_threads=0`, 3600s timeout, min-instances=1 (no cold starts).
- **websocket-odoo** — gevent worker for `/websocket` (chat/longpolling/bus), session affinity.
- **cron-runner-odoo** — the ONLY service that runs scheduled jobs (`max_instances=1`, internal-only, CPU always allocated), services every tenant DB from `ODOO_DATABASES`.
Each service runs a **pgbouncer sidecar**.

### 4. Tenant routing model [Both]
`dbfilter = ^(%d|%h)$` maps a request Host to exactly one database: `%d` = first label of host (`beta.droob.app` → db `beta`), `%h` = full host (for first-label collisions). `list_db=False`. Three enforcement gates: `validate_clients.py`, Terraform preconditions on the SSL cert, and Odoo itself. Explain why an unmatched host safely dead-ends.

### 5. Tenant isolation — defense in depth [Security]
Table of layers, each with the mechanism and what it stops:
- Edge: per-tenant (Host) rate limit (Cloud Armor).
- App: `dbfilter` + `list_db=False`.
- **Connection: pgbouncer maps each database to that tenant's own least-privilege PostgreSQL user.**
- Database: `REVOKE CONNECT FROM PUBLIC`; tenant user owns only its DB.
- DB resources: per-role `statement_timeout` + `CONNECTION LIMIT`.
- Storage: one GCS bucket per tenant, IAM per bucket.
- Secrets: one Secret Manager secret per tenant credential.
- Modules: entitlement gating (see §9).
Stress the principle: a failure at any single layer does not expose another tenant.

### 6. pgbouncer — per-tenant credentials on a pooled process [Security/DevOps]
Explain the core problem and solution: a pooled Odoo process has ONE `db_user`, so it cannot present different PostgreSQL credentials per database. The pgbouncer sidecar rewrites credentials per database: Odoo connects to `127.0.0.1:6432` as the platform user `odoo_shared` (valid only on loopback), pgbouncer authenticates locally then connects to Cloud SQL **as that tenant's own PG user**, which can connect only to that tenant's DB. Also covers connection-exhaustion protection (`default_pool_size`, `max_db_connections`). Tenant map + passwords come from `clients.yaml` + Secret Manager via Terraform.

### 7. Sessions, attachments, cron [DevOps]
- **Sessions → Memorystore Redis** (`session_redis`, server-wide) so instances are stateless.
- **Attachments → GCS** via OCA `fs_storage`/`fs_attachment`. **IMPORTANT nuance:** the storage backend (protocol, bucket, credentials, default-for-attachments) is configured through the OCA **`server_environment`** module via the `SERVER_ENV_CONFIG` env var (section `[fs_storage.gcs_att]`), NOT via database fields. With `fs_attachment`'s force-DB rules, JS/CSS **asset bundles are stored in the database** (survive container recycles) and other attachments go to **GCS**. Explain why this matters: Cloud Run's local filestore is **ephemeral**, so anything left on local disk is lost on every revision roll / cold start.
- **Cron → one dedicated runner** (no duplicate scheduled jobs across autoscaled replicas).

### 8. Secrets management [Security]
Per-secret ownership table (who creates, who reads): `odoo-shared-db-password`, per-tenant `<slug>-db-password`, per-tenant `<slug>-admin-user`/`-admin-password`, `odoo-shared-admin-password`. Rules: no secret value in code or state (only references); each service account granted `secretAccessor` on exactly the secrets it needs; grants-before-consumers ordering enforced in Terraform (`depends_on`) plus a 30s retry to absorb IAM propagation lag.

### 9. Addon catalog & per-tenant entitlements [Both — this is a headline feature]
- **Code plane:** the pooled image bakes the ENTIRE sellable addon catalog (every repo), so selling an addon never requires an image rebuild.
- **Entitlement plane:** `ODOO_ENTITLEMENTS` env (database → list of catalog dirs), rendered by Terraform from each client's `addon_repos` in `clients.yaml`, delivered to all three services.
- **Enforcement:** a platform Odoo module **`addon_entitlement`** installed in every tenant DB: (a) hides un-entitled, uninstalled modules from the Apps list / search; (b) a **hard install/upgrade/state-change gate** that refuses un-entitled modules and their dependency closure; (c) blocks `base_import_module` (zip sideloading = arbitrary code); (d) a daily **audit cron** that logs `ENTITLEMENT_VIOLATION`, wired to a Cloud Monitoring alert.
- **Trust boundary (security-critical):** the gate is bypassed ONLY in operator-run Cloud Run Jobs, identified by the `ODOO_ENTITLEMENT_BYPASS=1` env var that the long-running services never set — NOT by "is there an HTTP request", because a tenant admin's `ir.cron` scheduled action also runs without a request. Explain the vulnerability this closed and why env-based is the correct boundary (tenants cannot set container env).
- **Honest limitation:** this is a paywall with detection, not a vault. A tenant admin with Odoo `group_system` can still run arbitrary SQL/Python; the durable hardening is to deny Technical/Settings rights and/or use the future dedicated per-tenant tier. Say this explicitly to the security team.

### 10. Infrastructure as Code — two Terraform stacks [DevOps]
- **`terraform/shared`** (apply once, re-apply on `clients.yaml` change): VPC/peering, Cloud SQL, Redis, Artifact Registry, Cloud Armor, ALB (cert/URL map/backends), the three services, per-tenant SQL users + password secrets, Cloud Tasks, the fleet-migration Workflow, monitoring. Explain WHY tenant SQL users live here (avoids a chicken-and-egg race with the pooled service's pgbouncer secret references) and why one apply updates users, secrets, pgbouncer map, cert domains, and uptime checks atomically.
- **`terraform/` per-tenant workspace**: tenant database, GCS bucket + IAM, the three Cloud Run Jobs, optional DNS.
- The managed SSL cert name embeds a **hash of the domain set** with `create_before_destroy` (certs are immutable and can't be destroyed while attached to the proxy).

### 11. CI/CD pipelines [DevOps]
- **The upgrade model:** an addon update is TWO operations — **code** (image rebuild → rolls to every tenant at once) and **database** (schema/data migration via `-u`, only for the tenant(s) it's run for). Explain the three per-tenant Jobs (db-setup / init / migration) and the two callers of the migration job.
- **`deploy-fleet.yml`** (the safe fleet upgrade): build → smoke test on disposable Postgres → no-traffic revision → re-point jobs → **sequential fleet migration (halt-on-fail, resumable)** → **canary 10→50→100% health-gated with instant rollback** → finalize.
- **`update-addon.yml`** (one module, one tenant) with a CI entitlement guard.
- **`provision-client.yml` / `destroy-client.yml`.**
- Auth via **Workload Identity Federation** (no long-lived keys).

### 12. Provisioning & offboarding runbooks [DevOps]
Summarise onboarding a new tenant (clients.yaml + tfvars → DNS → provision → verify → install paid modules) and the offboarding ordering hazards (cron auto-creates DBs; tenant-owned DBs can't be dropped via the Cloud SQL API; SQL user can't be dropped while it owns the DB). Include the DB-rename hazard: renaming a client's `database` makes Terraform want to **destroy** the tenant DB (`name` is ForceNew) — the safe path is an in-place `ALTER DATABASE` + `terraform state rm`/`import`.

### 13. Observability & SLOs [Both]
Uptime checks per tenant domain, alert policies, log-based metrics (cron failures, entitlement violations), per-tenant labels for cost attribution. Note the platform anchor domain `odoo.droob.app` used by the canary health gate.

### 14. Security threat model [Security]
State the trust boundaries: **platform operators = trusted; tenant admins = semi-trusted** (full admin inside their own database, must not affect other tenants or the platform); internet = untrusted. Map each trust boundary to controls. Cover: network (no public IPs on data plane, ingress = internal load balancer only, Direct VPC Egress, private services access), edge (WAF, login throttle, per-tenant rate limit), identity (per-tenant PG users, WIF, per-secret IAM), data (per-tenant DB + bucket, least privilege), application (dbfilter, list_db off, entitlement gate). Explicitly list residual risks (group_system tenant admins, shared image = shared code on disk, pooled tier has no hard storage isolation between tenants) and the compensating controls / roadmap (dedicated tier).

### 15. Hard-won lessons / gotchas [Both]
Turn the README "Deploy-time gotchas" into slides: Cloud Armor `SRC_IPS_V1`; `PORT` is reserved; serverless-NEG rejects `timeout_sec`; PSA `/24` exhaustion → second `/20`; `odoo:18.0` `VOLUME /mnt/extra-addons` discards build writes; pyOpenSSL/cryptography pin; demo-data exclusion; cron auto-creates DBs; managed-cert immutability & "all SANs must resolve before ACTIVE"; secret-IAM propagation; **attachments/assets on ephemeral local filestore unless `SERVER_ENV_CONFIG` configures `fs_storage`**; **`-i base` does not install `web` (login 500s without it)**; **`.gcloudignore` needed so `build-addons/` uploads**. Frame these as "why the platform is now resilient."

### 16. Roadmap & recommendations [Both]
Regional HA flip for Cloud SQL, dedicated premium tier for hard isolation, denying tenant `group_system` as defense-in-depth, and any operational follow-ups.

## Tone & audience guidance
- For **DevOps** slides, emphasise: reproducibility (IaC), safe rollouts (canary/rollback), recovery runbooks, and cost (pooled model).
- For **Security** slides, emphasise: least privilege, blast-radius containment, explicit trust boundaries, and honest disclosure of residual risk with compensating controls.
- Every claim should be defensible; prefer "here is the exact mechanism and its limit" over marketing language.

Now generate the full slide-by-slide deck with speaker notes and all Q&A sections.

=== PROMPT END ===
