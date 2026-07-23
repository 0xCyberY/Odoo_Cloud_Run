# Odoo v18 on Cloud Run — Multi-Tenant SaaS (v2 Hardened Architecture)

Multi-tenant Odoo hosting on Google Cloud Run: **one shared image** containing the
full sellable addon catalog, tenants segregated **per database**
(`dbfilter = ^(%d|%h)$`), and per-tenant addon **entitlements enforced at
runtime** (`addon_entitlement` module + `ODOO_ENTITLEMENTS`, §2) — selling an
addon is a config change, never an image rebuild. All eight v1 weaknesses are
closed (see the [Fixes legend](#15-fixes-legend--v1-weakness--v2-solution)).

Full diagram: [`docs/architecture-v2.svg`](docs/architecture-v2.svg)

```
Internet → tenant domains (acme.droob.app, beta.droob.app, ...)
   │
   ▼
Global External Application Load Balancer  (static IP, Google-managed SSL)
   ├─ Cloud CDN (static assets)
   ├─ Cloud Armor: WAF + per-IP login throttle + PER-TENANT (Host) rate limit
   ├─ default                  → pooled-odoo    (Cloud Run, web, min=1, dbfilter)
   └─ /websocket, /websocket/* → websocket-odoo (Cloud Run, gevent, session affinity)

Cloud Run services (each with a pgbouncer sidecar):
   pooled-odoo       web tier: threaded Odoo, max_cron_threads=0, timeout 3600s
   websocket-odoo    gevent worker: chat / longpolling / live notifications
   cron-runner-odoo  THE ONLY cron runner: max_instances=1, internal-only

Data layer (Shared VPC, Direct VPC Egress, private IPs only):
   Cloud SQL PostgreSQL 16 · Memorystore Redis · GCS buckets · Secret Manager

Async / control plane:
   Cloud Tasks "odoo-heavy-ops" · Cloud Run Jobs (db-setup/init/migration)
   Cloud Workflows "odoo-fleet-migration" (sequential, halt-on-fail, resumable)
```

---

## Table of Contents

1. [Directory structure](#1-directory-structure)
2. [The addon catalog — where addons live](#2-the-addon-catalog--where-addons-live)
3. [The image and its three run modes](#3-the-image-and-its-three-run-modes)
4. [Life of a request](#4-life-of-a-request)
5. [Tenant isolation — the layers](#5-tenant-isolation--the-layers)
6. [pgbouncer — how per-tenant DB credentials work](#6-pgbouncer--how-per-tenant-db-credentials-work)
7. [Sessions, attachments, and cron](#7-sessions-attachments-and-cron)
8. [Secrets — who creates what, who reads what](#8-secrets--who-creates-what-who-reads-what)
9. [Terraform — two stacks and why](#9-terraform--two-stacks-and-why)
10. [CI/CD workflows explained](#10-cicd-workflows-explained)
11. [Deployment runbook — clean GCP project, manual, step by step](#11-deployment-runbook--clean-gcp-project-manual-step-by-step)
12. [Onboarding a new client (live platform)](#12-onboarding-a-new-client-live-platform)
13. [Offboarding / destroying a client](#13-offboarding--destroying-a-client)
14. [Migrating a live pre-v2 environment (historical)](#14-migrating-a-live-pre-v2-environment-historical--not-needed-on-a-fresh-project)
15. [Fixes legend](#15-fixes-legend--v1-weakness--v2-solution)
16. [Deploy-time gotchas — hit once, now handled in code](#16-deploy-time-gotchas--hit-once-now-handled-in-code)

---

## 1. Directory Structure

```
.
├── README.md
├── docs/architecture-v2.svg           # Architecture diagram (as implemented)
├── clients/
│   ├── clients.yaml                   # SINGLE SOURCE OF TRUTH: sellable addon
│   │                                  #   catalog + per-tenant domain, database,
│   │                                  #   db_user, addon entitlements
│   └── <client>.tfvars                # Per-client Terraform inputs
├── odoo-v18/
│   ├── Dockerfile                     # odoo:18.0 + platform modules + addon catalog
│   ├── entrypoint.sh                  # Generates odoo.conf; ODOO_MODE=web|cron|websocket
│   ├── db-setup.sh                    # Tenant DB hardening (least-privilege user)
│   ├── addons/gcs_attachment_default/ # Repo-owned module (committed here)
│   ├── build-addons/                  # Addon catalog staging (gitignored, built on demand)
│   └── pgbouncer/                     # Sidecar image: per-tenant credential routing
├── scripts/
│   ├── prepare_addons.py              # clients.yaml → clone all addon repos for the build
│   ├── provision.py                   # Onboarding: shared apply → tenant apply → db-setup → init
│   ├── cloud_run_scale.py             # Toggle pooled warm floor (min-instances)
│   └── notify.py                      # Email notifications
├── terraform/
│   ├── main.tf                        # Per-tenant workspace: DB, bucket, jobs, DNS
│   ├── shared/                        # Platform stack (apply once, re-apply on clients.yaml change)
│   │   ├── main.tf                    #   VPC, SQL, Redis, ALB, Armor, 3 Cloud Run services,
│   │   │                              #   tenant SQL users, Cloud Tasks, Cloud Workflows
│   │   ├── monitoring.tf              #   Uptime checks, alert policies, log metrics
│   │   └── outputs.tf                 #   alb_ip, sql_private_ip, ssl_certificate, ...
│   └── modules/
│       ├── cloud-run-odoo/            # Service module (modes, pgbouncer sidecar, NEG)
│       ├── cloud-run-job/             # Job module (entrypoint-preserving)
│       └── cloud-sql-db/              # Tenant DB + Odoo admin secrets
└── .github/workflows/
    ├── deploy-fleet.yml               # Build → smoke test → migrate fleet → canary + rollback
    ├── update-addon.yml               # Single-module update for one tenant
    ├── provision-client.yml           # Onboard a tenant from CI
    └── destroy-client.yml             # Tear down a tenant workspace
```

---

## 2. The Addon Catalog — Where Addons Live

Client addons are **not stored in this repo** — they're pulled in at build time.

### On disk (this repo)

| Location | What's there | How it gets there |
|---|---|---|
| `odoo-v18/addons/` | `gcs_attachment_default` — the one platform module we own | Committed in this repo |
| `odoo-v18/build-addons/` | Empty in git (just `.gitkeep`) | Populated by `scripts/prepare_addons.py` right before every build |

`prepare_addons.py` reads `clients/clients.yaml` and clones the common repo
plus **the entire `catalog:` section — every sellable repo, whether or not a
client currently subscribes**. Baking the full catalog is deliberate: selling
an addon to a client is then purely an entitlement change (runtime), never an
image rebuild (§10 upgrade model, §12 step 3):

```yaml
common_addon_repo: 'github.com/0xCyberY/Common-18.0.git'      # → build-addons/common/
catalog:                       # EVERY sellable repo — all baked into the image
  repo-hr:                                                    # → build-addons/repo-hr/
    repo:   'github.com/0xCyberY/Human-Resources-18.0.git'
    branch: main
clients:
  mac-corp:
    addon_repos: [repo-hr]     # ← entitlement: catalog keys this client pays for
```

To populate it locally:

```bash
GITHUB_TOKEN=<pat> python3 scripts/prepare_addons.py --clean
ls odoo-v18/build-addons/     # → common/  repo-hr/
```

CI runs this automatically before `gcloud builds submit` using the
`ADDONS_GITHUB_TOKEN` secret. `build-addons/` is gitignored so private client
code never gets committed into this infra repo, and `.git` dirs are stripped
after cloning so no token or history leaks into the image.

The Dockerfile ends stage 1 with **build-time assertions**: every platform
module's `__manifest__.py` must exist, and `import OpenSSL.crypto, redis,
gcsfs, packaging` plus `import odoo` must succeed — so a missing module or a
broken Python dependency pair fails the *build* with a clear message instead
of a 4-minute probe timeout at deploy.

### Inside the built image (container paths)

The Dockerfile assembles four layers; `entrypoint.sh` builds `addons_path` from them:

| Container path | Contents | Source |
|---|---|---|
| `/opt/extra-addons` | `session_redis`, `fs_storage`, `fs_attachment`, `server_environment` | Cloned from camptocamp/OCA 18.0 during `docker build` (NOT `/mnt/extra-addons` — that's a VOLUME in the odoo base image; build-time writes there are discarded) |
| `/mnt/platform-addons` | `gcs_attachment_default`, `platform_dblist` | `COPY addons/` |
| `/mnt/custom-shared/common` | Your Common-18.0 modules | `COPY build-addons/` |
| `/mnt/custom-shared/repo-hr` | Your Human-Resources-18.0 modules | `COPY build-addons/` |
| `/usr/lib/python3/dist-packages/odoo/addons` | Odoo core | Base image `odoo:18.0` |

The entrypoint **auto-discovers every subdirectory** of `/mnt/custom-shared/`,
so adding a new repo to the catalog requires no Dockerfile or entrypoint
change — the next build picks it up.

### Segregation model — entitlements enforced at runtime

One image carries the **entire catalog**. Isolation and entitlement are
per-database, enforced by the platform module **`addon_entitlement`**, which
the init job installs into **every newly provisioned** tenant DB. Its overrides
only load in databases where it is installed, so **existing tenants provisioned
before this module must be backfilled once** — `-u all` never installs a new
module, so run per pre-existing DB (safe to re-run, idempotent):

```bash
gcloud run jobs execute <slug>-odoo-job-migration --region $REGION --wait \
  --args="-d,<db>,-i,addon_entitlement,--stop-after-init"
```

Until that backfill runs, a tenant DB without the module has **no** visibility
filter or install gate — verify with the daily audit (§ below) or
`gcloud run jobs execute ... --args="-d,<db>,-i,addon_entitlement,..."`. Once
installed, it enforces:

- **Visibility**: modules from catalog repos a client does not declare in its
  `addon_repos` are **hidden from the Apps list** and every module search.
  Installed modules always stay visible and working, whatever the entitlement
  map says — a map mistake degrades to "cannot install", never a broken tenant.
- **Install gate**: install/upgrade of an unentitled module (or anything whose
  dependency chain includes one) is refused with a "not included in your
  subscription" error — in **every** context, with no `sudo()` exemption
  (server/automated actions) and no interactive-only exemption (a tenant
  `ir.cron` scheduled action runs on the cron-runner with no HTTP request
  bound and is still gated). Module-state writes and self-uninstall are guarded
  the same way, so neither the next fleet `-u all` nor a scheduled action can
  smuggle an install.
- **Installs are an operation, not a tenant button**: the only exempt context
  is the operator-run provisioning/migration **Cloud Run Jobs**, which set
  `ODOO_ENTITLEMENT_BYPASS=1` (the `cloud-run-job` module) — the three
  long-running services never set it, and tenants cannot set container env, so
  that flag (not "is a request bound") is the trust boundary. Its absence fails
  closed (enforce).
- **Entitlement source**: the `ODOO_ENTITLEMENTS` env var (db → catalog dirs),
  rendered by `terraform/shared` from clients.yaml onto all three services.
  Selling an addon = one `addon_repos` entry + shared apply (zero-downtime
  revision roll) — no rebuild, no migration.
- **Sideloading blocked**: `base_import_module` (module-zip upload = arbitrary
  code on the shared workers) is blocklisted for every tenant.
- **Detection**: a daily audit cron logs `ENTITLEMENT_VIOLATION` for any
  installed-but-unentitled module; `terraform/shared/monitoring.tf` turns that
  into an alert. This is a paywall with an alarm, not a vault — hard code
  isolation remains the dedicated per-client tier ("premium", future), for
  which the `/mnt/client-addons` mount point is already reserved.

---

## 3. The Image and Its Three Run Modes

One image, three roles. `entrypoint.sh` generates `/etc/odoo/odoo.conf` at
container startup based on `ODOO_MODE`, then execs Odoo:

| | `ODOO_MODE=web` (default) | `ODOO_MODE=cron` | `ODOO_MODE=websocket` |
|---|---|---|---|
| Used by | `pooled-odoo` | `cron-runner-odoo` | `websocket-odoo` |
| Process | `odoo` (threaded, `workers=0`) | `odoo` (threaded) | `odoo gevent` |
| Tenant routing | `dbfilter = ^(%d|%h)$` (hostname → DB) | `db_name = <all tenant DBs>` | `dbfilter = ^(%d|%h)$` |
| Cron threads | `0` — never | `MAX_CRON_THREADS` (default 2) — **only here** | `0` — never |
| Listens on | `$PORT` (http) | `$PORT` (http, probes only) | `$PORT` (`gevent_port`) |

Shared behavior in every mode:

- `workers = 0` (threaded mode) — one container instance handles many concurrent
  requests with threads, which matches Cloud Run's concurrency model.
- `list_db = False`, `proxy_mode = True`, limits aligned with the 3600s
  end-to-end timeout.
- If `REDIS_HOST` is set, `server_wide_modules = base,web,session_redis` and the
  `ODOO_SESSION_REDIS_*` env vars are exported → sessions live in Memorystore.
- `DB_HOST` points at the pgbouncer sidecar (`127.0.0.1:6432`) in services, or
  directly at the Cloud SQL private IP in jobs (which have no sidecar).
- `running_env = prod` (override with `RUNNING_ENV`) — required by OCA
  `server_environment`, a dependency of `fs_storage`.

Why jobs don't override the entrypoint: `/entrypoint.sh` is what writes
`odoo.conf`. Cloud Run Jobs therefore keep the image entrypoint and only append
args (e.g. `-d acme -u all --stop-after-init`). The only exception is the
db-setup job, which runs `/db-setup.sh` directly — it's pure `psql`, no Odoo.

---

## 4. Life of a Request

What happens when a user opens `https://acme.droob.app/web`:

1. **DNS** → the tenant's A record points at the shared ALB static IP
   (managed per tenant by Terraform when `manage_dns = true`).
2. **ALB frontend** terminates TLS with the Google-managed certificate, whose
   domain list is generated from `clients.yaml`.
3. **Cloud Armor** evaluates: WAF rules → per-IP login throttle (60/min on
   `/web/login` + `/web/database`) → per-tenant budget (default 600 req/min per
   `Host` header, so one tenant cannot starve the others).
4. **Cloud CDN** serves cached static assets (`CACHE_ALL_STATIC`) without ever
   reaching Cloud Run.
5. **URL map** routes by path: `/websocket*` → `websocket-odoo`, everything
   else → `pooled-odoo`. Both services only accept traffic *from the load
   balancer* (`ingress = INTERNAL_LOAD_BALANCER`) — their `run.app` URLs are
   not reachable from the internet.
6. **Odoo (pooled)** sees `Host: acme.droob.app`; `dbfilter = ^(%d|%h)$` maps the
   hostname to exactly one database (see the naming rules below). The session
   cookie is looked up in **Redis**, so any instance can serve any request
   (instances are stateless).
7. **Database access** goes to `127.0.0.1:6432` — the **pgbouncer sidecar** —
   which connects to Cloud SQL's private IP over Direct VPC Egress *as that
   tenant's own PostgreSQL user* (see §6).
8. **Attachments** are streamed from the tenant's GCS bucket via the JSON API
   (`fs_attachment`), authenticated with the service account — no keys, no
   mounts.

### Host → database naming rules

`dbfilter = ^(%d|%h)$` is a hybrid: Odoo substitutes `%d` with the **first
label** of the host (after stripping `www.`) and `%h` with the **full host**, so
a request matches a database named either way:

| Request Host | Matches a DB named | Convention |
|---|---|---|
| `beta.droob.app` | `beta` | Normal case: DB named after the subdomain |
| `example.com` | `example` | Apex domains: first label works the same |
| `super.droob.com` + `super.example.com` | `super.droob.com` / `super.example.com` | First-label **collision**: both DBs use the full domain; a DB named just `super` must not exist |

These rules are **enforced automatically** — a duplicate or ambiguous
registration is rejected before any infrastructure changes, at three gates:

1. `scripts/validate_clients.py` — run by `provision.py` and
   `prepare_addons.py` (so every CI build and every onboarding fails fast).
   Checks: duplicate slugs (YAML would silently drop one!), duplicate domains,
   duplicate databases/db_users, and that every host resolves to exactly one
   database.
2. **Terraform preconditions** on the managed SSL certificate in
   `terraform/shared` — the same rules re-checked at `plan`/`apply` time, for
   paths that don't go through the Python scripts.
3. Odoo itself — with `list_db = False`, an ambiguous or zero-match host gets
   an error page rather than a database picker.

---

## 5. Tenant Isolation — The Layers

Defense in depth: a failure at any single layer does not expose another tenant.

| Layer | Mechanism | What it stops |
|---|---|---|
| Edge | Per-tenant (Host) rate limit in Cloud Armor | One tenant flooding the platform |
| App | `dbfilter = ^(%d|%h)$` + `list_db = False` | Cross-tenant DB selection from the UI |
| Connection | pgbouncer maps each DB → that tenant's PG user | A dbfilter bug or Odoo exploit reading another tenant's DB |
| Database | `REVOKE CONNECT FROM PUBLIC`; tenant user owns only its DB | Any connection to a foreign DB, even with valid creds |
| DB resources | Per-role `statement_timeout` + `CONNECTION LIMIT` | A runaway tenant query starving the instance |
| Storage | One GCS bucket per tenant, IAM per bucket | Cross-tenant file access |
| Secrets | One Secret Manager secret per tenant credential | Blast radius of a leaked credential |
| Modules | Install-by-job only; no Apps rights for tenants | A tenant enabling another client's addons |

---

## 6. pgbouncer — How Per-Tenant DB Credentials Work

The subtle problem: a *pooled* Odoo process has **one** `db_user` in its config —
it cannot present different PostgreSQL credentials per database. So per-tenant
DB users would be useless… unless something swaps credentials per database.
That something is the pgbouncer sidecar (`odoo-v18/pgbouncer/`).

At sidecar startup, `entrypoint.sh` generates `pgbouncer.ini` from env vars:

```ini
[databases]
acme  = host=<sql-private-ip> dbname=acme  user=acme_production2 password=***   ; ← tenant user
beta  = host=<sql-private-ip> dbname=beta  user=beta_production  password=***
*     = host=<sql-private-ip>                                                    ; ← fallback: platform user

[pgbouncer]
pool_mode = session          ; Odoo needs LISTEN/NOTIFY (bus) + advisory locks
default_pool_size = 5        ; server connections per db
max_db_connections = 10      ; hard cap per db (noisy-neighbor containment)
```

Where the pieces come from:

| Piece | Source |
|---|---|
| The tenant map (`PGB_TENANTS`) | Terraform builds it from `clients.yaml` (`database` + `db_user` per client) |
| Tenant passwords (`TENANT_DB_PASSWORD_<SLUG>` env) | Injected from Secret Manager per tenant by the `cloud-run-odoo` module |
| Frontend auth (what Odoo logs in with) | The platform user `odoo_shared` — valid only on the loopback interface inside the instance |

Flow: Odoo opens `acme` on `127.0.0.1:6432` as `odoo_shared` → pgbouncer
authenticates it locally → connects to Cloud SQL **as `acme_production2`**,
which can *only* connect to `acme` (db-setup revoked everything else).

Adding a tenant to `clients.yaml` + re-applying `terraform/shared` rolls new
revisions of all three services with the updated map (this is step 1 of
`provision.py`).

The same sidecar also solves connection exhaustion (Fix #2): Cloud SQL's
`max_connections` is protected by `default_pool_size`/`max_db_connections`
regardless of how many Odoo threads or instances are running.

---

## 7. Sessions, Attachments, and Cron

### Sessions → Memorystore Redis

Cloud Run instances are disposable; anything on local disk vanishes. The
`session_redis` module (camptocamp, 18.0) is loaded **server-wide**
(`server_wide_modules`), so every HTTP session is read/written in Redis. Any
instance — or a brand-new one after a deploy — can serve any user's session.
Configured entirely by env (`REDIS_HOST` → `ODOO_SESSION_REDIS_*` in the
entrypoint); no per-database setup needed.

### Attachments → GCS via API

`fs_storage` + `fs_attachment` (OCA 18.0) store `ir.attachment` content in GCS
through the JSON API (fsspec/gcsfs) — deliberately **not** GCS FUSE (weak POSIX
guarantees corrupt attachments) and not Filestore (cost). The install chain per
tenant is `gcs_attachment_default → fs_attachment → fs_storage →
server_environment` (+ core `base_sparse_field`), all baked into the image and
covered by the build assertions and CI smoke test. The repo-owned module
`gcs_attachment_default` runs at tenant init: it reads the `GCS_BUCKET` env var
(set per tenant on the init/migration jobs) and creates the `fs.storage` record
inside that tenant's database with `use_as_default_for_attachments = true` and
`token = google_default` (service-account auth via ADC — no key files). Because
the record lives in the tenant DB, the pooled service needs **no** per-tenant
configuration.

### Cron → one dedicated runner (Fix #8)

The classic Cloud Run problem: autoscaled replicas would each run scheduled
jobs (duplicates), and CPU is throttled outside requests. Solution:

- Every web/websocket instance runs `max_cron_threads = 0` — they never touch cron.
- `cron-runner-odoo` is the **only** service with cron threads, pinned to
  `max_instances = 1` (no duplicates, no locking hacks), `min_instances = 1`
  with **CPU always allocated** (background threads actually get CPU),
  `ingress = INTERNAL_ONLY` and no ALB backend (unreachable from outside).
- Its `db_name` lists every tenant database (generated from `clients.yaml`),
  so one runner services the whole fleet — through the same pgbouncer map, so
  each tenant's crons run under that tenant's own DB user.

### Heavy operations → Cloud Tasks + Jobs (Fix #3)

Big reports/imports don't belong in a request-scoped instance. The
`odoo-heavy-ops` Cloud Tasks queue is provisioned for enqueueing Cloud Run Job
executions (`.../jobs/<tenant>-odoo-job-migration:run` with overridden args):
no request timeout, queue-level retries, rate limiting.

---

## 8. Secrets — Who Creates What, Who Reads What

| Secret (Secret Manager) | Created by | Read by |
|---|---|---|
| `odoo-shared-db-password` | terraform/shared | All services (pgbouncer frontend + fallback), db-setup job |
| `<slug>-db-password` (per tenant) | terraform/shared (from `clients.yaml`) | pgbouncer sidecars (per-tenant backend creds), tenant init/migration jobs |
| `<slug>-admin-user` / `<slug>-admin-password` | tenant workspace (`cloud-sql-db` module) | Provisioning jobs (Odoo admin login for the tenant) |
| `odoo-shared-admin-password` | terraform/shared | Services (Odoo master password env) |

Rules encoded in Terraform: no secret value ever appears in code, state
contains only references, each service account is granted `secretAccessor` on
exactly the secrets it needs (the `cloud-run-odoo` module grants per-tenant
secrets to its own service's SA automatically from the tenant map).

**Ordering matters**: Cloud Run validates secret access at service/job
*creation* time, so the code enforces grants-before-consumers everywhere —
services `depends_on` their IAM members, the `cloud-sql-db` secret output
`depends_on` its grant + version, and `provision.py` / `provision-client.yml`
retry the tenant apply once after 30s to absorb cross-stack Secret Manager IAM
propagation lag (safe: applies are idempotent).

---

## 9. Terraform — Two Stacks and Why

### `terraform/shared` — the platform (apply once, re-apply on `clients.yaml` change)

VPC + subnet + private services peering, Cloud SQL instance, Redis, Artifact
Registry, Cloud Armor, ALB (cert/URL map/backends), the **three Cloud Run
services**, **per-tenant SQL users + password secrets**, Cloud Tasks queue,
the `odoo-fleet-migration` Cloud Workflow, and all monitoring/alerting.

Why tenant SQL users live *here* and not in the tenant workspace: the pooled
service's pgbouncer sidecar references every tenant's password secret in its
env. If tenant workspaces created those secrets, the shared service and the
tenant stacks would race each other (chicken-and-egg on first apply). With
everything derived from `clients.yaml` in one stack, one `apply` updates the
users, the secrets, the pgbouncer map, the SSL cert domains, and the uptime
checks **atomically**.

The managed SSL certificate's **name embeds a hash of the domain set**
(`random_id` + `create_before_destroy`): certificates are immutable and can't
be destroyed while the HTTPS proxy uses them, so every domain change creates
the replacement first, repoints the proxy, then removes the old cert — always
resolve the current name via `terraform output -raw ssl_certificate`.

#### The anchor domain `odoo.droob.app` — why it exists

The certificate's domain list is `["odoo.droob.app"] + <all client domains>`.
The anchor belongs to no client and matches no database — visiting it in a
browser shows "The database manager has been disabled by the administrator",
which is **by design** (zero-match host + `list_db = False`, isolation gate 3
in §4). It exists for machines, not humans:

1. **Deploy-fleet's canary health gate probes it.** Every traffic shift
   (10% → 50% → 100%) is gated on `https://odoo.droob.app/web/health` —
   `/web/health` is database-independent, so it works on a host with no DB.
   This exercises the full production path (DNS → cert → ALB → Cloud Armor →
   pooled service) through a domain that **no customer owns**: probing a
   tenant domain instead would break the deploy pipeline the day that client
   churns and its domain leaves the cert.
2. **It keeps the cert (and ALB) valid independent of tenant churn.** A
   Google-managed certificate must contain at least one domain; every other
   entry comes from `clients.yaml`. With zero clients — fresh platform
   bootstrap, or all tenants offboarded — the shared stack could not even
   create the certificate without the anchor.
3. **It is the one domain guaranteed to be in our own DNS zone**, so the
   "all SANs must resolve before the cert turns ACTIVE" requirement (gotcha
   table, §16) never depends solely on customer-controlled DNS.

Do **not** remove it from the cert, and keep its A record pointing at the ALB.
If the error page shown to human visitors is a concern, add an ALB host rule
redirecting `odoo.droob.app` (all paths except `/web/health`) to a landing
page — cosmetic only.

Notable variables (`terraform/shared/variables.tf`):

| Variable | Default | Purpose |
|---|---|---|
| `db_availability_type` | `ZONAL` | Flip to `REGIONAL` for HA (Fix #1) — in-place change, ~2× DB cost |
| `db_flags` | `max_connections=100` | Instance-wide PG flags |
| `pooled_min_instances` / `pooled_max_instances` | 1 / 3 | Warm floor (no cold starts) / DB-connection cap |
| `per_tenant_rate_limit_per_minute` | 600 | Cloud Armor per-Host budget |
| `alert_email` | empty | Set to enable the monitoring notification channel |

### `terraform/` — one workspace per tenant

`terraform workspace select <slug>` + `clients/<slug>.tfvars`. Creates the
tenant **database**, the **GCS bucket** (+ IAM for pooled & cron SAs), the three
**Cloud Run Jobs** (db-setup / init / migration), and optionally the DNS record.
It reads `clients.yaml` too (for `db_user`), so tfvars stay minimal.

### Modules

| Module | Provides |
|---|---|
| `cloud-run-odoo` | Cloud Run v2 service: run modes, optional pgbouncer sidecar with per-tenant secret env, NEG/ingress/public-access toggles, probes, labels. `ignore_changes` on image + traffic — **CI owns those** |
| `cloud-run-job` | Cloud Run v2 job preserving the image entrypoint (so `odoo.conf` gets generated); `env_extra` for TENANT_DB / GCS_BUCKET etc. |
| `cloud-sql-db` | Tenant database + Odoo admin credential secrets |

---

## 10. CI/CD Workflows Explained

### The upgrade model — code vs database (read this first)

An Odoo addon "update" is **two separate operations**, and they travel by
different mechanisms:

| Layer | Lives in | How it changes | Who receives it |
|---|---|---|---|
| **Code** (addon files, Odoo source) | The shared Docker image | Image rebuild → rollout to the Cloud Run services | **Every tenant at once** — pooled tier, one image, no way to hold a tenant back on old code |
| **Database** (schema, views, stored data) | Each tenant's Cloud SQL database | Odoo run with `-u <module>` against that DB (the **migration job**) | **Only the tenant(s) it's run for** |
| **Odoo version itself** (18 → 19) | Base image + heavy DB conversion | Out of scope — plain `-u all` cannot do major upgrades (OpenUpgrade / Odoo's upgrade service territory); this platform is pinned to v18 | — |

Deploying new code does **nothing** to a database by itself: new fields,
changed views, and data updates only land when Odoo runs `-u` against that
database. The running web service never does this on its own. Every upgrade is
therefore: *image rebuild delivers the code → migration job brings each
tenant's database in line with it.*

#### The three per-tenant Cloud Run Jobs

Each tenant workspace creates three jobs (`terraform/main.tf`) — same Odoo
image as the services, but batch containers that run once and exit:

| Job | Runs | What it does |
|---|---|---|
| `<slug>-odoo-job-db-setup` | At provisioning (and re-run after init) | `/db-setup.sh` — pure `psql` as the shared admin: creates the tenant's database user, locks CONNECT to it, transfers ownership, applies `statement_timeout` + connection limit. No Odoo. |
| `<slug>-odoo-job-init` | First provisioning only | `odoo -d <db> -i base,web,gcs_attachment_default,addon_entitlement --without-demo=all --stop-after-init` — builds the initial schema, installs the web client, binds the GCS attachment storage record, and installs the entitlement gate |
| `<slug>-odoo-job-migration` | Every upgrade | Default args `odoo -d <db> -u all --stop-after-init` — reload every installed module and apply schema/view/data changes to this tenant's database |

The migration job has two callers, matching the two upgrade scenarios:

- **Targeted addon update** — `update-addon.yml` executes it with
  **overridden args** (`-u <single module>` instead of `-u all`): one client,
  one module, after its addon repo changed.
- **Fleet upgrade** — the `odoo-fleet-migration` Cloud Workflow executes each
  tenant's job **sequentially with the default `-u all`**, for platform-wide
  changes (base image bump, common-repo change) where every module in every
  database needs re-migration.

Migrations run as a separate job rather than on the live service on purpose:
`--stop-after-init` means one dedicated process performs the schema change and
exits, instead of racing live web workers mid-request. Note deploy-fleet
re-points the jobs to the new image **before** running migrations (step 5
below) — migrations must execute the *new* code.

#### ⚠️ Why undeclared addons are blocked (entitlement enforcement)

The pooled image carries the **full** catalog on every tenant's `addons_path`,
so historically nothing stopped a tenant DB from installing a module whose
repo that client does **not** declare in `clients.yaml`. That is now enforced
by `addon_entitlement` (§2) — undeclared modules are hidden and refuse to
install — and the reason the gate exists is *schema drift*, not just billing:

1. The shared image is rebuilt and rolled out → the tenant's workers now run
   the **new** code (code reaches everyone, see the table above).
2. `-u` runs only against the databases of clients who **declare** the addon
   (that's who `update-addon.yml` / fleet migration know about — and
   update-addon's entitlement guard refuses undeclared modules outright).
3. An undeclared tenant would be running new code against an **unmigrated
   database** — crashed views, missing columns, tracebacks — until someone
   manually executes its migration job with `-u <module>`.

Rule: `clients.yaml` is the source of truth for *who has what*. A client
getting a catalog addon = add the key to its `addon_repos` **first**, apply
`terraform/shared` (entitlement goes live, no rebuild), then install via its
migration job (§12 step 8). The daily audit cron + alert catch anything that
slips through anyway.

### `deploy-fleet.yml` — the safe fleet upgrade (Fix #5)

| Step | What happens | Why |
|---|---|---|
| 1. Addon catalog | `prepare_addons.py --clean` clones all repos from `clients.yaml` | The image must contain the full catalog |
| 2. Build | Cloud Build → `odoo-pooled:<git-sha>` + `pgbouncer:<git-sha>` (also tagged `latest`) | Immutable tags — you always know what's running |
| 3. Smoke test | Installs `base,session_redis,fs_storage,fs_attachment,gcs_attachment_default` against a disposable Postgres 16 in CI | Catches broken platform modules **before** anything deploys (Fix #6) |
| 4. No-traffic revision | New pooled revision at 0% traffic | The new code exists but serves nobody |
| 5. Job re-point | All tenants' jobs updated to the SHA image | Migrations must run the *new* code |
| 6. Fleet migration | `gcloud workflows run odoo-fleet-migration` — one tenant at a time, **halts on first failure**, resumable via the `start_from` input | No more mixed-version chaos at tenant 15 of 40 |
| 7. Canary | Traffic 10% → 50% → 100%, health-gated on `/web/health` through the ALB; any 5xx → instant rollback to the previous revision | Bad revision never reaches all users |
| 8. Finalize | Traffic reset to `--to-latest`; websocket + cron-runner rolled | Future Terraform revisions (e.g. new tenant in the pgbouncer map) serve immediately |

### `update-addon.yml` — one module, one tenant

Rebuilds the image (SHA tag), runs `-u <module>` in the target tenant's DB via
its migration job, then rolls the image to all three services. Since the image
is shared, prefer **deploy-fleet** when a change affects multiple clients.

### `provision-client.yml` / `destroy-client.yml`

CI equivalents of `provision.py` (shared apply → tenant apply → db-setup →
init) and of tearing down a tenant workspace.

Required GitHub secrets: `GCP_WORKLOAD_IDENTITY_PROVIDER`,
`GCP_SERVICE_ACCOUNT`, `ADDONS_GITHUB_TOKEN` (read-only PAT for the private
addon repos), `SMTP_CREDS`.

---

## 11. Deployment Runbook — Clean GCP Project, Manual, Step by Step

Written for a **freshly cleaned project** (`nomowsoft-poc`, nothing in it).
Every command runs from the **repo root** in your terminal. Phases must run in
order; each phase says what to expect and how to verify before moving on.

### Phase 0 — Tools & authentication

Required locally: `gcloud`, Terraform ≥ 1.8, Python 3.9+, git.

```bash
export PROJECT=nomowsoft-poc
export REGION=europe-west1

gcloud auth login
gcloud auth application-default login     # Terraform uses these credentials
gcloud config set project $PROJECT
```

### Phase 1 — Enable the required APIs (one time, ~1 min)

```bash
gcloud services enable \
  compute.googleapis.com run.googleapis.com sqladmin.googleapis.com \
  redis.googleapis.com servicenetworking.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com \
  cloudbuild.googleapis.com workflows.googleapis.com cloudtasks.googleapis.com \
  monitoring.googleapis.com logging.googleapis.com storage.googleapis.com \
  iam.googleapis.com dns.googleapis.com
```

Give it a minute after this returns — API activation is eventually consistent.

### Phase 2 — Terraform state bucket (one time)

The backends (`terraform/backend.tf`, `terraform/shared/providers.tf`) expect
`gs://nomowsoft-poc-tf-state`. Recreate it:

```bash
gcloud storage buckets create gs://${PROJECT}-tf-state \
  --location=$REGION --uniform-bucket-level-access
gcloud storage buckets update gs://${PROJECT}-tf-state --versioning
```

### Phase 3 — Validate config & build the addon catalog

```bash
python3 -m venv .venv && .venv/bin/pip install -q pyyaml
.venv/bin/python scripts/validate_clients.py        # must print "clients.yaml OK"

# Clone common + all client addon repos into odoo-v18/build-addons/
GITHUB_TOKEN=<your-github-pat> .venv/bin/python scripts/prepare_addons.py --clean
ls odoo-v18/build-addons/                            # expect: common/  repo-hr/
```

### Phase 4 — Artifact Registry repo + images

The Cloud Run services (Phase 5) need both images to already exist, but the
registry itself is a Terraform resource — so create **just the registry** first
with a targeted apply, then build:

```bash
terraform -chdir=terraform/shared init
terraform -chdir=terraform/shared apply \
  -target=google_artifact_registry_repository.odoo_repo

# On a fresh project, grant Cloud Build's runtime SA push access (one time)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/artifactregistry.writer
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/logging.logWriter

# Build & push both images (Odoo build takes ~10 min the first time)
gcloud builds submit odoo-v18/ \
  --tag $REGION-docker.pkg.dev/$PROJECT/odoo-v18-repo/odoo-pooled:latest
gcloud builds submit odoo-v18/pgbouncer/ \
  --tag $REGION-docker.pkg.dev/$PROJECT/odoo-v18-repo/pgbouncer:latest

# Verify
gcloud artifacts docker images list $REGION-docker.pkg.dev/$PROJECT/odoo-v18-repo
```

### Phase 5 — Apply the shared platform (~15–25 min)

Creates: VPC + peering, Cloud SQL (slowest, ~10 min), Redis, Cloud Armor, ALB +
certificate, the three Cloud Run services with pgbouncer sidecars, per-tenant
SQL users + secrets, Cloud Tasks queue, the migration Workflow, monitoring.

```bash
terraform -chdir=terraform/shared plan     # review: ~60+ resources, no destroys
terraform -chdir=terraform/shared apply
terraform -chdir=terraform/shared output   # note alb_ip for Phase 6
```

**Immediately after the apply, pause the cron runner until Phase 7 is done:**

```bash
gcloud run services update cron-runner-odoo --min-instances=0 --region $REGION
```

Why: Odoo auto-creates any database named in its `db_name` list (`-d` behavior
since v15). Left running, the cron runner creates *empty* tenant databases
before Phase 7's Terraform does, and the tenant apply then fails with
"database already exists" (recoverable via `terraform import`, but avoidable).

Other expected quirks — both normal:
- HTTPS doesn't work yet — the certificate can't provision until DNS points at
  the ALB (Phase 6).
- If a service revision fails on "Permission denied on secret", IAM propagation
  lagged — re-run the apply (idempotent).

### Phase 6 — DNS + SSL certificate

At your DNS registrar, create **A records → the `alb_ip` output** for **every**
domain in the certificate — all client domains **plus the platform anchor
`odoo.droob.app`** (why the anchor exists: see §9).
A Google-managed certificate only turns ACTIVE when **all** of its domains
resolve to the LB, so one missing record blocks HTTPS for everyone.

```bash
# Watch provisioning (ACTIVE can take 15–60 min after DNS propagates).
# The cert name embeds a hash of the domain set (rotates on tenant changes),
# so always resolve it from the Terraform output:
gcloud compute ssl-certificates describe \
  "$(terraform -chdir=terraform/shared output -raw ssl_certificate)" --global \
  --format='yaml(managed.status, managed.domainStatus)'
```

Proceed to Phase 7 while you wait — tenant provisioning doesn't need the cert.

### Phase 7 — Provision each tenant

Fresh project = fresh databases, so run with `--init-db` for every client:

```bash
GITHUB_TOKEN=<pat> .venv/bin/python scripts/provision.py --client acme-corp --init-db
GITHUB_TOKEN=<pat> .venv/bin/python scripts/provision.py --client beta-corp --init-db
GITHUB_TOKEN=<pat> .venv/bin/python scripts/provision.py --client mac-corp  --init-db
```

Each run executes, in order:
1. **terraform/shared apply** — tenant SQL user + secret, pgbouncer map, cert
   domain, uptime check (no-op if unchanged).
2. **Tenant workspace apply** — database, GCS bucket, the three Cloud Run Jobs.
3. **db-setup job** — CONNECT locked to the tenant user, ownership transferred,
   `statement_timeout` + connection limit applied.
4. **init job** — `odoo -i base,web,gcs_attachment_default,addon_entitlement` (attachments wired to
   the tenant's bucket), then **db-setup re-runs to replace the default
   admin/admin with the tenant's real credentials** from Secret Manager.

(`provision.py` auto-retries the tenant apply once after 30s if Secret Manager
IAM propagation lags — you'll see a warning, not a failure.)

**When all tenants are provisioned, restore the cron runner:**

```bash
gcloud run services update cron-runner-odoo --min-instances=1 --region $REGION
```

Get a tenant's admin login credentials:

```bash
gcloud secrets versions access latest --secret=acme-corp-admin-user;  echo
gcloud secrets versions access latest --secret=acme-corp-admin-password; echo
```

### Phase 8 — Verify the deployment

```bash
# All three services healthy?
gcloud run services list --region $REGION      # pooled-odoo, websocket-odoo, cron-runner-odoo

# Health end-to-end through the ALB (after cert is ACTIVE)
curl -sI https://acme.droob.app/web/health       # expect HTTP/2 200
curl -sI https://beta.droob.app/web/health
curl -sI https://mac.droob.app/web/health

# Cron runner picked up the tenant DBs? (errors should have stopped)
gcloud run services logs read cron-runner-odoo --region $REGION --limit 30

# Log in at https://acme.droob.app/web with the Phase-7 credentials, then
# upload any attachment and confirm it lands in GCS:
gcloud storage ls -r gs://$PROJECT-acme-corp-odoo-attachments/ | head

# Websocket path routed? (400/upgrade-required from Odoo = correctly routed)
curl -sI https://acme.droob.app/websocket
```

Also check Cloud Console → Monitoring → Uptime checks: three green checks.

### Phase 9 — Turn on alerting (recommended) & CI (optional)

```bash
terraform -chdir=terraform/shared apply -var alert_email=you@example.com
```

For GitHub Actions (fleet upgrades via `deploy-fleet.yml`), configure repo
secrets `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`,
`ADDONS_GITHUB_TOKEN`, `SMTP_CREDS` (Workload Identity Federation mapping
reference: `workload-identity-attribute-mapping.json`). Until then, a manual
fleet upgrade is: Phase 3 → Phase 4 build with a new tag → run the
`odoo-fleet-migration` workflow → shift traffic (see §10 for the sequence).

### Day-2 operations

```bash
# Warm floor on the pooled service (1 = no cold starts, 0 = scale-to-zero)
python3 scripts/cloud_run_scale.py --min-instances 1

# Enable Cloud SQL Regional HA (Fix #1) when tenant revenue justifies ~2x DB cost
terraform -chdir=terraform/shared apply -var db_availability_type=REGIONAL

# Resume a halted fleet migration from the failed tenant
gcloud workflows run odoo-fleet-migration --location $REGION \
  --data '{"tenants": ["acme-corp","beta-corp","mac-corp"], "start_from": "beta-corp"}'
```

To add a client to the running platform: §12. To remove one: §13 — the order
there matters (tenant-owned DBs, cron auto-create, SQL-user dependencies), so
follow it rather than improvising with `terraform destroy`.

---

## 12. Onboarding a New Client (Live Platform)

§11 bootstraps an empty project; this section adds **one tenant to the
platform that is already running**. Example throughout: `zed-corp` on
`zed.droob.app`. Commands assume the §11 environment (`$PROJECT`, `$REGION`,
`.venv`, repo root). Active work is ~15 minutes; the SSL certificate wait
dominates the calendar time.

### Step 1 — Declare the client in `clients/clients.yaml`

The single source of truth: everything downstream (SQL user, pgbouncer map,
cert domain, uptime check, addon catalog, cron `db_name`) derives from this
entry.

```yaml
  zed-corp:
    domain:      zed.droob.app
    region:      europe-west1
    database:    zed              # first label of the domain — see §4 naming rules
    db_user:     zed_production
    gcp_project: nomowsoft-poc
    addon_repos: [repo-hr]        # entitlements: catalog keys this client pays
                                  # for (§2) — must exist in the catalog section
```

```bash
.venv/bin/python scripts/validate_clients.py    # must print "clients.yaml OK"
```

### Step 2 — Create `clients/zed-corp.tfvars`

Mirror an existing file (`clients/mac-corp.tfvars`):

```hcl
gcp_project   = "nomowsoft-poc"
region        = "europe-west1"
client_slug   = "zed-corp"
domain        = "zed.droob.app"
database_name = "zed"
admin_user    = "admin@zed-corp.com"        # the tenant's Odoo admin login
image_url     = "europe-west1-docker.pkg.dev/nomowsoft-poc/odoo-v18-repo/odoo-pooled:latest"
# manage_dns  = true                        # only if the zone lives in Cloud DNS
```

Commit both files — CI reads them from the repo, and clients.yaml history *is*
the tenant audit trail.

### Step 3 — Rebuild the image (only if the repo is NEW to the catalog)

The image always carries the **whole catalog** (§2), so a client subscribing
to an existing catalog repo needs **no rebuild** — skip this step; their
entitlement goes live with the shared apply in step 6. Rebuild only when the
client brings a repo the catalog has never seen: add it to the `catalog:`
section first, then either run **deploy-fleet** (preferred: smoke test +
canary included) or manually:

```bash
GITHUB_TOKEN=<pat> .venv/bin/python scripts/prepare_addons.py --clean
gcloud builds submit odoo-v18/ \
  --tag $REGION-docker.pkg.dev/$PROJECT/odoo-v18-repo/odoo-pooled:latest
# services/jobs pin digests at deploy time — a rebuild alone changes nothing
# until images are re-pointed (deploy-fleet does this; see §16 last gotcha)
```

### Step 4 — Create the DNS A record FIRST

At the registrar: `zed.droob.app` → the ALB IP
(`terraform -chdir=terraform/shared output -raw alb_ip`).

Do this **before** provisioning: adding a domain **replaces** the managed
certificate (the name embeds the domain-set hash, §9), and the replacement
only turns ACTIVE once **every** SAN — including the new one — resolves to the
ALB. Existing tenants keep serving on the old cert until the new one is
ACTIVE; the new domain's HTTPS typically takes 15–60 min after DNS propagates.
The earlier the record exists, the shorter that window.

### Step 5 — Pause the cron runner

```bash
gcloud run services update cron-runner-odoo --min-instances=0 --region $REGION
```

Same race as §11 Phase 5, in miniature: provisioning step 1 (shared apply)
adds `zed` to the cron runner's `db_name` list *before* step 2 creates the
database — and Odoo auto-creates databases it is told about, leaving an empty
`zed` DB that makes the tenant apply fail with "already exists".

### Step 6 — Provision

```bash
GITHUB_TOKEN=<pat> .venv/bin/python scripts/provision.py --client zed-corp --init-db
# or from CI: Actions → "provision-client" → client_slug=zed-corp + domain
```

One command, four phases (§11 Phase 7 describes each): **shared apply**
(SQL user + password secret, pgbouncer map, cert domain, `ODOO_DATABASES`,
uptime check — rolls new revisions of all three services; existing tenants are
unaffected, CI owns traffic) → **tenant workspace apply** (database, GCS
bucket, the three Cloud Run Jobs, DNS record if `manage_dns`) → **db-setup
job** → **init job** + admin-credential swap. A single 30s-retry warning on
the tenant apply is normal (Secret Manager IAM propagation).

Then restore the cron runner:

```bash
gcloud run services update cron-runner-odoo --min-instances=1 --region $REGION
```

### Step 7 — Verify and hand over

```bash
# cert ACTIVE again (incl. zed.droob.app)?
gcloud compute ssl-certificates describe \
  "$(terraform -chdir=terraform/shared output -raw ssl_certificate)" --global \
  --format='yaml(managed.status, managed.domainStatus)'

curl -sI https://zed.droob.app/web/health      # HTTP/2 200

# tenant admin credentials for handover:
gcloud secrets versions access latest --secret=zed-corp-admin-user;     echo
gcloud secrets versions access latest --secret=zed-corp-admin-password; echo
```

Also confirm the new uptime check is green (Cloud Console → Monitoring) and
the cron runner logs show no errors for `zed`.

### Step 8 — Install the client's paid modules

Init installs only the platform baseline (`base` + attachments wiring). The
client's own modules are installed via their migration job with overridden
args — never by the tenant from the Apps menu (§10 undeclared-addon warning):

```bash
gcloud run jobs execute zed-corp-odoo-job-migration --region $REGION --wait \
  --args="-d,zed,-i,<module_name>,--stop-after-init"
```

Repeat `-i` per module (comma-separate for several:
`-d,zed,-i,mod_a,mod_b,--stop-after-init`).

### Selling an addon to an EXISTING client

The everyday case, and the whole point of the catalog/entitlement split (§2) —
no rebuild, no fleet event, other tenants untouched:

```bash
# 1. Entitle: add the catalog key to the client's addon_repos in clients.yaml
#    (e.g. beta-corp: addon_repos: [repo-hr]), commit, then:
.venv/bin/python scripts/validate_clients.py
terraform -chdir=terraform/shared apply     # rolls ODOO_ENTITLEMENTS onto the services

# 2. Install into their database (the only legitimate install path):
gcloud run jobs execute beta-corp-odoo-job-migration --region $REGION --wait \
  --args="-d,beta,-i,<module_name>,--stop-after-init"
```

After step 1 the modules appear in the client's Apps list (visible but the
tenant still can't self-install); step 2 makes them live. If the addon's repo
isn't in the catalog yet, that's a product release — step 3 above first.

---

## 13. Offboarding / Destroying a Client

**Everything here is irreversible past step 3 — data is destroyed.** The
order below is not stylistic; it dodges three traps that will bite in any
other order:

- **Cron auto-create**: the cron runner lists every tenant DB in `db_name`,
  and Odoo auto-creates missing databases it is told about — drop the DB
  while the runner still references it and an empty one reappears.
- **Tenant-owned database** (least-privilege side effect): the DB is owned by
  the tenant's SQL user, so the Cloud SQL API — and therefore Terraform —
  cannot drop it ("must be owner of database").
- **SQL-user dependency**: the shared stack can't drop the tenant's SQL user
  while that user still owns the database — so the DB must be gone *before*
  the client is removed from `clients.yaml` and shared is re-applied.

Example throughout: `zed-corp` / database `zed`.

### Step 1 — Pause the cron runner

```bash
gcloud run services update cron-runner-odoo --min-instances=0 --region $REGION
```

### Step 2 — Back up everything (last chance)

```bash
# Database dump to GCS (instance name: gcloud sql instances list)
gcloud sql export sql <sql-instance> \
  gs://$PROJECT-tf-state/offboard-backups/zed-$(date +%F).sql.gz \
  --database=zed --offload

# Attachments bucket
gcloud storage cp -r gs://$PROJECT-zed-corp-odoo-attachments \
  gs://<your-archive-bucket>/zed-corp-final/

# Record the admin credentials if contractually required — the secrets are
# destroyed with the tenant workspace in step 5
gcloud secrets versions access latest --secret=zed-corp-admin-user
gcloud secrets versions access latest --secret=zed-corp-admin-password
```

### Step 3 — Drop the database as `odoo_shared`

Terraform can't (trap 2). Temporarily repurpose the db-setup job — it already
runs inside the VPC with the shared admin credentials — then drop:

```bash
gcloud run jobs update zed-corp-odoo-job-db-setup --region $REGION \
  --command bash \
  --args='^@^-c@PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"zed\" WITH (FORCE);"'
gcloud run jobs execute zed-corp-odoo-job-db-setup --region $REGION --wait
```

No need to restore the job's command — it is destroyed in step 5.

### Step 4 — Remove the dropped DB from Terraform state

The tenant workspace still *thinks* it manages the database; destroying now
would fail trying to delete it. Tell state it's gone:

```bash
terraform -chdir=terraform workspace select zed-corp
terraform -chdir=terraform state rm module.cloud_sql_db.google_sql_database.client
```

### Step 5 — Destroy the tenant workspace

Removes the GCS bucket (**and its contents**), the three Cloud Run Jobs, the
admin secrets, and the Cloud DNS record if managed:

```bash
terraform -chdir=terraform destroy -var-file=../clients/zed-corp.tfvars
# or from CI: Actions → "destroy-client" → client_slug=zed-corp
terraform -chdir=terraform workspace select default
terraform -chdir=terraform workspace delete zed-corp
```

### Step 6 — Remove the client from the repo

Delete the `zed-corp:` block from `clients/clients.yaml`, delete
`clients/zed-corp.tfvars`, then:

```bash
.venv/bin/python scripts/validate_clients.py
git add -A && git commit    # the yaml history is the offboarding audit trail
```

### Step 7 — Re-apply the shared platform

```bash
terraform -chdir=terraform/shared apply
```

This atomically removes the tenant's SQL user (safe now — it owns nothing),
its password secret, the pgbouncer map entry, the `ODOO_DATABASES` /
cron `db_name` entries, the uptime check, and the cert domain — the
certificate is **replaced again** (hashed name, §9); existing tenants keep
serving on the old cert until the new one is ACTIVE. All three services roll
new revisions.

### Step 8 — Restore the cron runner, clean up the edges

```bash
gcloud run services update cron-runner-odoo --min-instances=1 --region $REGION
```

- Delete the `zed.droob.app` A record at the registrar (if not Cloud
  DNS-managed).
- If no remaining client declares the departed client's addon repo, the next
  image build drops it from the catalog automatically (`prepare_addons.py`
  only clones what clients.yaml references) — it disappears at the next
  deploy-fleet run; no immediate rebuild needed.
- Keep the step-2 backups per your retention policy.

---

## 14. Migrating a Live Pre-v2 Environment (historical — NOT needed on a fresh project)

> The current project was cleaned before the v2 deployment, so **skip this
> section entirely** — the §11 runbook covers everything. Keep it only as the
> playbook for ever upgrading a *live* v1 environment in place:
> rename non-conforming databases first (`ALTER DATABASE ... RENAME` +
> `terraform state rm`/`import`, never destroy/recreate), then
> `provision.py --client <slug>` *without* `--init-db` (db-setup's
> `REASSIGN OWNED` transfers existing objects to the tenant user), then install
> the platform modules into each existing DB via the migration job
> (`-i session_redis,fs_storage,fs_attachment,gcs_attachment_default`).

---

## 15. Fixes Legend — v1 Weakness → v2 Solution

| # | Weakness (v1) | Solution (v2, implemented here) |
|---|---|---|
| 1 | DB single point of failure | PITR + backups now; `db_availability_type=REGIONAL` one-variable HA flip |
| 2 | Noisy neighbor (compute & DB) | pgbouncer sidecars, `max_instances` caps, per-role `statement_timeout` + connection limits |
| 3 | Cloud Run/Odoo mismatch | min=1 + CPU boost, 3600s end-to-end timeouts, gevent websocket service, Cloud Tasks + Jobs for heavy ops |
| 4 | Weak tenant isolation via dbfilter | Per-tenant least-privilege SQL users; pgbouncer maps each DB to its own user; per-tenant secrets |
| 5 | Painful fleet migrations | Cloud Workflows orchestrator: sequential, halt-on-fail, resumable; canary traffic shift + rollback |
| 6 | Fragile GCS attachment module | `fs_storage`/`fs_attachment` (OCA 18.0) + repo-owned `gcs_attachment_default`, smoke-tested in CI |
| 7 | No observability / rate limits / cost attribution | Uptime checks + alert policies + log metrics; per-tenant (Host) Cloud Armor throttle; tenant labels everywhere |
| 8 | Cron races across replicas | Single Cron Runner service (`max_instances=1`, internal-only); all web services run `max_cron_threads=0` |

---

## 16. Deploy-Time Gotchas — Hit Once, Now Handled in Code

Every one of these failed a real apply/build during the first v2 deployment
(July 2026). They are all fixed in the repo — this table exists so nobody
re-learns them the hard way in this or any future project.

| Gotcha | Symptom | Where it's handled |
|---|---|---|
| Cloud Armor enum is `SRC_IPS_V1` (covers v4+v6); `SRC_IPS_V4` never existed | plan-time error | `terraform/shared/main.tf` |
| `PORT` is a reserved Cloud Run env (injected from `container_port`) | 400 on service create | `cloud-run-odoo` module (not set) |
| `timeout_sec` is unsupported on serverless-NEG backend services | 400 on backend create | backend services (attribute omitted; Cloud Run's 3600s governs) |
| One `/24` PSA range is fully consumed by Cloud SQL — Redis then can't allocate | "private IP space exhausted" | second `/20` range (`10.20.0.0/20`) on the peering |
| `odoo:18.0` declares `VOLUME /mnt/extra-addons` — build-time writes there are **silently discarded** (why v1's modules never worked) | modules missing at runtime | platform modules live in `/opt/extra-addons`; build assertion |
| pip `--ignore-installed` upgrades `cryptography`, breaking Debian's old pyOpenSSL (`GEN_EMAIL` AttributeError → `base` won't import → `/web/health` 404) | probe timeouts | `pyopenssl` installed from pip alongside; `import odoo` build assertion |
| `fs_storage` needs `server_environment` (OCA/server-env) + python `packaging` (to parse versioned external deps) | init job UserError | both baked into the image; `running_env` set in odoo.conf |
| `odoo -i base` loads **demo data** by default — permanent once committed | fake users in a production tenant | init job passes `--without-demo=all` |
| Odoo auto-creates DBs named in `db_name` (v15+) — the cron runner spawns empty tenant DBs before provisioning | tenant apply "already exists" | runbook pauses cron-runner during bootstrap (Phase 5→7) |
| Managed SSL certs are immutable and can't be destroyed while attached to the proxy | replace deadlock on domain change | hashed cert name + `create_before_destroy` |
| A managed cert only turns ACTIVE when **all** SANs resolve to the LB | one missing A record blocks HTTPS for everyone | runbook Phase 6; anchor domain `odoo.droob.app` in the same DNS zone as tenants |
| Cloud Run validates secret access at create time; Secret Manager IAM is eventually consistent | "Permission denied on secret" | `depends_on` grants everywhere + 30s retry in `provision.py`/CI |
| Tenant-owned databases can't be dropped via the Cloud SQL API | offboarding delete fails | documented DROP-as-`odoo_shared` procedure (§13 offboarding, step 3) |
| Empty `ODOO_SESSION_REDIS_PASSWORD` makes redis-py send `AUTH ""` to a no-auth Memorystore | every request 500s | entrypoint exports the var only when non-empty |
| `session_redis` 18.0 defaults **SSL to ON** (`ODOO_SESSION_REDIS_SSL=1`) — TLS handshake against no-TLS Memorystore hangs ~60s per request | 500s + extreme slowness | entrypoint exports `ODOO_SESSION_REDIS_SSL=0` (override with `REDIS_SSL=1` if transit encryption is enabled) |
| Odoo's `list_dbs()` only returns databases **owned by the connecting role** — with per-tenant DB owners (Fix #4), discovery as `odoo_shared` returns nothing and every host lands on the database selector | "database manager has been disabled" page on all tenants | repo-owned `platform_dblist` module (server-wide) serves the list from `ODOO_DATABASES`, which Terraform renders from clients.yaml onto all three services |
| Cloud Run services **and jobs** pin the image digest at deploy/update — not at execution | stale `:latest` after rebuild | deploy-fleet re-points everything; manual rebuilds must `services/jobs update --image` |
| OCA `fs_storage` makes `protocol`/`options`/`directory_path`/`use_as_default_for_attachments` **server-env fields** (no DB columns) when `server_environment` is installed — writing them on the `fs.storage` record is silently dropped, so attachments (incl. web asset bundles) fall back to the **ephemeral local filestore** and styling breaks on every revision roll / cold start | unstyled/heavy pages, `FileNotFoundError .../filestore/...`, 500s after any deploy | backend config supplied via `SERVER_ENV_CONFIG` (section `[fs_storage.gcs_att]`) rendered by `terraform/shared` (`local.server_env_config`) onto all three services; `gcs_attachment_default` only creates the record. JS/CSS bundles then persist in the DB (fs_attachment `force_db` rules), other attachments in GCS — both survive rolls |
| `odoo -i base` does **not** install the `web` client — a tenant provisioned without it 500s on `/web/login` (`External ID not found: web.login`) | login page 500 on a "successfully" provisioned tenant | init job installs `base,web,...` (`terraform/main.tf`) |
| `gcloud builds submit odoo-v18/` falls back to the repo `.gitignore` (which excludes `build-addons/`) when no `.gcloudignore` exists → image ships with an **empty addon catalog** | tenants' custom modules missing at runtime | `odoo-v18/.gcloudignore` explicitly keeps `build-addons/` in the upload |
| Renaming a client's `database` in clients.yaml/tfvars → `terraform plan` shows `google_sql_database.client must be replaced` (name is ForceNew) = **DESTROY the live tenant DB** | data loss on a "rename" | never plain-apply; rename in place (`ALTER DATABASE` in-VPC) + `terraform state rm`/`import`, per §13 |

