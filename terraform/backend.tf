# terraform/backend.tf
# Partial config: no bucket hardcoded here (GCS backend blocks can't use
# variables) — pass it at init time, e.g. via scripts/tf.sh which derives it
# from the currently active `gcloud config get-value project`.
terraform {
  backend "gcs" {
    prefix = "odoo-saas"
  }
}
