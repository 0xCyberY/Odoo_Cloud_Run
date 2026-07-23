# terraform/modules/cloud-run-odoo/variables.tf

variable "gcp_project" {
  type        = string
  description = "The GCP project ID"
}

variable "region" {
  type        = string
  description = "The GCP region"
}

variable "client_slug" {
  type        = string
  description = "Unique service slug (e.g. pooled, websocket, cron-runner)"
}

variable "image_url" {
  type        = string
  description = "The container image URL in Artifact Registry"
}

variable "vpc_id" {
  type        = string
  description = "The ID of the VPC Network"
}

variable "subnet_id" {
  type        = string
  description = "The ID of the VPC Subnetwork for Egress"
}

variable "odoo_mode" {
  type        = string
  description = "Service role: web | cron | websocket (see entrypoint.sh)"
  default     = "web"

  validation {
    condition     = contains(["web", "cron", "websocket"], var.odoo_mode)
    error_message = "odoo_mode must be one of: web, cron, websocket."
  }
}

variable "odoo_databases" {
  type        = string
  description = "Comma-separated tenant DB list (required for odoo_mode=cron)"
  default     = ""
}

variable "db_host" {
  type        = string
  description = "Database host address (Cloud SQL private IP)"
}

variable "db_port" {
  type        = string
  description = "Database port"
  default     = "5432"
}

variable "db_user" {
  type        = string
  description = "Platform database username (pgbouncer frontend / fallback)"
}

variable "db_name" {
  type        = string
  description = "Default database name"
}

variable "db_password_secret" {
  type        = string
  description = "Secret ID containing the platform database password"
}

variable "admin_password_secret" {
  type        = string
  description = "Secret ID containing Odoo admin password"
}

variable "redis_host" {
  type        = string
  description = "Redis cache host address"
}

variable "redis_port" {
  type        = number
  description = "Redis cache port"
  default     = 6379
}

variable "redis_password_secret" {
  type        = string
  description = "Secret ID containing the Redis password (optional)"
  default     = ""
}

variable "enable_pgbouncer" {
  type        = bool
  description = "Run the pgbouncer connection-pooling sidecar"
  default     = false
}

variable "pgbouncer_image" {
  type        = string
  description = "pgbouncer sidecar image URL in Artifact Registry"
  default     = ""
}

variable "tenant_db_map" {
  type = map(object({
    db     = string # tenant database name
    user   = string # tenant least-privilege PostgreSQL user
    secret = string # Secret Manager secret id holding that user's password
  }))
  description = "Tenant slug → DB/user/secret map for pgbouncer per-tenant credential routing"
  default     = {}
}

variable "pgbouncer_default_pool_size" {
  type        = number
  description = "pgbouncer default_pool_size (server connections per db/user pair)"
  default     = 5
}

variable "pgbouncer_max_db_connections" {
  type        = number
  description = "pgbouncer max_db_connections (hard cap per database)"
  default     = 10
}

variable "pgbouncer_cpu" {
  type        = string
  description = "CPU limit for the pgbouncer sidecar"
  default     = "0.5"
}

variable "pgbouncer_memory" {
  type        = string
  description = "Memory limit for the pgbouncer sidecar"
  default     = "256Mi"
}

variable "min_instances" {
  type        = number
  description = "Minimum instances to scale down to"
  default     = 0
}

variable "max_instances" {
  type        = number
  description = "Maximum instances to scale up to"
  default     = 5
}

variable "cpu" {
  type        = string
  description = "CPU limit (e.g. 1, 2)"
  default     = "2"
}

variable "memory" {
  type        = string
  description = "Memory limit (e.g. 2Gi, 4Gi)"
  default     = "4Gi"
}

variable "timeout" {
  type        = string
  description = "Max request duration (aligned with ALB backend timeout)"
  default     = "3600s"
}

variable "health_probe_type" {
  type        = string
  description = "Startup/liveness probe style: http (/web/health) or tcp (port only — used by the gevent websocket service)"
  default     = "http"

  validation {
    condition     = contains(["http", "tcp"], var.health_probe_type)
    error_message = "health_probe_type must be http or tcp."
  }
}

variable "concurrency" {
  type        = number
  description = "Max concurrent requests per instance (Cloud Run default is 80 — too high for memory-bound threaded Odoo; raise for the websocket service where connections are long-lived and idle)"
  default     = 40
}

variable "ingress" {
  type        = string
  description = "Ingress policy for the service"
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
}

variable "session_affinity" {
  type        = bool
  description = "Enable sticky routing"
  default     = true
}

variable "create_neg" {
  type        = bool
  description = "Create a Serverless NEG for ALB integration (false for internal services)"
  default     = true
}

variable "public_access" {
  type        = bool
  description = "Allow unauthenticated invocation (required behind the ALB)"
  default     = true
}

variable "env_extra" {
  type        = map(string)
  description = "Additional plain environment variables for the Odoo container"
  default     = {}
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the service (cost attribution / observability)"
  default     = {}
}
