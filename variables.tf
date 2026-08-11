# -----------------------------------------------------------------------------
# Input variables
# -----------------------------------------------------------------------------
# All values are parameterized so other teams can reuse this module by copying
# terraform.tfvars.example -> terraform.tfvars and overriding as needed.
# Defaults reproduce the original quickstart, so `terraform apply` with no
# tfvars behaves exactly like before.

# --- Project ----------------------------------------------------------------
variable "project_id" {
  description = "Lakebase project id (immutable; changing it recreates the project)."
  type        = string
  default     = "lakebase-project-id-dev"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 3-63 chars, lowercase alphanumeric or hyphens, and not start/end with a hyphen."
  }
}

variable "project_display_name" {
  description = "Human-friendly name shown in the Databricks UI."
  type        = string
  default     = "lakebase-project-id-dev-name"
}

variable "pg_version" {
  description = "PostgreSQL major version for the project."
  type        = number
  default     = 17

  validation {
    condition     = contains([14, 15, 16, 17], var.pg_version)
    error_message = "pg_version must be one of: 14, 15, 16, 17."
  }
}

variable "enable_pg_native_login" {
  description = "Enable native Postgres username/password login on the project."
  type        = bool
  default     = false
}

variable "purge_on_delete" {
  description = "If true, hard-delete the project on destroy instead of the default 7-day soft-delete retention."
  type        = bool
  default     = false
}

# Note: to guard a production project against deletion, uncomment the
# lifecycle { prevent_destroy = true } block in main.tf. Terraform does not
# allow that flag to be driven by a variable, so it is not parameterized here.

# --- Dev branch + endpoint --------------------------------------------------
variable "create_dev_branch" {
  description = "Whether to create the development branch and its endpoint. Set false to manage the project only."
  type        = bool
  default     = true
}

variable "dev_branch_id" {
  description = "Branch id for the development branch."
  type        = string
  default     = "dev"
}

variable "dev_branch_no_expiry" {
  description = "If true, the dev branch never auto-expires."
  type        = bool
  default     = true
}

variable "dev_endpoint_id" {
  description = "Endpoint id to adopt on the dev branch (the implicit one is named 'primary')."
  type        = string
  default     = "primary"
}

variable "dev_endpoint_type" {
  description = "Endpoint type for the dev branch endpoint."
  type        = string
  default     = "ENDPOINT_TYPE_READ_WRITE"

  validation {
    condition     = contains(["ENDPOINT_TYPE_READ_WRITE", "ENDPOINT_TYPE_READ_ONLY"], var.dev_endpoint_type)
    error_message = "dev_endpoint_type must be ENDPOINT_TYPE_READ_WRITE or ENDPOINT_TYPE_READ_ONLY."
  }
}

# --- Secret scope (for role passwords) --------------------------------------
variable "create_secret_scope" {
  description = "Whether to create a Databricks secret scope for Lakebase role passwords."
  type        = bool
  default     = true
}

variable "secret_scope_name" {
  description = "Name of the Databricks secret scope that holds Lakebase role passwords."
  type        = string
  default     = "lakebase"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,128}$", var.secret_scope_name))
    error_message = "secret_scope_name must be 1-128 chars: letters, digits, underscore, dash, or dot."
  }
}

variable "secret_key" {
  description = "Key within the scope under which the role password is stored."
  type        = string
  default     = "app_service_pw"
}

variable "secret_reader_principal" {
  description = "Optional principal (user email, group name, or SP application id) to grant READ on the scope. Empty = no ACL created (creator keeps MANAGE)."
  type        = string
  default     = ""
}

# The password value is normally written at runtime by sql/rotate_password.sh so
# it never lands in Terraform state. The two variables below let you opt into
# managing it declaratively instead — at the cost of storing the plaintext in
# state. Only do this for throwaway dev/CI.
variable "manage_secret_value" {
  description = "If true, Terraform manages the password value in the scope (plaintext ends up in state). Prefer rotate_password.sh; leave false for real environments."
  type        = bool
  default     = false
}

variable "secret_value" {
  description = "Password value, used only when manage_secret_value = true. Pass via TF_VAR_secret_value, never commit it."
  type        = string
  default     = ""
  sensitive   = true
}
