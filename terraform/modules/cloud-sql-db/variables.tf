# terraform/modules/cloud-sql-db/variables.tf
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
  description = "Client identifier slug"
}

variable "database_name" {
  type        = string
  description = "Name of the PostgreSQL database to create"
}

variable "cloud_sql_instance" {
  type        = string
  description = "The name of the shared PostgreSQL instance"
  default     = "odoo-shared-pg"
}

variable "admin_user" {
  type        = string
  description = "Odoo admin login email for this tenant (e.g. admin@acme-corp.com)"
}
