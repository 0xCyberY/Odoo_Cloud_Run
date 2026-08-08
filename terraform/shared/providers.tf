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

  # Without this, the provider infers which project to bill/attribute API
  # calls to from the calling credential's own ADC quota-project state. A
  # human's ADC file carries one (scripts/tf.sh and provision.py's
  # _sync_adc_quota_project keep it synced) — but Workload Identity
  # Federation credentials (google-github-actions/auth in CI) don't, and
  # some Cloud Resource Manager calls (the ones backing
  # google_project_iam_member / google_project_service) then fail closed
  # with a misleading "API has not been used in project ... or it is
  # disabled" even though the API is enabled and the resources already
  # exist — this exact config applied cleanly from a human session moments
  # before hitting this in CI. Pinning it explicitly removes the
  # credential-type dependency entirely.
  user_project_override = true
  billing_project       = var.gcp_project
}
