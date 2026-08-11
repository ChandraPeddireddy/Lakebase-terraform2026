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
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "")        ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

# --- Preflight, auth, and connection (see common.sh) -------------------------
preflight_and_auth
resolve_connection

# --- Read the grant plan from terraform output -------------------------------
# db_identity_grants is a JSON list of {role, access} (see ../outputs.tf).
GRANTS_JSON="$(terraform -chdir="$TF_DIR" output -json db_identity_grants 2>/dev/null || echo '[]')"
COUNT="$(python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' <<<"$GRANTS_JSON")"
(( COUNT )) || { log "No identity grants in terraform output — nothing to do."; exit 0; }

log "Target: ${PG_USER}@${PG_HOST}/${PG_DATABASE}  (${COUNT} identity grant(s))"

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

# Build the full statement batch first, then apply it in a SINGLE transaction so
# grants are all-or-nothing: if any one fails (e.g. a role that terraform apply
# hasn't created yet) the whole batch rolls back, leaving the DB unchanged rather
# than a partial, iteration-order-dependent set of grants. This also uses one
# connection instead of one psql round trip per identity.
SQL=""
applied=0
while IFS=$'\t' read -r role access; do
  # apply_one returns non-zero on an unknown access value; under `set -e` that
  # aborts here before anything is applied.
  SQL+="$(apply_one "$role" "$access")"$'\n'
  if (( DRY_RUN )); then
    echo "  [plan] $role ($access): $(apply_one "$role" "$access")"
  fi
  applied=$((applied + 1))
done < <(python3 -c '
import sys, json
for e in json.load(sys.stdin):
    print("%s\t%s" % (e["role"], e["access"]))
' <<<"$GRANTS_JSON")

if (( DRY_RUN )); then
  log "Dry run — ${applied} identity grant(s) would be applied in one transaction; no changes made."
else
  # ON_ERROR_STOP=1 + BEGIN/COMMIT: any error aborts the transaction and psql
  # exits non-zero, so `set -e` skips the success message below.
  run_sql -f - <<<"BEGIN;
${SQL}COMMIT;"
  log "Done — applied grants for ${applied} identit$( ((applied == 1)) && echo y || echo ies) in one transaction."
fi
