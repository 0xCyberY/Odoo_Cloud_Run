# terraform/shared/main.tf
#
# Shared project-level infrastructure (v2 hardened architecture).
# Managed independently of any client. Apply ONCE for the whole platform,
# and re-apply whenever clients.yaml changes (tenant DB users, pgbouncer map,
# SSL certificate domains, uptime checks all derive from it).

# ── Locals: client catalog (single source of truth: clients/clients.yaml) ────
locals {
  clients_config = yamldecode(file("${path.root}/../../clients/clients.yaml"))
  clients        = local.clients_config.clients
  client_domains = [for name, config in local.clients : config.domain if lookup(config, "domain", "") != ""]

  # Comma-separated tenant DB list serviced by the Cron Runner
  odoo_databases = join(",", [for name, config in local.clients : config.database])

  # db → entitled catalog repo dirs, consumed by the addon_entitlement module
  # (ODOO_ENTITLEMENTS env on all three services). The full catalog is baked
  # into the image; this map is the runtime entitlement plane — selling an
  # addon = one addon_repos entry + shared apply (revision roll), no rebuild.
  odoo_entitlements = jsonencode({
    for name, config in local.clients : config.database => lookup(config, "addon_repos", [])
  })

  # OCA fs_storage backend config, consumed by the server_environment module
  # (SERVER_ENV_CONFIG, section [fs_storage.<code>]). Routes ALL Odoo
  # attachments — including generated web asset bundles — to each tenant's GCS
  # bucket instead of the ephemeral Cloud Run local filestore, so styling and
  # attachments survive revision rolls / instance recycles. directory_path
  # templates on {db_name}; tenant buckets are <project>-<db>-corp-odoo-attachments
  # (tenant slug convention = <db>-corp). fs_storage's own fields (protocol,
  # options, directory_path, use_as_default_for_attachments) are server-env
  # driven when server_environment is installed, which is why they must come
  # from here rather than the fs.storage DB record.
  server_env_config = <<-EOT
    [fs_storage.gcs_att]
    protocol=gcs
    options={"token": "google_default", "project": "${var.gcp_project}"}
    directory_path=${var.gcp_project}-{db_name}-corp-odoo-attachments
    use_as_default_for_attachments=True
  EOT

  # Tenant-resolution validation (dbfilter = ^(%d|%h)$ — see entrypoint.sh):
  # every host must match EXACTLY ONE database, either by subdomain first
  # label (beta.nomowsoft.com → beta) or full host (super.droob.com → db of that
  # exact name, used when two clients share a first label).
  all_databases = [for name, config in local.clients : config.database]
  host_db_matches = {
    for name, config in local.clients : name => [
      for db in local.all_databases : db
      if db == split(".", trimprefix(config.domain, "www."))[0] || db == trimprefix(config.domain, "www.")
    ]
    if lookup(config, "domain", "") != ""
  }

  # Tenant slug → db/user/secret map consumed by the pgbouncer sidecars
  tenant_db_map = {
    for name, config in local.clients : name => {
      db     = config.database
      user   = config.db_user
      secret = google_secret_manager_secret.tenant_db_password[name].secret_id
    }
  }

  pooled_image    = "${var.region}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.odoo_repo.repository_id}/odoo-pooled:latest"
  pgbouncer_image = "${var.region}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.odoo_repo.repository_id}/pgbouncer:latest"

  common_labels = {
    app  = "odoo"
    tier = "shared"
  }
}

# 1. Custom VPC Network
resource "google_compute_network" "vpc" {
  name                    = "odoo-vpc"
  project                 = var.gcp_project
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# 2. Subnet for Cloud Run Egress
resource "google_compute_subnetwork" "cloudrun_subnet" {
  name          = "odoo-cloudrun-subnet"
  project       = var.gcp_project
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.100.0.0/20"
  region        = var.region
}

# 3. Private IP Range for Cloud SQL & VPC Peering
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "google-managed-services-odoo-vpc"
  project       = var.gcp_project
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  address       = "10.10.0.0"
  network       = google_compute_network.vpc.id
}

# 3b. Extension range: Cloud SQL consumes the entire /24 above for itself, so
# Memorystore (and any future second SQL instance) allocate from this /20.
resource "google_compute_global_address" "private_ip_alloc_ext" {
  name          = "google-managed-services-odoo-vpc-ext"
  project       = var.gcp_project
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  address       = "10.20.0.0"
  network       = google_compute_network.vpc.id
}

# 4. VPC Peering connection for Private Services Access (Cloud SQL + Redis)
resource "google_service_networking_connection" "private_vpc_connection" {
  network = google_compute_network.vpc.id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.private_ip_alloc.name,
    google_compute_global_address.private_ip_alloc_ext.name,
  ]
}

# 5. Shared Cloud SQL PostgreSQL Instance (No Public IP)
# v2 Fix #1: availability_type is variable-gated — flip db_availability_type to
# "REGIONAL" for HA (primary + standby, automatic failover) when tenants justify
# the ~2x instance cost. The change applies in place with a brief restart.
resource "google_sql_database_instance" "shared_db" {
  name             = "odoo-shared-pg"
  project          = var.gcp_project
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = true

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = var.db_tier
    edition           = "ENTERPRISE"
    availability_type = var.db_availability_type

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = var.db_backup_retention_count
      }
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = false
      record_client_address   = false
    }

    dynamic "database_flags" {
      for_each = var.db_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }

    user_labels = local.common_labels
  }
}

# 6. Shared Memorystore Redis (Odoo Session Store + cache)
resource "google_redis_instance" "session_cache" {
  name               = "odoo-session-cache"
  project            = var.gcp_project
  region             = var.region
  tier               = "BASIC" # Optimized for cost (single-zone, no replication replica)
  memory_size_gb     = 1       # Optimized for cost (1 GB is plenty for 10 clients)
  authorized_network = google_compute_network.vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_7_0"
  display_name  = "Odoo Shared Session Store"
  labels        = local.common_labels

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# 7. Artifact Registry for Odoo Docker Images (odoo-pooled + pgbouncer)
resource "google_artifact_registry_repository" "odoo_repo" {
  location      = var.region
  repository_id = "odoo-v18-repo"
  description   = "Docker repository for Odoo v18 custom images"
  format        = "DOCKER"
  project       = var.gcp_project
}

# 8. Cloud Armor Security Policy (WAF / Rate Limiting)
resource "google_compute_security_policy" "waf_policy" {
  name        = "odoo-cloud-armor-policy"
  project     = var.gcp_project
  description = "Cloud Armor WAF policy for Odoo SaaS"

  # Default rule: Allow all traffic
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }

  # Rate limiting rule: Limit brute force on login/database pages
  rule {
    action   = "throttle"
    priority = "1000"
    match {
      expr {
        expression = "request.path.matches('/web/login') || request.path.matches('/web/database')"
      }
    }
    rate_limit_options {
      rate_limit_threshold {
        count        = 60
        interval_sec = 60
      }
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
    }
    description = "Rate limit login attempts to 60 per minute per IP"
  }

  # v2 Fix #7: per-tenant rate limiting keyed on the Host header — one tenant
  # cannot flood the platform and starve the others.
  rule {
    action   = "throttle"
    priority = "1100"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      rate_limit_threshold {
        count        = var.per_tenant_rate_limit_per_minute
        interval_sec = 60
      }
      conform_action      = "allow"
      exceed_action       = "deny(429)"
      enforce_on_key      = "HTTP_HEADER"
      enforce_on_key_name = "Host"
    }
    description = "Per-tenant (Host header) rate limit"
  }
}

# 9. Global External HTTPS Load Balancer Frontend
resource "google_compute_global_address" "alb_ip" {
  name        = "odoo-shared-alb-ip"
  project     = var.gcp_project
  description = "Shared Static IP for Odoo SaaS Load Balancer"
}

# URL Map: default → pooled service; /websocket → dedicated gevent service
# (v2 Fix #3). Host rules for future dedicated tenants slot in here.
resource "google_compute_url_map" "alb_url_map" {
  name            = "odoo-alb-url-map"
  project         = var.gcp_project
  default_service = google_compute_backend_service.pooled_backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "odoo"
  }

  path_matcher {
    name            = "odoo"
    default_service = google_compute_backend_service.pooled_backend.id

    path_rule {
      paths   = ["/websocket", "/websocket/*"]
      service = google_compute_backend_service.websocket_backend.id
    }
  }
}

resource "google_compute_target_https_proxy" "alb_https_proxy" {
  name             = "odoo-alb-https-proxy"
  project          = var.gcp_project
  url_map          = google_compute_url_map.alb_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default_cert.id]
}

resource "google_compute_global_forwarding_rule" "alb_forwarding_rule" {
  name                  = "odoo-alb-forwarding-rule"
  project               = var.gcp_project
  target                = google_compute_target_https_proxy.alb_https_proxy.id
  port_range            = "443"
  ip_address            = google_compute_global_address.alb_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# Default Certificate (automatically extended with tenant domains).
# Also the enforcement point for clients.yaml sanity — a duplicate or
# ambiguous registration fails the plan/apply here with a clear message.
#
# The name embeds a hash of the domain set: certificates are immutable, so a
# domain change means REPLACEMENT — and the old cert can't be destroyed while
# the HTTPS proxy still uses it. A fresh name + create_before_destroy lets
# Terraform create the new cert, repoint the proxy, then drop the old one.
resource "random_id" "cert" {
  byte_length = 3
  keepers = {
    domains = join(",", concat(["saas-dev.nomowsoft.com"], local.client_domains))
  }
}

resource "google_compute_managed_ssl_certificate" "default_cert" {
  name    = "odoo-managed-cert-${random_id.cert.hex}"
  project = var.gcp_project

  managed {
    domains = concat(["saas-dev.nomowsoft.com"], local.client_domains)
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(local.client_domains) == length(distinct(local.client_domains))
      error_message = "Duplicate tenant domain in clients.yaml — two clients registered the same domain."
    }
    precondition {
      condition     = length(local.all_databases) == length(distinct(local.all_databases))
      error_message = "Duplicate database name in clients.yaml — two clients share one database."
    }
    precondition {
      condition     = alltrue([for name, matches in local.host_db_matches : length(matches) == 1])
      error_message = "Tenant host→database resolution broken (dbfilter ^(%d|%h)$): every domain must match exactly one database — name it after the subdomain, or after the full domain on first-label collisions. Run scripts/validate_clients.py for details."
    }
  }
}

# 10. Platform Database User & Credentials (admin/fallback; pgbouncer frontend)
resource "random_password" "db_shared_pass" {
  length  = 32
  special = false
}

resource "google_sql_user" "shared_user" {
  name     = "odoo_shared"
  instance = google_sql_database_instance.shared_db.name
  password = random_password.db_shared_pass.result
  project  = var.gcp_project
}

resource "google_secret_manager_secret" "shared_db_password" {
  secret_id = "odoo-shared-db-password"
  project   = var.gcp_project
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "shared_db_password" {
  secret      = google_secret_manager_secret.shared_db_password.id
  secret_data = random_password.db_shared_pass.result
}

# 11. Per-Tenant Least-Privilege Database Users (v2 Fix #4)
# Driven by clients.yaml. Each tenant's Postgres user only reaches its own
# database (enforced by the per-tenant db-setup job: REVOKE CONNECT + OWNER).
# The pgbouncer sidecars map each tenant DB to its own user, so a dbfilter
# misconfiguration or Odoo exploit cannot reach another tenant's data.
resource "random_password" "tenant_db" {
  for_each = local.clients
  length   = 32
  special  = false
}

resource "google_sql_user" "tenant" {
  for_each = local.clients
  name     = each.value.db_user
  instance = google_sql_database_instance.shared_db.name
  password = random_password.tenant_db[each.key].result
  project  = var.gcp_project
}

resource "google_secret_manager_secret" "tenant_db_password" {
  for_each  = local.clients
  secret_id = "${each.key}-db-password"
  project   = var.gcp_project
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "tenant_db_password" {
  for_each    = local.clients
  secret      = google_secret_manager_secret.tenant_db_password[each.key].id
  secret_data = random_password.tenant_db[each.key].result
}

# 12. Shared Odoo Admin (master) Password
resource "random_password" "shared_admin_pass" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "shared_admin_password" {
  secret_id = "odoo-shared-admin-password"
  project   = var.gcp_project
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "shared_admin_password" {
  secret      = google_secret_manager_secret.shared_admin_password.id
  secret_data = random_password.shared_admin_pass.result
}

# 13. Pooled Odoo Cloud Run Service — standard tenants (web traffic only)
module "cloud_run_odoo_pooled" {
  source = "../modules/cloud-run-odoo"

  # Secret VERSIONS must exist before Cloud Run resolves "latest" on first apply
  depends_on = [
    google_secret_manager_secret_version.shared_db_password,
    google_secret_manager_secret_version.shared_admin_password,
    google_secret_manager_secret_version.tenant_db_password,
  ]

  gcp_project = var.gcp_project
  region      = var.region
  client_slug = "pooled"
  image_url   = local.pooled_image

  # Tenant catalog for env-driven DB discovery (platform_dblist)
  odoo_databases = local.odoo_databases

  # Per-tenant addon entitlements (addon_entitlement module)
  env_extra = { ODOO_ENTITLEMENTS = local.odoo_entitlements, SERVER_ENV_CONFIG = local.server_env_config }

  # Network
  vpc_id    = google_compute_network.vpc.id
  subnet_id = google_compute_subnetwork.cloudrun_subnet.id

  # Database via pgbouncer sidecar (per-tenant credential routing)
  db_host               = google_sql_database_instance.shared_db.private_ip_address
  db_port               = "5432"
  db_user               = google_sql_user.shared_user.name
  db_name               = "postgres" # Default system db; Odoo routes tenants via dbfilter
  db_password_secret    = google_secret_manager_secret.shared_db_password.secret_id
  admin_password_secret = google_secret_manager_secret.shared_admin_password.secret_id

  enable_pgbouncer = true
  pgbouncer_image  = local.pgbouncer_image
  pgbouncer_cpu    = var.pgbouncer_cpu
  tenant_db_map    = local.tenant_db_map

  # Redis Session Store
  redis_host = google_redis_instance.session_cache.host
  redis_port = google_redis_instance.session_cache.port

  # Scaling & Specs (v2 Fix #3: min 1 + startup CPU boost = no cold starts;
  # max cap protects database connections — Fix #2)
  min_instances = var.pooled_min_instances
  max_instances = var.pooled_max_instances
  cpu           = "1"
  memory        = "2Gi"

  timeout = "3600s"
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels  = merge(local.common_labels, { role = "web" })
}

# 14. WebSocket Odoo Service — gevent worker for /websocket (v2 Fix #3)
module "cloud_run_odoo_websocket" {
  source = "../modules/cloud-run-odoo"

  depends_on = [
    google_secret_manager_secret_version.shared_db_password,
    google_secret_manager_secret_version.shared_admin_password,
    google_secret_manager_secret_version.tenant_db_password,
  ]

  gcp_project = var.gcp_project
  region      = var.region
  client_slug = "websocket"
  image_url   = local.pooled_image
  odoo_mode   = "websocket"

  odoo_databases = local.odoo_databases
  env_extra      = { ODOO_ENTITLEMENTS = local.odoo_entitlements, SERVER_ENV_CONFIG = local.server_env_config }

  vpc_id    = google_compute_network.vpc.id
  subnet_id = google_compute_subnetwork.cloudrun_subnet.id

  db_host               = google_sql_database_instance.shared_db.private_ip_address
  db_port               = "5432"
  db_user               = google_sql_user.shared_user.name
  db_name               = "postgres"
  db_password_secret    = google_secret_manager_secret.shared_db_password.secret_id
  admin_password_secret = google_secret_manager_secret.shared_admin_password.secret_id

  enable_pgbouncer = true
  pgbouncer_image  = local.pgbouncer_image
  pgbouncer_cpu    = var.pgbouncer_cpu
  tenant_db_map    = local.tenant_db_map

  redis_host = google_redis_instance.session_cache.host
  redis_port = google_redis_instance.session_cache.port

  min_instances     = 1
  max_instances     = 2
  cpu               = "1"
  memory            = "1Gi"
  session_affinity  = true
  concurrency       = 250   # long-lived idle websockets are cheap but count as requests
  health_probe_type = "tcp" # gevent binds the port; its HTTP surface is not probe-safe

  timeout = "3600s"
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels  = merge(local.common_labels, { role = "websocket" })
}

# 15. Cron Runner — the ONLY service with cron threads (v2 Fix #8)
# max_instances = 1 guarantees scheduled jobs never run twice across replicas;
# all web services run max_cron_threads = 0. min = 1 with CPU always allocated
# so background cron threads actually get CPU on Cloud Run.
module "cloud_run_odoo_cron" {
  source = "../modules/cloud-run-odoo"

  depends_on = [
    google_secret_manager_secret_version.shared_db_password,
    google_secret_manager_secret_version.shared_admin_password,
    google_secret_manager_secret_version.tenant_db_password,
  ]

  gcp_project = var.gcp_project
  region      = var.region
  client_slug = "cron-runner"
  image_url   = local.pooled_image
  odoo_mode   = "cron"

  odoo_databases = local.odoo_databases
  env_extra      = { ODOO_ENTITLEMENTS = local.odoo_entitlements, SERVER_ENV_CONFIG = local.server_env_config }

  vpc_id    = google_compute_network.vpc.id
  subnet_id = google_compute_subnetwork.cloudrun_subnet.id

  db_host               = google_sql_database_instance.shared_db.private_ip_address
  db_port               = "5432"
  db_user               = google_sql_user.shared_user.name
  db_name               = "postgres"
  db_password_secret    = google_secret_manager_secret.shared_db_password.secret_id
  admin_password_secret = google_secret_manager_secret.shared_admin_password.secret_id

  enable_pgbouncer = true
  pgbouncer_image  = local.pgbouncer_image
  pgbouncer_cpu    = var.pgbouncer_cpu
  tenant_db_map    = local.tenant_db_map

  redis_host = google_redis_instance.session_cache.host
  redis_port = google_redis_instance.session_cache.port

  min_instances    = 1
  max_instances    = 1
  cpu              = "1"
  memory           = "2Gi"
  session_affinity = false

  # Internal only: not reachable from the internet, no ALB backend
  ingress       = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  create_neg    = false
  public_access = false
  labels        = merge(local.common_labels, { role = "cron" })
}

# 16. Grant Cloud Run Developer to Pooled SA for running Jobs
resource "google_project_iam_member" "run_developer" {
  project = var.gcp_project
  role    = "roles/run.developer"
  member  = "serviceAccount:${module.cloud_run_odoo_pooled.service_account_email}"
}

# 17. Backend Services
resource "google_compute_backend_service" "pooled_backend" {
  name                  = "odoo-pooled-backend-service"
  project               = var.gcp_project
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  # NOTE: timeout_sec is NOT supported on serverless-NEG backends — the request
  # timeout is governed by the Cloud Run service itself (3600s, v2 Fix #3/B5).
  security_policy = google_compute_security_policy.waf_policy.id

  backend {
    group = module.cloud_run_odoo_pooled.serverless_neg_id
  }

  cdn_policy {
    cache_mode  = "CACHE_ALL_STATIC"
    default_ttl = 3600
    client_ttl  = 3600
    max_ttl     = 86400

    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }
  enable_cdn = true
}

resource "google_compute_backend_service" "websocket_backend" {
  name                  = "odoo-websocket-backend-service"
  project               = var.gcp_project
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.waf_policy.id

  backend {
    group = module.cloud_run_odoo_websocket.serverless_neg_id
  }

  # No CDN: websocket/longpolling traffic is not cacheable
  enable_cdn = false
}

# 18. Cloud Tasks Queue — heavy ops enqueueing (v2 Fix #3)
# Web services enqueue big reports/imports here; tasks trigger Cloud Run Job
# executions so heavy work never runs inside a request-scoped instance.
resource "google_cloud_tasks_queue" "heavy_ops" {
  name     = "odoo-heavy-ops"
  location = var.region
  project  = var.gcp_project

  rate_limits {
    max_concurrent_dispatches = 2
    max_dispatches_per_second = 1
  }

  retry_config {
    max_attempts = 3
    min_backoff  = "10s"
    max_backoff  = "300s"
  }
}

# 19. Fleet Migration Orchestrator — Cloud Workflows (v2 Fix #5)
# Runs each tenant's migration Cloud Run Job SEQUENTIALLY, halts on the first
# failure, and is resumable from the failed tenant via the start_from argument.
resource "google_service_account" "fleet_migrator" {
  account_id   = "odoo-fleet-migrator"
  display_name = "Odoo fleet migration workflow"
  project      = var.gcp_project
}

resource "google_project_iam_member" "fleet_migrator_run" {
  project = var.gcp_project
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.fleet_migrator.email}"
}

resource "google_workflows_workflow" "fleet_migration" {
  name            = "odoo-fleet-migration"
  project         = var.gcp_project
  region          = var.region
  description     = "Sequential per-tenant Odoo DB migration: halt on failure, resumable via start_from"
  service_account = google_service_account.fleet_migrator.id

  source_contents = <<-EOT
    main:
      params: [args]
      steps:
        - init:
            assign:
              - tenants: $${args.tenants}
              - start_from: $${default(map.get(args, "start_from"), "")}
              - started: $${start_from == ""}
              - migrated: []
        - each_tenant:
            for:
              value: tenant
              in: $${tenants}
              steps:
                - maybe_mark_started:
                    switch:
                      - condition: $${tenant == start_from}
                        steps:
                          - mark:
                              assign:
                                - started: true
                - maybe_migrate:
                    switch:
                      - condition: $${started}
                        steps:
                          - run_migration_job:
                              call: googleapis.run.v2.projects.locations.jobs.run
                              args:
                                name: $${"projects/${var.gcp_project}/locations/${var.region}/jobs/" + tenant + "-odoo-job-migration"}
                              result: job_execution
                          - record:
                              assign:
                                - migrated: $${list.concat(migrated, tenant)}
        - done:
            return:
              migrated: $${migrated}
  EOT
}

# 20. GitHub Actions CI/CD — Workload Identity Federation
# deploy-fleet.yml and update-addon.yml (google-github-actions/auth) need a
# workload_identity_provider + service_account. Neither existed after the
# 2026-08-03 project rebuild — the workflows failed with "must specify
# exactly one of workload_identity_provider or credentials_json" because both
# GitHub secrets were empty. Keyless OIDC federation (no long-lived JSON key
# to leak/rotate), scoped by attribute_condition to ONLY var.github_repo —
# no other GitHub repo, fork, or workflow can assume this identity.
resource "google_iam_workload_identity_pool" "github_actions" {
  workload_identity_pool_id = "github-actions-pool"
  project                   = var.gcp_project
  display_name              = "GitHub Actions"
  description               = "OIDC federation for this repo's CI/CD workflows (deploy-fleet, update-addon)"
}

resource "google_iam_workload_identity_pool_provider" "github_actions" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions-provider"
  project                            = var.gcp_project
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # Hard trust boundary: only tokens minted for var.github_repo are accepted,
  # regardless of what the SA IAM binding below would otherwise allow.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions_deployer" {
  account_id   = "github-actions-deployer"
  display_name = "GitHub Actions CI/CD deployer"
  project      = var.gcp_project
}

# Only workflow runs FROM var.github_repo can impersonate this SA.
resource "google_service_account_iam_member" "github_actions_wif_binding" {
  service_account_id = google_service_account.github_actions_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo}"
}

# Roles actually exercised by deploy-fleet.yml / update-addon.yml:
#   cloudbuild.builds.editor  — gcloud builds submit
#   artifactregistry.writer   — gcloud artifacts docker tags add
#   run.admin                 — gcloud run services/jobs update, jobs execute
#   iam.serviceAccountUser    — act as pooled-run-sa/websocket-run-sa/
#                                cron-runner-run-sa when updating their revisions
#   workflows.invoker         — gcloud workflows run odoo-fleet-migration
resource "google_project_iam_member" "github_actions_deployer_cloudbuild" {
  project = var.gcp_project
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

resource "google_project_iam_member" "github_actions_deployer_artifactregistry" {
  project = var.gcp_project
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

resource "google_project_iam_member" "github_actions_deployer_run" {
  project = var.gcp_project
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

resource "google_project_iam_member" "github_actions_deployer_sa_user" {
  project = var.gcp_project
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

resource "google_project_iam_member" "github_actions_deployer_workflows" {
  project = var.gcp_project
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# `gcloud builds submit` without --gcs-source-staging-dir uploads source to
# Cloud Build's auto-managed <project>_cloudbuild bucket, which requires
# broad roles/storage.admin on the caller to read/write/auto-create — that
# would ALSO grant github_actions_deployer full control over every tenant's
# attachment bucket (over-broad for a "build and deploy code" identity). A
# dedicated bucket with a bucket-scoped IAM binding keeps CI's storage access
# limited to exactly this one bucket. The workflows must pass
# --gcs-source-staging-dir=gs://<this bucket>/source explicitly.
resource "google_storage_bucket" "cloudbuild_source" {
  name                        = "${var.gcp_project}-cloudbuild-source"
  project                     = var.gcp_project
  location                    = var.region
  uniform_bucket_level_access = true

  # Source archives are only needed for the duration of a build; do not let
  # this grow unbounded.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

# roles/storage.admin here is BUCKET-scoped (via google_storage_bucket_iam_member,
# not google_project_iam_member) — it reaches only this one bucket, not every
# tenant's attachment bucket. Needed over roles/storage.objectAdmin: `gcloud
# builds submit` also calls storage.buckets.get to verify the staging bucket,
# which objectAdmin (object permissions only) does not grant — that gap is
# exactly what "user is forbidden from accessing the bucket" meant.
resource "google_storage_bucket_iam_member" "github_actions_deployer_cloudbuild_source" {
  bucket = google_storage_bucket.cloudbuild_source.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# `gcloud builds submit` submits the build as github_actions_deployer, but the
# build ITSELF executes as a separate identity — by default the project's
# default Compute Engine SA (<project_number>-compute@developer.gserviceaccount.com).
# This project deliberately doesn't grant that default SA extra roles (it has
# none of our bucket/registry access), which surfaced as "service account
# ...-compute@developer.gserviceaccount.com does not have access to the
# bucket". Matching every other purpose-built SA in this stack, use a
# dedicated execution identity instead of relying on the broad, implicit
# default. github_actions_deployer's project-wide roles/iam.serviceAccountUser
# (above) already lets it pass --service-account=this SA to gcloud builds submit.
resource "google_service_account" "cloudbuild_runner" {
  account_id   = "cloudbuild-runner"
  display_name = "Cloud Build execution SA (odoo-pooled / pgbouncer image builds)"
  project      = var.gcp_project
}

resource "google_storage_bucket_iam_member" "cloudbuild_runner_source" {
  bucket = google_storage_bucket.cloudbuild_source.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# Repo-scoped, not project-wide: the build only ever needs to push into this
# one Artifact Registry repository.
resource "google_artifact_registry_repository_iam_member" "cloudbuild_runner_artifactregistry" {
  project    = var.gcp_project
  location   = google_artifact_registry_repository.odoo_repo.location
  repository = google_artifact_registry_repository.odoo_repo.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# Required by Cloud Build whenever a non-default build service account is
# specified, regardless of the custom --gcs-log-dir above.
resource "google_project_iam_member" "cloudbuild_runner_logwriter" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}
