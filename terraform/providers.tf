# terraform/providers.tf
terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.region

  # See terraform/shared/providers.tf for why this matters — same
  # ADC-quota-project-vs-WIF-credentials gap applies to this workspace's
  # provider too, since CI runs terraform apply here as well
  # (scripts/provision.py's tenant workspace apply / scripts/destroy.py).
  user_project_override = true
  billing_project       = var.gcp_project
}
