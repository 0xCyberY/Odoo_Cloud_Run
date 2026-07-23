# terraform/outputs.tf

output "service_url" {
  value       = "https://${var.domain}"
  description = "The URL of the client Odoo instance (routed through shared ALB)"
}

output "filestore_bucket_name" {
  value       = google_storage_bucket.attachments.name
  description = "The GCS bucket allocated for client attachments"
}

output "database" {
  value       = module.cloud_sql_db.database_name
  description = "The tenant database name"
}

output "migration_job_name" {
  value       = module.cloud_run_migration_job.job_name
  description = "The name of the Cloud Run Job for database migrations"
}

output "init_job_name" {
  value       = module.cloud_run_init_job.job_name
  description = "The name of the Cloud Run Job for first-time database initialization"
}

output "db_setup_job_name" {
  value       = module.cloud_run_db_setup_job.job_name
  description = "The name of the Cloud Run Job that hardens the tenant database (least-privilege user)"
}
