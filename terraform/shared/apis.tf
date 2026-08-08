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
#
# cloudresourcemanager.googleapis.com is a special case: like
# storage.googleapis.com (needed for Phase 2's state bucket before
# Terraform can even init), the google provider itself calls into Cloud
# Resource Manager to resolve the project for virtually every
# project-scoped resource — including google_project_service, the resource
# managing THIS list. On a truly fresh project it can't self-heal the way
# the others can; it must be enabled manually first (README Phase 1). It's
# still declared here so a project where it's already enabled (the normal
# case — most projects have it on by default) gets it tracked/documented,
# and so re-applies after any drift stay self-healing.
#
# Hit in production (2026-08-10): every google_project_service and
# google_project_iam_member resource failed with a misleading "Cloud
# Resource Manager API has not been used ... or it is disabled" — but only
# in CI (WIF credentials), not from a local human session, on the SAME
# project, for the SAME resources. Root cause was two compounding issues:
# (1) this API genuinely wasn't enabled, and (2) the google provider had no
# explicit user_project_override/billing_project (see providers.tf), so
# local applies were accidentally billing Cloud Resource Manager calls
# against a human ADC quota project that happened to have it enabled,
# silently masking the gap — while CI's WIF credentials have no such
# fallback and failed consistently. Fixing only the provider config (so
# both environments behave identically) would have just made local fail
# the same confusing way too; fixing only the API would have left the
# masking behavior in place for the next gap like this one. Both were
# needed.
locals {
  required_apis = toset([
    "cloudresourcemanager.googleapis.com",
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
