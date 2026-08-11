# Outputs mirror the guide's steps 3-7 so `terraform output` shows useful values.
# Dev-branch outputs return null when var.create_dev_branch = false.

# Step 3: project details
output "project_name" {
  value = data.databricks_postgres_project.this.name
}

output "project_pg_version" {
  value = try(data.databricks_postgres_project.this.status.pg_version, null)
}

output "project_display_name" {
  value = try(data.databricks_postgres_project.this.status.display_name, null)
}

# Step 4: dev branch
output "dev_branch_name" {
  value = one(databricks_postgres_branch.dev[*].name)
}

# Step 5: dev endpoint
output "dev_endpoint_name" {
  value = one(databricks_postgres_endpoint.dev_primary[*].name)
}

# Step 6: list endpoints in dev branch
output "dev_endpoint_names" {
  value = var.create_dev_branch ? [for e in data.databricks_postgres_endpoints.dev[0].endpoints : e.name] : []
}

output "dev_endpoint_types" {
  value = var.create_dev_branch ? [
    for e in data.databricks_postgres_endpoints.dev[0].endpoints :
    try(e.status.endpoint_type, null)
  ] : []
}

# Step 7: list all branches (production + dev)
output "branch_names" {
  value = [for b in data.databricks_postgres_branches.all.branches : b.name]
}

# Secret scope for role passwords (null when create_secret_scope = false)
output "secret_scope_name" {
  description = "Databricks secret scope holding Lakebase role passwords."
  value       = one(databricks_secret_scope.lakebase[*].name)
}

output "secret_key" {
  description = "Key within the scope where the role password is stored. Populate it with sql/rotate_password.sh --secret-scope <scope> --secret-key <key>."
  value       = var.create_secret_scope ? var.secret_key : null
}

# Identity-linked roles created by Terraform (layer 1). sql/grant_access.sh reads
# this to apply the app_ro/app_rw GROUP grants (layer 2) that confer table access.
# Emits one entry per role: the Postgres role name + desired access level.
output "db_identity_grants" {
  description = "Map of provisioned postgres_role -> access level (read|readwrite|none) for sql/grant_access.sh to enforce group membership."
  # Iterate the resource map (not var.db_identity_roles) so this stays correct
  # when create_dev_branch = false collapses the roles to an empty set — indexing
  # the var into a non-existent resource instance would error at plan time.
  value = {
    for k, r in databricks_postgres_role.identity :
    var.db_identity_roles[k].principal => coalesce(var.db_identity_roles[k].access, "read")
  }
}
