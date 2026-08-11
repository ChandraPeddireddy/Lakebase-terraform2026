# -----------------------------------------------------------------------------
# Databricks secret scope for Lakebase role passwords
# -----------------------------------------------------------------------------
# Terraform owns the *infrastructure* — the secret scope and its ACLs — which
# contain no secret material and are safe to keep in state.
#
# The secret *value* (the role password) is intentionally NOT managed here by
# default: a value in a `databricks_secret` resource is stored in plaintext in
# Terraform state. Instead, write it at runtime with sql/rotate_password.sh:
#
#   ./rotate_password.sh --role app_service \
#       --secret-scope <this scope> --secret-key app_service_pw
#
# For teams that want a fully-declarative value in state anyway (dev/CI only),
# set manage_secret_value = true and pass secret_value — see variables.tf for
# the tradeoff.
# -----------------------------------------------------------------------------

resource "databricks_secret_scope" "lakebase" {
  count = var.create_secret_scope ? 1 : 0
  name  = var.secret_scope_name

  # DATABRICKS-backed scope (default). No keyvault backend needed.
}

# Optional read ACL so an app/service principal can read the password secret.
resource "databricks_secret_acl" "reader" {
  count      = var.create_secret_scope && var.secret_reader_principal != "" ? 1 : 0
  scope      = databricks_secret_scope.lakebase[0].name
  principal  = var.secret_reader_principal
  permission = "READ"
}

# Optional, opt-in: manage the password value declaratively.
# WARNING: this puts the plaintext password in Terraform state. Only use for
# throwaway dev/CI. Prefer rotate_password.sh for anything real.
resource "databricks_secret" "role_password" {
  count        = var.create_secret_scope && var.manage_secret_value ? 1 : 0
  scope        = databricks_secret_scope.lakebase[0].name
  key          = var.secret_key
  string_value = var.secret_value
}
