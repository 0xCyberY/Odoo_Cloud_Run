# terraform/modules/cloud-run-odoo/main.tf
#
# Module for provisioning an Odoo service on Google Cloud Run (v2 architecture).
# Supports three roles via var.odoo_mode: web (pooled), cron (single Cron
# Runner), websocket (gevent). Optionally runs a pgbouncer sidecar that maps
# each tenant database to its least-privilege PostgreSQL user.

locals {
  use_pgbouncer = var.enable_pgbouncer
  odoo_db_host  = local.use_pgbouncer ? "127.0.0.1" : var.db_host
  odoo_db_port  = local.use_pgbouncer ? "6432" : var.db_port

  # slug → env var name holding that tenant's DB password inside the sidecar
  tenant_pass_env = {
    for slug, t in var.tenant_db_map :
    slug => "TENANT_DB_PASSWORD_${upper(replace(slug, "-", "_"))}"
  }
  pgb_tenants = join(";", [
    for slug, t in var.tenant_db_map :
    "${t.db}:${t.user}:${local.tenant_pass_env[slug]}"
  ])
}

# 1. Dedicated Service Account
resource "google_service_account" "cloud_run_sa" {
  account_id   = "${var.client_slug}-run-sa"
  display_name = "Cloud Run SA — ${var.client_slug} Odoo"
  project      = var.gcp_project
}

# 2. Least-Privilege IAM Bindings
resource "google_project_iam_member" "sql_client" {
  project = var.gcp_project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "db_password" {
  project   = var.gcp_project
  secret_id = var.db_password_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "admin_password" {
  project   = var.gcp_project
  secret_id = var.admin_password_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "redis_password" {
  count     = var.redis_password_secret != "" ? 1 : 0
  project   = var.gcp_project
  secret_id = var.redis_password_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Per-tenant DB password secrets consumed by the pgbouncer sidecar
resource "google_secret_manager_secret_iam_member" "tenant_db_password" {
  for_each  = var.tenant_db_map
  project   = var.gcp_project
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# 3. Cloud Run Service (Compute Layer)
resource "google_cloud_run_v2_service" "odoo" {
  name     = "${var.client_slug}-odoo"
  location = var.region
  project  = var.gcp_project
  ingress  = var.ingress
  labels   = var.labels

  # Cloud Run validates secret access at revision creation — the SA's accessor
  # grants must exist first, or a fresh-project apply races and fails with
  # "Permission denied on secret".
  depends_on = [
    google_secret_manager_secret_iam_member.db_password,
    google_secret_manager_secret_iam_member.admin_password,
    google_secret_manager_secret_iam_member.redis_password,
    google_secret_manager_secret_iam_member.tenant_db_password,
  ]

  template {
    service_account = google_service_account.cloud_run_sa.email
    labels          = var.labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Sticky routing (websocket/longpolling and warm cache hits)
    session_affinity = var.session_affinity
    timeout          = var.timeout

    # Requests per instance before scaling out. Threaded Odoo on ~1 vCPU is
    # memory-bound: keep this well below the Cloud Run default of 80 so
    # instances scale out before they degrade. The websocket service overrides
    # this upward — long-lived idle sockets are cheap but count as requests.
    max_instance_request_concurrency = var.concurrency

    # Direct VPC Egress for fully private networking (Cloud SQL + Redis)
    vpc_access {
      network_interfaces {
        network    = var.vpc_id
        subnetwork = var.subnet_id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      name       = "odoo"
      image      = var.image_url
      depends_on = local.use_pgbouncer ? ["pgbouncer"] : null

      ports {
        container_port = 8069
      }

      # ── Environment Variables ─────────────────────────────────────────────
      # (PORT is reserved: Cloud Run injects it automatically from container_port)
      env {
        name  = "ODOO_MODE"
        value = var.odoo_mode
      }
      env {
        name  = "DB_HOST"
        value = local.odoo_db_host
      }
      env {
        name  = "DB_PORT"
        value = local.odoo_db_port
      }
      env {
        name  = "DB_USER"
        value = var.db_user
      }
      env {
        name  = "DB_NAME"
        value = var.db_name
      }
      env {
        name  = "REDIS_HOST"
        value = var.redis_host
      }
      env {
        name  = "REDIS_PORT"
        value = var.redis_port
      }

      dynamic "env" {
        for_each = var.odoo_databases != "" ? [1] : []
        content {
          name  = "ODOO_DATABASES"
          value = var.odoo_databases
        }
      }

      dynamic "env" {
        for_each = var.env_extra
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.db_password_secret
            version = "latest"
          }
        }
      }

      env {
        name = "ADMIN_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.admin_password_secret
            version = "latest"
          }
        }
      }

      dynamic "env" {
        for_each = var.redis_password_secret != "" ? [1] : []
        content {
          name = "REDIS_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.redis_password_secret
              version = "latest"
            }
          }
        }
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        startup_cpu_boost = true
        # min_instances > 0 → CPU always allocated (required for the Cron
        # Runner's background threads and for websocket push)
        cpu_idle = var.min_instances > 0 ? false : true
      }

      startup_probe {
        dynamic "http_get" {
          for_each = var.health_probe_type == "http" ? [1] : []
          content {
            path = "/web/health"
            port = 8069
          }
        }
        # TCP probe for the gevent websocket worker: it binds the port but its
        # HTTP surface is not guaranteed for /web/health.
        dynamic "tcp_socket" {
          for_each = var.health_probe_type == "tcp" ? [1] : []
          content {
            port = 8069
          }
        }
        initial_delay_seconds = 15
        period_seconds        = 10
        failure_threshold     = 20
        timeout_seconds       = 5
      }

      # Liveness probes support HTTP only (not TCP) on Cloud Run
      dynamic "liveness_probe" {
        for_each = var.health_probe_type == "http" ? [1] : []
        content {
          http_get {
            path = "/web/health"
            port = 8069
          }
          period_seconds    = 30
          failure_threshold = 3
          timeout_seconds   = 5
        }
      }
    }

    # ── pgbouncer sidecar (v2 Fixes #2 & #4) ────────────────────────────────
    # Pools/caps connections to Cloud SQL and maps each tenant database to its
    # own least-privilege PostgreSQL user.
    dynamic "containers" {
      for_each = local.use_pgbouncer ? [1] : []
      content {
        name  = "pgbouncer"
        image = var.pgbouncer_image

        env {
          name  = "DB_HOST"
          value = var.db_host
        }
        env {
          name  = "DB_PORT"
          value = var.db_port
        }
        env {
          name  = "DB_USER"
          value = var.db_user
        }
        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.db_password_secret
              version = "latest"
            }
          }
        }
        env {
          name  = "PGB_TENANTS"
          value = local.pgb_tenants
        }
        env {
          name  = "PGB_DEFAULT_POOL_SIZE"
          value = var.pgbouncer_default_pool_size
        }
        env {
          name  = "PGB_MAX_DB_CONNECTIONS"
          value = var.pgbouncer_max_db_connections
        }

        dynamic "env" {
          for_each = var.tenant_db_map
          content {
            name = local.tenant_pass_env[env.key]
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = "latest"
              }
            }
          }
        }

        resources {
          limits = {
            cpu    = var.pgbouncer_cpu
            memory = var.pgbouncer_memory
          }
          cpu_idle = var.min_instances > 0 ? false : true
        }

        startup_probe {
          tcp_socket {
            port = 6432
          }
          period_seconds    = 2
          failure_threshold = 15
          timeout_seconds   = 2
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    # Image and traffic split are managed by the CI/CD pipeline
    # (deploy-fleet.yml: no-traffic revision → canary 10/50/100 → rollback).
    ignore_changes = [
      template[0].containers[0].image,
      traffic,
    ]
  }
}

# 4. Serverless NEG for Global Application Load Balancer Integration
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  count                 = var.create_neg ? 1 : 0
  name                  = "${var.client_slug}-neg"
  project               = var.gcp_project
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.odoo.name
  }
}

# 5. IAM: unauthenticated invocation (the ALB fronts the service; ingress is
# restricted to the load balancer via var.ingress)
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  count    = var.public_access ? 1 : 0
  project  = var.gcp_project
  location = var.region
  name     = google_cloud_run_v2_service.odoo.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
