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
}
