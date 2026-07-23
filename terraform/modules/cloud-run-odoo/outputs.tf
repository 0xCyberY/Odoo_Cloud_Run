# terraform/modules/cloud-run-odoo/outputs.tf

output "service_url" {
  value       = google_cloud_run_v2_service.odoo.uri
  description = "The direct URL of the Cloud Run service"
}

output "service_name" {
  value       = google_cloud_run_v2_service.odoo.name
  description = "The name of the Cloud Run service"
}

output "service_account_email" {
  value       = google_service_account.cloud_run_sa.email
  description = "The email of the dedicated service account"
}

output "serverless_neg_id" {
  value       = var.create_neg ? google_compute_region_network_endpoint_group.serverless_neg[0].id : null
  description = "The Serverless NEG resource ID (null when create_neg = false)"
}
