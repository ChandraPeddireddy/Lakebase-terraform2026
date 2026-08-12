#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Phase 2 — Delta -> Lakebase synced table (member feature set)
#
# WHY THIS IS A SCRIPT, NOT TERRAFORM:
# Lakebase Autoscaling synced tables have NO Terraform resource yet. The only
# provider resource, `databricks_database_synced_database_table`, maps to the
# *Provisioned* API and can misfire against an Autoscaling project. So we drive
# the sync via the CLI and keep it version-controlled here instead.
#
# PREREQUISITES:
#   1. Phase 1 applied (project + production endpoint).
#   2. UC catalog registered: set enable_uc_catalog=true and `terraform apply`
#      (resource databricks_postgres_catalog.lakebase), OR run
#      `databricks postgres create-catalog ...`.
#   3. A GOLD member-feature Delta table exists in UC (sync gold, not raw).
#   4. For CONTINUOUS/TRIGGERED modes, enable CDF on the source:
#        ALTER TABLE <SOURCE> SET TBLPROPERTIES (delta.enableChangeDataFeed = true)
# -----------------------------------------------------------------------------
set -euo pipefail

# --- Configure these for your environment ------------------------------------
PROFILE="${DATABRICKS_PROFILE:-lakebase-sandbox}"
PROJECT_ID="${PROJECT_ID:?set PROJECT_ID (e.g. nba or sandbox-lakebase)}"
LAKEBASE_CATALOG="${LAKEBASE_CATALOG:?set LAKEBASE_CATALOG (the UC catalog registered for Lakebase)}"
SOURCE_TABLE="${SOURCE_TABLE:?set SOURCE_TABLE (e.g. analytics.gold.nba_member_features)}"
STORAGE_CATALOG="${STORAGE_CATALOG:?set STORAGE_CATALOG (a REGULAR UC catalog for DLT metadata, NOT the Lakebase catalog)}"
# Must match var.uc_catalog_postgres_database used to register the UC catalog.
POSTGRES_DATABASE="${POSTGRES_DATABASE:-databricks_postgres}"
TARGET_TABLE="${TARGET_TABLE:-${LAKEBASE_CATALOG}.public.nba_member_features}"
# PK_COLUMNS must be a non-empty JSON array of quoted names, e.g. ["member_id"]
# or ["a","b"]. The regex rejects [], bare [member_id], and other non-JSON.
PK_COLUMNS="${PK_COLUMNS:-[\"member_id\"]}"
if [[ ! "${PK_COLUMNS}" =~ ^\[\"[^\"]+\"(,\"[^\"]+\")*\]$ ]]; then
  echo "ERROR: PK_COLUMNS must be a non-empty JSON array of quoted names, e.g. '[\"member_id\"]' (got: ${PK_COLUMNS})" >&2
  exit 1
fi
SCHEDULING_POLICY="${SCHEDULING_POLICY:-CONTINUOUS}"   # CONTINUOUS | TRIGGERED | SNAPSHOT

echo "Creating synced table ${TARGET_TABLE} (${SCHEDULING_POLICY}) from ${SOURCE_TABLE} ..."

databricks postgres create-synced-table "${TARGET_TABLE}" \
  --json "{
    \"spec\": {
      \"source_table_full_name\": \"${SOURCE_TABLE}\",
      \"primary_key_columns\": ${PK_COLUMNS},
      \"scheduling_policy\": \"${SCHEDULING_POLICY}\",
      \"branch\": \"projects/${PROJECT_ID}/branches/production\",
      \"postgres_database\": \"${POSTGRES_DATABASE}\",
      \"create_database_objects_if_missing\": true,
      \"new_pipeline_spec\": {
        \"storage_catalog\": \"${STORAGE_CATALOG}\",
        \"storage_schema\": \"default\"
      }
    }
  }" \
  --profile "${PROFILE}"

echo "Sync created. Check status with:"
echo "  databricks postgres get-synced-table \"synced_tables/${TARGET_TABLE}\" --profile ${PROFILE}"

# Notes:
#  - Continuous ~150 rows/sec/CU; each synced table uses up to 16 connections.
#  - After ONLINE, create Postgres indexes for the app's query patterns.
#  - Sanitize null bytes (0x00) in STRING/ARRAY/MAP/STRUCT source columns.
