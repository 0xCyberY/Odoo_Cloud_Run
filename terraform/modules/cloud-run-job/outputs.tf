# terraform/modules/cloud-run-job/outputs.tf

output "job_name" {
  value       = google_cloud_run_v2_job.odoo_job.name
  description = "The name of the Cloud Run Job"
}

output "job_id" {
  value       = google_cloud_run_v2_job.odoo_job.id
  description = "The ID of the Cloud Run Job"
}
