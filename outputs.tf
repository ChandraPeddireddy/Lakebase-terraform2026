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
