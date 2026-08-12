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

# Phase 1: production endpoint (HA + autoscaling)
output "prod_endpoint_name" {
  value = one(databricks_postgres_endpoint.prod_primary[*].name)
}

output "prod_endpoint_host" {
  description = "Primary (read-write) connection host."
  value       = try(one(databricks_postgres_endpoint.prod_primary[*].status.hosts.host), null)
}

output "prod_endpoint_read_only_host" {
  description = "Read-only host routing to readable secondaries (populated when HA readable secondaries are enabled)."
  value       = try(one(databricks_postgres_endpoint.prod_primary[*].status.hosts.read_only_host), null)
}

# Phase 2: registered UC catalog for the Lakebase database
output "lakebase_uc_catalog_name" {
  value = one(databricks_postgres_catalog.lakebase[*].name)
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
# Emits a LIST of {role, access}:
#   - A list (not a map) tolerates two slugs pointing at the same principal; a
#     map keyed by principal would fail plan with "duplicate object key". Applying
#     a grant to the same role twice is idempotent, so duplicates are harmless.
#   - `role` is read from the resource's actual spec.postgres_role, not re-derived
#     from the var, so the GRANT always targets the role Terraform really created
#     (the coupling is explicit and can't silently drift).
# Iterating the resource map (not var.db_identity_roles) also keeps this valid
# when create_dev_branch = false collapses the roles to an empty set.
output "db_identity_grants" {
  description = "List of {role, access} (access = read|readwrite|none) for sql/grant_access.sh to enforce group membership on each provisioned Postgres role."
  value = [
    for k, r in databricks_postgres_role.identity : {
      role   = r.spec.postgres_role
      access = coalesce(var.db_identity_roles[k].access, "read")
    }
  ]
}
