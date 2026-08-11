# -----------------------------------------------------------------------------
# Identity-linked Postgres roles (users / service principals)
# -----------------------------------------------------------------------------
# Layer 1 of access management (see variables.tf `db_identity_roles`):
# create one Postgres role per Databricks identity, bound to OAuth login. This
# is the part that MUST go through the Databricks API — a plain SQL CREATE ROLE
# cannot establish the Databricks-identity/OAuth linkage, which is why a human
# hitting the SQL Editor without one gets "permission denied / ask the owner to
# create a PostgreSQL role for your Databricks identity".
#
# Layer 2 — granting the app_ro / app_rw GROUP membership that actually confers
# table access — is applied as SQL by sql/grant_access.sh, because the role
# API's membership_roles only accepts predefined roles, not our app_* groups.
#
# for_each (not count) keys each role by its stable slug, so adding or removing
# an identity never reshuffles the others in state.
resource "databricks_postgres_role" "identity" {
  for_each = var.create_dev_branch ? var.db_identity_roles : {}

  role_id = each.key
  parent  = databricks_postgres_branch.dev[0].name

  spec = {
    identity_type = each.value.identity_type
    postgres_role = each.value.principal
    auth_method   = "LAKEBASE_OAUTH_V1"
  }

  # Adopt a role that already exists on the branch (e.g. one created by hand or
  # auto-provisioned) instead of failing with "already exists".
  replace_existing = true
}
