# -----------------------------------------------------------------------------
# Lakebase (OLTP) Terraform quickstart
# Follows: https://learn.microsoft.com/en-us/azure/databricks/oltp/projects/automate-with-terraform
# Order of operations: Project -> Branch -> Endpoint
#
# All tunable values live in variables.tf. Copy terraform.tfvars.example to
# terraform.tfvars to customize for your team/environment.
# -----------------------------------------------------------------------------

# Step 2: Create a project ----------------------------------------------------
# A project is the top-level resource that contains branches, endpoints,
# databases, and roles. Creating it auto-provisions a `production` branch with
# a read-write endpoint named `primary`.
resource "databricks_postgres_project" "app" {
  project_id      = var.project_id
  purge_on_delete = var.purge_on_delete
  spec = {
    pg_version             = var.pg_version
    display_name           = var.project_display_name
    enable_pg_native_login = var.enable_pg_native_login
  }

  # To guard a production project against accidental deletion, uncomment the
  # block below. Terraform requires a literal here, so it can't be a variable.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Step 3: Get a project (data source) -----------------------------------------
data "databricks_postgres_project" "this" {
  name = databricks_postgres_project.app.name
}

# Step 4: Create a development branch -----------------------------------------
# Each new branch also gets its own implicit `primary` read-write endpoint.
resource "databricks_postgres_branch" "dev" {
  count     = var.create_dev_branch ? 1 : 0
  branch_id = var.dev_branch_id
  parent    = databricks_postgres_project.app.name
  spec = {
    no_expiry = var.dev_branch_no_expiry
  }
}

# Step 5: Take ownership of the dev branch's primary endpoint ------------------
# `replace_existing = true` tells Terraform to adopt the implicitly-created
# `primary` endpoint instead of trying to create a new one.
resource "databricks_postgres_endpoint" "dev_primary" {
  count       = var.create_dev_branch ? 1 : 0
  endpoint_id = var.dev_endpoint_id
  parent      = databricks_postgres_branch.dev[0].name
  spec = {
    endpoint_type = var.dev_endpoint_type
  }
  replace_existing = true
}

# Step 6: List endpoints in the dev branch (data source) ----------------------
data "databricks_postgres_endpoints" "dev" {
  count  = var.create_dev_branch ? 1 : 0
  parent = databricks_postgres_branch.dev[0].name
}

# Step 7: List all branches in the project (data source) ----------------------
data "databricks_postgres_branches" "all" {
  parent = databricks_postgres_project.app.name
}
