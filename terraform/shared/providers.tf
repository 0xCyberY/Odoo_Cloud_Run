# terraform/shared/providers.tf
terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  # Partial config: no bucket hardcoded here (GCS backend blocks can't use
  # variables) — pass it at init time, e.g. via scripts/tf.sh which derives it
  # from the currently active `gcloud config get-value project`.
  backend "gcs" {
    prefix = "odoo-saas-shared"
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.region
}
