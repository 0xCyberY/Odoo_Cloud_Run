# terraform/modules/cloud-run-job/variables.tf

variable "gcp_project" {
  type        = string
  description = "The GCP project ID"
}

variable "region" {
  type        = string
  description = "The GCP region"
}

variable "client_slug" {
  type        = string
  description = "Unique client slug (e.g. client-a)"
}

variable "image_url" {
  type        = string
  description = "The container image URL in Artifact Registry"
}

variable "service_account_email" {
  type        = string
  description = "The email of the service account under which the job executes"
}

variable "vpc_id" {
  type        = string
  description = "The ID of the VPC Network"
}

variable "subnet_id" {
  type        = string
  description = "The ID of the VPC Subnetwork for Egress"
}

variable "db_host" {
  type        = string
  description = "Database host address"
}

variable "db_port" {
  type        = string
  description = "Database port"
  default     = "5432"
}

variable "db_user" {
  type        = string
  description = "Database username"
}

variable "db_name" {
  type        = string
  description = "Database name for the job execution"
}

variable "db_password_secret" {
  type        = string
  description = "Secret ID containing the database password"
}

variable "admin_password_secret" {
  type        = string
  description = "Secret ID containing Odoo admin password"
}

variable "command" {
  type        = list(string)
  description = "Entrypoint override. Leave null to run /entrypoint.sh (which generates odoo.conf) and append args"
  default     = null
}

variable "args" {
  type        = list(string)
  description = "Arguments appended to the entrypoint (e.g. [\"-d\", \"acme\", \"-u\", \"all\", \"--stop-after-init\"])"
  default     = ["--stop-after-init"]
}

variable "env_extra" {
  type        = map(string)
  description = "Additional plain environment variables (e.g. TENANT_DB, TENANT_USER, GCS_BUCKET)"
  default     = {}
}

variable "task_timeout" {
  type        = string
  description = "Max duration for a job task (migrations can be slow)"
  default     = "3600s"
}

variable "max_retries" {
  type        = number
  description = "Retries per task. 0 for migrations: they must not re-run blindly on failure"
  default     = 0
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the job (cost attribution / observability)"
  default     = {}
}

variable "cpu" {
  type        = string
  description = "CPU limit (e.g. 1, 2)"
  default     = "2"
}

variable "memory" {
  type        = string
  description = "Memory limit (e.g. 2Gi, 4Gi)"
  default     = "4Gi"
}

variable "job_suffix" {
  type        = string
  description = "Optional suffix to distinguish multiple jobs (e.g., 'cron')"
  default     = ""
}

