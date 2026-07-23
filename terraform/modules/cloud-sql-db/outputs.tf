# terraform/modules/cloud-sql-db/outputs.tf

output "database_name" {
  value       = google_sql_database.client.name
  description = "The database name"
}

output "admin_user" {
  value       = var.admin_user
  description = "Odoo admin login email"
}

output "admin_password" {
  value       = random_password.admin.result
  description = "Odoo admin password (sensitive)"
  sensitive   = true
}

output "admin_password_secret_id" {
  value       = google_secret_manager_secret.admin_pass.secret_id
  description = "GCP Secret Manager secret ID for the Odoo admin password"

  # Jobs referencing this secret are validated by Cloud Run at creation time —
  # they must not be created before the pooled SA's accessor grant exists.
  depends_on = [
    google_secret_manager_secret_iam_member.admin_pass_access,
    google_secret_manager_secret_version.admin_pass,
  ]
}

