# terraform/shared/outputs.tf

output "alb_ip" {
  value       = google_compute_global_address.alb_ip.address
  description = "Static IP of the shared ALB — point every tenant domain (and saas-dev.nomowsoft.com) A record here"
}

output "sql_private_ip" {
  value       = google_sql_database_instance.shared_db.private_ip_address
  description = "Cloud SQL private IP (VPC-internal only)"
}

output "sql_connection_name" {
  value       = google_sql_database_instance.shared_db.connection_name
  description = "Cloud SQL connection name (for Cloud SQL Auth Proxy / psql via proxy)"
}

output "redis_host" {
  value       = google_redis_instance.session_cache.host
  description = "Memorystore Redis host (VPC-internal only)"
}

output "artifact_registry" {
  value       = "${var.region}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.odoo_repo.repository_id}"
  description = "Docker registry path for odoo-pooled and pgbouncer images"
}

output "ssl_certificate" {
  value       = google_compute_managed_ssl_certificate.default_cert.name
  description = "Managed certificate name — check provisioning status after pointing DNS"
}

output "github_actions_workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github_actions.name
  description = "Set as the GCP_WORKLOAD_IDENTITY_PROVIDER secret in the repo's 'production' GitHub environment"
}

output "github_actions_service_account" {
  value       = google_service_account.github_actions_deployer.email
  description = "Set as the GCP_SERVICE_ACCOUNT secret in the repo's 'production' GitHub environment"
}
