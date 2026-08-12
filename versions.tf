terraform {
  # >= 1.9: variable validation blocks reference other variables (prod_max_cu
  # checks prod_min_cu). The config also uses optional() object attributes (>= 1.3).
  required_version = ">= 1.9.0"

  required_providers {
    databricks = {
      source = "databricks/databricks"
      # Pinned: postgres HA (`group` block) and postgres_catalog require a recent
      # provider. 1.126.0 verified to expose both. (Phase 3 will add
      # databricks_model_serving, also present from this version.)
      version = ">= 1.126.0, < 2.0"
    }
  }
}

provider "databricks" {
  # Automatically uses DATABRICKS_HOST, DATABRICKS_CLIENT_ID,
  # and DATABRICKS_CLIENT_SECRET from environment variables.
  # See env.sh for the values to export before running terraform.
}
