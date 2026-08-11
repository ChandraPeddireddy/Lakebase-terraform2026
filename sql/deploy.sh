#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Lakebase SQL migration runner
# -----------------------------------------------------------------------------
# Applies pending, sequentially-numbered migrations from ./migrations in order.
# State is tracked in app.schema_migrations *inside the database*, so the runner
# is stateless and safe to run repeatedly (idempotent): already-applied
# migrations are skipped, and a checksum guard rejects edits to applied files.
#
# Connection details come from `terraform output`, and the Postgres password is
# a short-lived Databricks OAuth token minted per run.
#
# Usage:
#   source ../env.sh          # DATABRICKS_HOST + DATABRICKS_TOKEN
#   ./deploy.sh               # apply all pending migrations
#   ./deploy.sh --status      # show applied vs pending, apply nothing
#   ./deploy.sh --dry-run     # list what would be applied, apply nothing
#
# Env overrides (rarely needed — defaults are derived from Terraform):
#   PG_DATABASE   Postgres database name        (default: databricks_postgres)
#   TF_DIR        Terraform dir for outputs      (default: parent of this script)
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MODE="apply"
case "${1:-}" in
  --status)  MODE="status" ;;
  --dry-run) MODE="dry-run" ;;
  "")        MODE="apply" ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

# --- Preflight, auth, and connection (see common.sh) -------------------------
preflight_and_auth
resolve_connection
log "Target: ${PG_USER}@${PG_HOST}/${PG_DATABASE}"

# --- Bootstrap the migrations ledger -----------------------------------------
run_sql -c "
  CREATE SCHEMA IF NOT EXISTS app;
  CREATE TABLE IF NOT EXISTS app.schema_migrations (
    version     TEXT PRIMARY KEY,
    filename    TEXT        NOT NULL,
    checksum    TEXT        NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );" >/dev/null

# --- Walk migrations ---------------------------------------------------------
shopt -s nullglob
FILES=("$MIGRATIONS_DIR"/[0-9]*.sql)
(( ${#FILES[@]} )) || { err "no migrations found in $MIGRATIONS_DIR"; exit 1; }
IFS=$'\n' FILES=($(sort <<<"${FILES[*]}")); unset IFS

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }

applied=0 pending=0
for file in "${FILES[@]}"; do
  base="$(basename "$file")"
  version="${base%%_*}"
  sum="$(checksum "$file")"

  prior="$(run_sql -c \
    "SELECT checksum FROM app.schema_migrations WHERE version = '${version}';")"

  if [[ -n "$prior" ]]; then
    if [[ "$prior" != "$sum" ]]; then
      err "checksum mismatch for ${base} — an applied migration was edited."
      err "Migrations are immutable; add a new migration instead of changing this one."
      exit 1
    fi
    applied=$((applied+1))
    [[ "$MODE" == "status" ]] && echo "  [applied] $base"
    continue
  fi

  pending=$((pending+1))
  case "$MODE" in
    status|dry-run) echo "  [pending] $base"; continue ;;
  esac

  log "Applying $base"
  # Each migration + its ledger insert run in ONE transaction: if the SQL fails,
  # nothing is recorded and the file re-runs cleanly next time.
  run_sql --single-transaction \
      -f "$file" \
      -c "INSERT INTO app.schema_migrations (version, filename, checksum)
          VALUES ('${version}', '${base}', '${sum}');" >/dev/null
done

case "$MODE" in
  status)  log "Applied: $applied  Pending: $pending" ;;
  dry-run) log "Dry run — $pending migration(s) would be applied, $applied already applied" ;;
  apply)
    if (( pending )); then log "Done — applied $pending migration(s)."
    else log "Up to date — nothing to apply ($applied already applied)."; fi ;;
esac
