#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Grant app_ro / app_rw group membership to identity-linked roles (layer 2)
# -----------------------------------------------------------------------------
# Terraform (databricks_postgres_role, see ../roles.tf) creates each Databricks
# identity's Postgres role and OAuth login binding. That role can log in but has
# no access to the app schema until it is added to a GROUP role. This script
# applies that GRANT, driven by the `db_identity_grants` terraform output:
#
#   read      -> GRANT app_ro   (SELECT on app.*)
#   readwrite -> GRANT app_rw   (SELECT/INSERT/UPDATE/DELETE on app.*)
#   none      -> revoke both (login only, no app access)
#
# It is idempotent (GRANT/REVOKE of an already-(non)member is a no-op) and safe
# to re-run after every `terraform apply` that changes db_identity_roles.
#
# Usage:
#   source ../env.sh
#   ./grant_access.sh              # apply grants from terraform output
#   ./grant_access.sh --dry-run    # print the GRANT/REVOKE plan, change nothing
#
# Env overrides (same as deploy.sh):
#   PG_DATABASE   default databricks_postgres
#   TF_DIR        default parent of sql/
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$(dirname "$SCRIPT_DIR")}"
PG_DATABASE="${PG_DATABASE:-databricks_postgres}"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "")        ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

log() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[0;31mError:\033[0m %s\n' "$*" >&2; }

command -v psql >/dev/null      || { err "psql not found (brew install libpq)"; exit 1; }
command -v terraform >/dev/null || { err "terraform not found"; exit 1; }
command -v databricks >/dev/null|| { err "databricks CLI not found"; exit 1; }
: "${DATABRICKS_HOST:?set DATABRICKS_HOST (source ../env.sh)}"

# Auth resolution (same policy as deploy.sh): force PAT auth only when a PAT is
# present, otherwise leave DATABRICKS_CONFIG_PROFILE-based OAuth resolution intact.
if [[ -n "${DATABRICKS_TOKEN:-}" ]]; then
  export DATABRICKS_CONFIG_PROFILE=""
  export DATABRICKS_AUTH_TYPE="pat"
fi

# --- Resolve connection (typed commands, same as deploy.sh) ------------------
ENDPOINT_NAME="$(terraform -chdir="$TF_DIR" output -raw dev_endpoint_name 2>/dev/null || true)"
[[ -n "$ENDPOINT_NAME" && "$ENDPOINT_NAME" != "null" ]] \
  || { err "no dev_endpoint_name output — run 'terraform apply' first"; exit 1; }

PG_HOST="$(databricks postgres get-endpoint "${ENDPOINT_NAME}" -o json \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["hosts"]["host"])')"
PG_USER="$(databricks current-user me \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["userName"])')"
PGPASSWORD="$(databricks postgres generate-database-credential "${ENDPOINT_NAME}" -o json \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
export PGPASSWORD PGSSLMODE="require"

# --- Read the grant plan from terraform output -------------------------------
GRANTS_JSON="$(terraform -chdir="$TF_DIR" output -json db_identity_grants 2>/dev/null || echo '{}')"
COUNT="$(python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' <<<"$GRANTS_JSON")"
(( COUNT )) || { log "No identity grants in terraform output — nothing to do."; exit 0; }

log "Target: ${PG_USER}@${PG_HOST}/${PG_DATABASE}  (${COUNT} identity grant(s))"

run_sql() { psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d "$PG_DATABASE" \
              -v ON_ERROR_STOP=1 -qAt "$@"; }

# Build the GRANT/REVOKE statements. Role names come from a trusted source
# (terraform output of our own tfvars) and are quoted as identifiers.
apply_one() {
  local role="$1" access="$2"
  case "$access" in
    read)      echo "GRANT app_ro TO \"$role\"; REVOKE app_rw FROM \"$role\";" ;;
    readwrite) echo "GRANT app_rw TO \"$role\";" ;;   # app_rw already includes app_ro
    none)      echo "REVOKE app_ro FROM \"$role\"; REVOKE app_rw FROM \"$role\";" ;;
    *)         err "unknown access '$access' for role '$role'"; return 1 ;;
  esac
}

# Iterate the map: {postgres_role: access}
while IFS=$'\t' read -r role access; do
  stmt="$(apply_one "$role" "$access")"
  if (( DRY_RUN )); then
    echo "  [plan] $role ($access): $stmt"
  else
    log "Granting '$access' to $role"
    run_sql -c "$stmt" >/dev/null
  fi
done < <(python3 -c '
import sys, json
for role, access in json.load(sys.stdin).items():
    print("%s\t%s" % (role, access))
' <<<"$GRANTS_JSON")

if (( DRY_RUN )); then
  log "Dry run — no changes applied."
else
  log "Done — applied ${COUNT} grant(s)."
fi
