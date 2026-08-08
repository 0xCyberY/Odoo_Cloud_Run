# Required GCP APIs, Terraform-managed.
#
# Previously these were only documented in README Phase 1 as a manual
# `gcloud services enable` step, run once by hand before the first apply.
# That step is easy to skip or fall out of sync with the code — it did,
# twice: this project's Cloud Run/SQL/Redis APIs were enabled by hand after
# the 2026-08-03 project migration, but nobody re-ran the (undocumented)
# equivalent for Certificate Manager when the Phase 1.5 migration added it,
# so the first `enable_certificate_manager=true` apply 403'd on every
# certificate_manager resource. Declaring every required API here makes a
# fresh or rebuilt project self-sufficient on `terraform apply` — no
# separate manual step to remember or keep in sync with README.
#
# disable_on_destroy = false: destroying this stack (or a future
# `terraform destroy` for cleanup) must never disable APIs a sibling
# workspace (tenant applies) or a future re-apply still needs.
locals {
  required_apis = toset([
    "compute.googleapis.com",
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "workflows.googleapis.com",
    "cloudtasks.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each                   = local.required_apis
  project                    = var.gcp_project
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}
