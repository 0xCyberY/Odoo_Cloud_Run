# terraform/modules/cloud-run-job/main.tf
#
# Module for provisioning a Cloud Run Job (DB init/migration, tenant DB setup,
# heavy ops). By default the image entrypoint (/entrypoint.sh) runs so that
# /etc/odoo/odoo.conf is generated before Odoo starts; only `args` are appended.

resource "google_cloud_run_v2_job" "odoo_job" {
  name     = var.job_suffix == "" ? "${var.client_slug}-odoo-job" : "${var.client_slug}-odoo-job-${var.job_suffix}"
  location = var.region
  project  = var.gcp_project
  labels   = var.labels

  template {
    template {
      service_account = var.service_account_email
      timeout         = var.task_timeout
      max_retries     = var.max_retries

      # Direct VPC Egress for private-IP database connectivity
      vpc_access {
        network_interfaces {
          network    = var.vpc_id
          subnetwork = var.subnet_id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = var.image_url
        command = var.command
        args    = var.args

        # ── Environment Variables ─────────────────────────────────────────────
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
          name  = "DB_NAME"
          value = var.db_name
        }

        # Operator context signal for the addon_entitlement module: these Jobs
        # are the ONLY legitimate module install/upgrade path (operator-run
        # CLI). The three long-running services (cloud-run-odoo module) never
        # set this, so tenant-triggered code — including ir.cron scheduled
        # actions on the cron-runner, which run with no HTTP request bound —
        # is always gated. Tenants cannot set container env, so it is a trusted
        # boundary; its absence means "enforce entitlements" (fail closed).
        env {
          name  = "ODOO_ENTITLEMENT_BYPASS"
          value = "1"
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

        resources {
          limits = {
            cpu    = var.cpu
            memory = var.memory
          }
        }
      }
    }
  }

  lifecycle {
    # The image tag is advanced by the CI/CD pipeline (deploy-fleet.yml).
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }
}
