# terraform/backend.tf
terraform {
  backend "gcs" {
    bucket = "nomowsoft-poc-tf-state"
    prefix = "odoo-saas"
  }
}
