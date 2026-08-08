# terraform/shared/variables.tf
variable "gcp_project" {
  type        = string
  description = "The GCP project ID (no default — pass explicitly or via TF_VAR_gcp_project, e.g. scripts/tf.sh)"
}

variable "region" {
  type        = string
  description = "The GCP region"
  default     = "europe-west1"
}

variable "db_tier" {
  type        = string
  description = "Cloud SQL machine tier"
  default     = "db-custom-1-3840" # Optimized for cost (1 vCPU, 3.75 GiB RAM)
}

variable "db_availability_type" {
  type        = string
  description = "v2 Fix #1: ZONAL (cost-optimized, POC) or REGIONAL (HA: primary + standby, auto failover, ~2x cost). Switching applies in place with a brief restart."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.db_availability_type)
    error_message = "db_availability_type must be ZONAL or REGIONAL."
  }
}

variable "db_backup_retention_count" {
  type        = number
  description = "Number of automated backups to retain (7-35)"
  default     = 14
}

variable "db_flags" {
  type        = map(string)
  description = "PostgreSQL database flags (instance-wide). Per-tenant statement_timeout / connection limits are set per role by the db-setup job."
  default = {
    max_connections = "100"
  }
}

variable "pooled_min_instances" {
  type        = number
  description = "Pooled service warm floor (v2 Fix #3: 1 eliminates cold starts)"
  default     = 1
}

variable "pooled_max_instances" {
  type        = number
  description = "Pooled service scale cap (v2 Fix #2: protects DB connections)"
  default     = 3
}

variable "pgbouncer_cpu" {
  type        = string
  description = "CPU limit for the pgbouncer sidecar in every service. If Cloud Run rejects fractional CPU for sidecar containers, re-apply with -var pgbouncer_cpu=1"
  default     = "0.5"
}

variable "per_tenant_rate_limit_per_minute" {
  type        = number
  description = "Cloud Armor per-tenant (Host header) request budget per minute (v2 Fix #7)"
  default     = 600
}

variable "github_repo" {
  type        = string
  description = "GitHub \"owner/repo\" allowed to authenticate as the CI/CD deployer via Workload Identity Federation — scoped to exactly this repo, no other GitHub repo can assume the role."
  default     = "0xCyberY/Odoo_Cloud_Run"
}

variable "enable_certificate_manager" {
  type        = bool
  default     = true
  description = "Cuts over from the single shared-SAN google_compute_managed_ssl_certificate to per-domain Certificate Manager. The migration has been applied and is now the live setup (acme/beta/mac all on per-domain certs), so this defaults true so a routine plan/apply matches production. Flip to false only in an apply whose entire purpose is reverting to the legacy shared-SAN certificate — that, too, affects live HTTPS for every existing tenant and must never happen as a side effect of a routine tenant onboarding/provisioning apply (which also runs `terraform apply` on this same shared workspace)."
}
