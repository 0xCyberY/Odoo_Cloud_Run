# terraform/main.tf
#
# Root client provisioning Terraform file. Called per tenant workspace.
# Depends on terraform/shared being applied first (VPC, Cloud SQL, tenant DB
# users, pgbouncer map, ALB, certificate — all driven by clients.yaml).

# ── Data Sources (Import Shared Resources) ───────────────────────────────────
data "google_compute_network" "shared_vpc" {
  name    = "odoo-vpc"
  project = var.gcp_project
}

data "google_compute_subnetwork" "shared_subnet" {
  name    = "odoo-cloudrun-subnet"
  project = var.gcp_project
  region  = var.region
}

data "google_sql_database_instance" "shared_db" {
  name    = "odoo-shared-pg"
  project = var.gcp_project
}

data "google_compute_global_address" "alb_ip" {
  name    = "odoo-shared-alb-ip"
  project = var.gcp_project
}

locals {
  # Single source of truth for tenant settings shared with terraform/shared
  clients_config = yamldecode(file("${path.module}/../clients/clients.yaml"))
  client_config  = local.clients_config.clients[var.client_slug]

  # Tenant least-privilege PostgreSQL user (created by terraform/shared)
  db_user                = local.client_config.db_user
  db_password_secret     = "${var.client_slug}-db-password"
  shared_db_private_ip   = data.google_sql_database_instance.shared_db.private_ip_address
  pooled_service_account = "pooled-run-sa@${var.gcp_project}.iam.gserviceaccount.com"

  tenant_labels = {
    app    = "odoo"
    tenant = var.client_slug
  }

  # Mirrors terraform/shared/main.tf's local.server_env_config (same
  # [fs_storage.gcs_att] template, {db_name} substituted per-tenant by the
  # OCA server_environment module at runtime). The shared and per-tenant
  # Terraform stacks are separate states with no cross-stack variable
  # sharing, so this is duplicated rather than remote-state-read — it's a
  # simple, deterministic string, lower-risk to copy than to wire a
  # cross-stack read for. Keep both copies in sync if the schema changes.
  #
  # Without this, the init/migration Cloud Run Jobs below never had GCS
  # routing configured at all (only the three long-running services in
  # terraform/shared did) — every module install/upgrade run through these
  # Jobs wrote attachments (menu icons, compiled assets, ...) to the job
  # container's local disk, which is destroyed within seconds of the job
  # finishing. That's the root cause of attachments recurringly vanishing
  # after every fleet migration, not just a one-time bring-up artifact.
  server_env_config = <<-EOT
    [fs_storage.gcs_att]
    protocol=gcs
    options={"token": "google_default", "project": "${var.gcp_project}"}
    directory_path=${var.gcp_project}-{db_name}-corp-odoo-attachments
    use_as_default_for_attachments=True
  EOT
}

# ── Tenant Database & Odoo Admin Credentials ─────────────────────────────────
module "cloud_sql_db" {
  source             = "./modules/cloud-sql-db"
  gcp_project        = var.gcp_project
  region             = var.region
  client_slug        = var.client_slug
  database_name      = var.database_name
  admin_user         = var.admin_user
  cloud_sql_instance = data.google_sql_database_instance.shared_db.name
}

# ── GCS Bucket for Odoo API Attachment Storage ───────────────────────────────
resource "google_storage_bucket" "attachments" {
  name          = "${var.gcp_project}-${var.client_slug}-odoo-attachments"
  location      = var.region
  project       = var.gcp_project
  force_destroy = false
  labels        = local.tenant_labels

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

# Attachment access for the services that read/write files for this tenant
resource "google_storage_bucket_iam_member" "filestore_access" {
  for_each = toset([
    local.pooled_service_account,
    "cron-runner-run-sa@${var.gcp_project}.iam.gserviceaccount.com",
  ])
  bucket = google_storage_bucket.attachments.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${each.value}"
}

# ── Cloud Run Jobs ───────────────────────────────────────────────────────────
# 1. Tenant DB hardening (v2 Fixes #2 & #4): connects as the platform admin
# user and locks the database down to the tenant's least-privilege user.
module "cloud_run_db_setup_job" {
  source      = "./modules/cloud-run-job"
  gcp_project = var.gcp_project
  region      = var.region
  client_slug = var.client_slug
  job_suffix  = "db-setup"
  image_url   = var.image_url
  labels      = local.tenant_labels

  service_account_email = local.pooled_service_account

  vpc_id    = data.google_compute_network.shared_vpc.id
  subnet_id = data.google_compute_subnetwork.shared_subnet.id

  db_host               = local.shared_db_private_ip
  db_port               = "5432"
  db_user               = "odoo_shared"
  db_name               = "postgres"
  db_password_secret    = "odoo-shared-db-password"
  admin_password_secret = module.cloud_sql_db.admin_password_secret_id

  command = ["/db-setup.sh"]
  args    = []

  env_extra = {
    TENANT_DB          = module.cloud_sql_db.database_name
    TENANT_USER        = local.db_user
    TENANT_ADMIN_LOGIN = var.admin_user
  }
}

# 2. Database initialization job (first provisioning): installs base plus the
# platform GCS attachment module, pointing it at this tenant's bucket.
module "cloud_run_init_job" {
  source      = "./modules/cloud-run-job"
  gcp_project = var.gcp_project
  region      = var.region
  client_slug = var.client_slug
  job_suffix  = "init"
  image_url   = var.image_url
  labels      = local.tenant_labels

  service_account_email = local.pooled_service_account

  vpc_id    = data.google_compute_network.shared_vpc.id
  subnet_id = data.google_compute_subnetwork.shared_subnet.id

  # Runs as the tenant's own user so every created object is tenant-owned
  db_host               = local.shared_db_private_ip
  db_port               = "5432"
  db_user               = local.db_user
  db_name               = module.cloud_sql_db.database_name
  db_password_secret    = local.db_password_secret
  admin_password_secret = module.cloud_sql_db.admin_password_secret_id

  args = [
    "-d", module.cloud_sql_db.database_name,
    # web: the Odoo web client — NOT auto-installed by `-i base`; without it a
    # tenant's /web/login 500s ("External ID not found: web.login"). See README §16.
    "-i", "base,web,gcs_attachment_default,addon_entitlement",
    "--without-demo=all",
    "--stop-after-init",
  ]

  env_extra = {
    GCS_BUCKET        = google_storage_bucket.attachments.name
    SERVER_ENV_CONFIG = local.server_env_config
  }
}

# 3. Database migration job (fleet upgrades): -u all, executed sequentially per
# tenant by the odoo-fleet-migration Cloud Workflow (v2 Fix #5).
module "cloud_run_migration_job" {
  source      = "./modules/cloud-run-job"
  gcp_project = var.gcp_project
  region      = var.region
  client_slug = var.client_slug
  job_suffix  = "migration"
  image_url   = var.image_url
  labels      = local.tenant_labels

  service_account_email = local.pooled_service_account

  vpc_id    = data.google_compute_network.shared_vpc.id
  subnet_id = data.google_compute_subnetwork.shared_subnet.id

  db_host               = local.shared_db_private_ip
  db_port               = "5432"
  db_user               = local.db_user
  db_name               = module.cloud_sql_db.database_name
  db_password_secret    = local.db_password_secret
  admin_password_secret = module.cloud_sql_db.admin_password_secret_id

  args = [
    "-d", module.cloud_sql_db.database_name,
    "-u", "all",
    "--stop-after-init",
  ]

  env_extra = {
    GCS_BUCKET        = google_storage_bucket.attachments.name
    SERVER_ENV_CONFIG = local.server_env_config
  }
}

# NOTE: no per-tenant cron job / Cloud Scheduler here anymore. Scheduled jobs
# run exclusively on the shared Cron Runner service (max_instances = 1,
# terraform/shared) — v2 Fix #8: no duplicate cron runs, no locking hacks.

# ── DNS Configuration ────────────────────────────────────────────────────────
resource "google_dns_record_set" "client_dns" {
  count        = var.manage_dns ? 1 : 0
  name         = "${var.domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_managed_zone
  project      = var.gcp_project
  rrdatas      = [data.google_compute_global_address.alb_ip.address]
}
