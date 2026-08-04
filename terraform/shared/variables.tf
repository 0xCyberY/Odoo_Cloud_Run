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

variable "alert_email" {
  type        = string
  description = "Email address for Cloud Monitoring alert notifications (empty disables the channel)"
  default     = ""
}
