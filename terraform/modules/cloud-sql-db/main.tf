# terraform/modules/cloud-sql-db/main.tf
#
# Tenant database + Odoo admin credentials. The tenant's least-privilege
# PostgreSQL user and its password secret are owned by terraform/shared
# (driven by clients.yaml) so the pooled service's pgbouncer sidecar and this
# workspace never race each other.

# 1. Tenant PostgreSQL Database (isolated per client)
resource "google_sql_database" "client" {
  name     = var.database_name
  instance = var.cloud_sql_instance
  project  = var.gcp_project
}

# 2. Tenant Odoo Admin Credentials in GCP Secret Manager
resource "random_password" "admin" {
  length  = 24
  special = true
}

resource "google_secret_manager_secret" "admin_user" {
  secret_id = "${var.client_slug}-admin-user"
  project   = var.gcp_project
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "admin_user" {
  secret      = google_secret_manager_secret.admin_user.id
  secret_data = var.admin_user
}

resource "google_secret_manager_secret" "admin_pass" {
  secret_id = "${var.client_slug}-admin-password"
  project   = var.gcp_project
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "admin_pass" {
  secret      = google_secret_manager_secret.admin_pass.id
  secret_data = random_password.admin.result
}

# 3. Grant shared pooled SA access to read the admin password for this tenant
resource "google_secret_manager_secret_iam_member" "admin_pass_access" {
  project   = var.gcp_project
  secret_id = google_secret_manager_secret.admin_pass.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:pooled-run-sa@${var.gcp_project}.iam.gserviceaccount.com"
}
