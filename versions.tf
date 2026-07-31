terraform {
  required_version = ">= 1.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

provider "databricks" {
  # Automatically uses DATABRICKS_HOST, DATABRICKS_CLIENT_ID,
  # and DATABRICKS_CLIENT_SECRET from environment variables.
  # See env.sh for the values to export before running terraform.
}
