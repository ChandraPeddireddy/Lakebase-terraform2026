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
TF_DIR="${TF_DIR:-$(dirname "$SCRIPT_DIR")}"
PG_DATABASE="${PG_DATABASE:-databricks_postgres}"

MODE="apply"
case "${1:-}" in
  --status)  MODE="status" ;;
  --dry-run) MODE="dry-run" ;;
  "")        MODE="apply" ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31mError:\033[0m %s\n' "$*" >&2; }

# --- Preflight ---------------------------------------------------------------
command -v psql >/dev/null      || { err "psql not found (brew install libpq)"; exit 1; }
command -v terraform >/dev/null || { err "terraform not found"; exit 1; }
command -v databricks >/dev/null|| { err "databricks CLI not found"; exit 1; }
: "${DATABRICKS_HOST:?set DATABRICKS_HOST (source ../env.sh)}"

# Force the CLI onto env-var/PAT auth so it doesn't fall back to a stale OAuth
# cache (the classic "OAuth is not configured for this host" failure).
export DATABRICKS_CONFIG_PROFILE=""
[[ -n "${DATABRICKS_TOKEN:-}" ]] && export DATABRICKS_AUTH_TYPE="pat"

# --- Resolve connection details from Terraform -------------------------------
log "Reading endpoint from terraform output ($TF_DIR)"
ENDPOINT_NAME="$(terraform -chdir="$TF_DIR" output -raw dev_endpoint_name 2>/dev/null || true)"
[[ -n "$ENDPOINT_NAME" && "$ENDPOINT_NAME" != "null" ]] \
  || { err "no dev_endpoint_name output — run 'terraform apply' first"; exit 1; }

PG_HOST="$(databricks api get "/api/2.0/postgres/${ENDPOINT_NAME}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["hosts"]["host"])')"
PG_USER="$(databricks current-user me \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["userName"])')"

log "Minting short-lived Postgres credential"
PGPASSWORD="$(databricks api post /api/2.0/postgres/credentials \
  --json "{\"endpoint\":\"${ENDPOINT_NAME}\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
export PGPASSWORD PGSSLMODE="require"

log "Target: ${PG_USER}@${PG_HOST}/${PG_DATABASE}"

# psql wrapper: fail on the first SQL error, quiet, no pager.
run_sql() { psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d "$PG_DATABASE" \
              -v ON_ERROR_STOP=1 -qAt "$@"; }

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
