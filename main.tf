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

# Phase 1: Production endpoint — HA + autoscaling ------------------------------
# The project auto-provisions a `production` branch with a read-write endpoint
# named `primary`. The NBA workload runs here, so we adopt it (replace_existing)
# and declare HA + autoscaling in code instead of clicking in the UI.
# Scale-to-zero is intentionally OFF: it is incompatible with HA and `production`
# is always-on. HA readable secondaries also serve reads via the `-ro` string.
resource "databricks_postgres_endpoint" "prod_primary" {
  count            = var.enable_prod_endpoint ? 1 : 0
  endpoint_id      = "primary"
  parent           = "${databricks_postgres_project.app.name}/branches/production"
  replace_existing = true

  spec = {
    endpoint_type            = "ENDPOINT_TYPE_READ_WRITE"
    autoscaling_limit_min_cu = var.prod_min_cu
    autoscaling_limit_max_cu = var.prod_max_cu
    no_suspension            = true

    # HA group: min/max are the TOTAL compute count (1 primary + N secondaries),
    # per Databricks HA docs — so total = 1 + prod_ha_secondaries, and min=max
    # fixes the group size. min=max=1 would be primary-only (no HA), which is why
    # we add 1. For read availability across a failover, docs recommend >= 2
    # secondaries (total >= 3); a lone secondary's -ro reads pause until replaced.
    group = {
      enable_readable_secondaries = var.prod_enable_readable_secondaries
      min                         = 1 + var.prod_ha_secondaries
      max                         = 1 + var.prod_ha_secondaries
    }
  }

  depends_on = [databricks_postgres_project.app]
}

# Phase 2: Register the Lakebase database as a Unity Catalog catalog ------------
# One-time per project. Prerequisite for creating synced tables (which are
# themselves driven via the CLI — see scripts/sync_member_features.sh — because
# the Autoscaling synced-table API has no Terraform resource yet).
resource "databricks_postgres_catalog" "lakebase" {
  count      = var.enable_uc_catalog ? 1 : 0
  catalog_id = var.uc_catalog_id
  spec = {
    branch                     = "${databricks_postgres_project.app.name}/branches/production"
    postgres_database          = var.uc_catalog_postgres_database
    create_database_if_missing = false
  }
  depends_on = [databricks_postgres_project.app]
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
