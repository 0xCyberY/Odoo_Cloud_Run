# terraform/shared/monitoring.tf
#
# v2 Fix #7 — Observability: uptime checks per tenant domain, alerting on
# latency / 5xx / DB / Redis saturation, cron failure log metric.
# All resources derive from clients.yaml (same locals as main.tf).

locals {
  tenant_domains = {
    for name, config in local.clients : name => config.domain
    if lookup(config, "domain", "") != ""
  }
  alert_channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.gcp_project
  display_name = "Odoo platform alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# ── Uptime checks: one per tenant domain ─────────────────────────────────────
resource "google_monitoring_uptime_check_config" "tenant" {
  for_each     = local.tenant_domains
  project      = var.gcp_project
  display_name = "odoo-${each.key}-uptime"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/web/health"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.gcp_project
      host       = each.value
    }
  }
}

resource "google_monitoring_alert_policy" "uptime_failure" {
  for_each              = local.tenant_domains
  project               = var.gcp_project
  display_name          = "Odoo tenant down: ${each.key} (${each.value})"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Uptime check failing for ${each.value}"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.tenant[each.key].uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 1
      }
    }
  }
}

# ── Cloud Run: 5xx rate and p95 latency on the pooled service ────────────────
resource "google_monitoring_alert_policy" "pooled_5xx" {
  project               = var.gcp_project
  display_name          = "Odoo pooled service 5xx rate"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "5xx responses > 1/s over 5 minutes"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_count\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"pooled-odoo\" AND metric.labels.response_code_class=\"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "pooled_latency" {
  project               = var.gcp_project
  display_name          = "Odoo pooled service p95 latency"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "p95 request latency > 5s over 10 minutes"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_latencies\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"pooled-odoo\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5000
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_95"
      }
    }
  }
}

# ── Cloud SQL: CPU and connection saturation ─────────────────────────────────
resource "google_monitoring_alert_policy" "sql_cpu" {
  project               = var.gcp_project
  display_name          = "Odoo Cloud SQL CPU saturation"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Cloud SQL CPU > 80% over 10 minutes"
    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.gcp_project}:${google_sql_database_instance.shared_db.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "sql_connections" {
  project               = var.gcp_project
  display_name          = "Odoo Cloud SQL connection saturation"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Postgres backends > 80% of max_connections"
    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\" AND resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.gcp_project}:${google_sql_database_instance.shared_db.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = floor(tonumber(lookup(var.db_flags, "max_connections", "100")) * 0.8)
      duration        = "300s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}

# ── Redis memory pressure ────────────────────────────────────────────────────
resource "google_monitoring_alert_policy" "redis_memory" {
  project               = var.gcp_project
  display_name          = "Odoo Redis session store memory"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Redis memory usage ratio > 80%"
    condition_threshold {
      filter          = "metric.type=\"redis.googleapis.com/stats/memory/usage_ratio\" AND resource.type=\"redis_instance\" AND resource.labels.instance_id=\"projects/${var.gcp_project}/locations/${var.region}/instances/${google_redis_instance.session_cache.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
}

# ── Migration job failures ───────────────────────────────────────────────────
resource "google_monitoring_alert_policy" "job_failures" {
  project               = var.gcp_project
  display_name          = "Odoo Cloud Run Job execution failed"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Any Odoo job execution failed"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.type=\"cloud_run_job\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
}

# ── Cron failures (log-based metric on the Cron Runner) ──────────────────────
resource "google_logging_metric" "cron_failures" {
  project = var.gcp_project
  name    = "odoo-cron-failures"
  filter  = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"cron-runner-odoo\" AND severity>=ERROR AND textPayload:\"ir_cron\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "cron_failures" {
  project               = var.gcp_project
  display_name          = "Odoo scheduled job (cron) failures"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "Cron errors logged by the Cron Runner"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.cron_failures.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
}

# ── Entitlement violations (daily audit cron in addon_entitlement) ───────────
# A tenant database has a module installed that its plan does not include —
# a billing/contract event, not an outage: the module keeps working by design.
resource "google_logging_metric" "entitlement_violations" {
  project = var.gcp_project
  name    = "odoo-entitlement-violations"
  # Match both plain-text stderr (textPayload, Odoo's default) and structured
  # logs (jsonPayload.message) so the alert survives a logging-format change.
  filter  = "resource.type=\"cloud_run_revision\" AND (textPayload:\"ENTITLEMENT_VIOLATION\" OR jsonPayload.message:\"ENTITLEMENT_VIOLATION\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "entitlement_violations" {
  project               = var.gcp_project
  display_name          = "Odoo addon entitlement violation (unpaid module installed)"
  combiner              = "OR"
  notification_channels = local.alert_channels

  conditions {
    display_name = "ENTITLEMENT_VIOLATION logged by the entitlement audit"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.entitlement_violations.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
}
