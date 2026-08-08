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

# The next four outputs are only meaningful once enable_certificate_manager =
# true has been applied — until then they resolve to null/empty, which is the
# correct signal to callers (e.g. onboard_client.py) that Phase 1.5 hasn't
# landed yet, rather than erroring on a reference to a resource with 0 instances.
output "certificate_manager_enabled" {
  value       = var.enable_certificate_manager
  description = "Whether the Phase 1.5 Certificate Manager migration is live. False = still on the legacy shared-SAN cert (ssl_certificate output)."
}

output "ssl_certificate" {
  value       = var.enable_certificate_manager ? null : google_compute_managed_ssl_certificate.default_cert[0].name
  description = "Legacy shared-SAN managed certificate name (only set while certificate_manager_enabled = false) — check provisioning status after pointing DNS"
}

output "certificate_map" {
  value       = var.enable_certificate_manager ? google_certificate_manager_certificate_map.default[0].name : null
  description = "Certificate Manager map name — the https proxy's cert source of truth once certificate_manager_enabled = true"
}

output "dns_authorization_records" {
  value = {
    for key, auth in google_certificate_manager_dns_authorization.tenant : key => {
      domain = auth.domain
      name   = auth.dns_resource_record[0].name
      type   = auth.dns_resource_record[0].type
      data   = auth.dns_resource_record[0].data
    }
  }
  description = "Per-domain DNS authorization CNAME each domain owner must add before its cert activates. Keyed by client slug ('platform-anchor' for saas-dev.nomowsoft.com). Empty until certificate_manager_enabled = true. onboard_client.py reads this and surfaces it to the client to add manually at their own DNS provider."
}

output "certificate_status" {
  value = {
    for key, cert in google_certificate_manager_certificate.tenant : key => {
      domain = local.cert_domains[key]
      state  = try(cert.managed[0].state, "UNKNOWN")
    }
  }
  description = "Per-domain certificate provisioning state — unlike the old shared-SAN cert, one domain stuck PROVISIONING no longer blocks the others from reaching ACTIVE. Empty until certificate_manager_enabled = true."
}

output "github_actions_workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github_actions.name
  description = "Set as the GCP_WORKLOAD_IDENTITY_PROVIDER secret in the repo's 'production' GitHub environment"
}

output "github_actions_service_account" {
  value       = google_service_account.github_actions_deployer.email
  description = "Set as the GCP_SERVICE_ACCOUNT secret in the repo's 'production' GitHub environment"
}
