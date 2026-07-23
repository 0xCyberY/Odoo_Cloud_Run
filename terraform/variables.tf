# terraform/variables.tf

variable "gcp_project" {
  type        = string
  description = "The GCP project ID to deploy to"
  default     = "nomowsoft-poc"
}

variable "region" {
  type        = string
  description = "The GCP region to deploy to"
  default     = "europe-west1"
}

variable "client_slug" {
  type        = string
  description = "The unique slug identifying the client (e.g. acme-corp)"
}

variable "domain" {
  type        = string
  description = "The public domain/subdomain for Odoo"
}

variable "database_name" {
  type        = string
  description = "Name of the Cloud SQL PostgreSQL database"
}

variable "admin_user" {
  type        = string
  description = "Odoo admin login email for this tenant"
}

variable "image_url" {
  type        = string
  description = "The container image URL in Artifact Registry (pooled or dedicated)"
}


variable "manage_dns" {
  type        = bool
  description = "Whether to manage the DNS A-record automatically via GCP Cloud DNS"
  default     = false
}

variable "dns_managed_zone" {
  type        = string
  description = "The name of the GCP Cloud DNS managed zone"
  default     = ""
}
