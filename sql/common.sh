#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# common.sh — shared helpers for the sql/ scripts (LIBRARY: source, don't run)
# -----------------------------------------------------------------------------
# Sourced by deploy.sh, rotate_password.sh, and grant_access.sh so the auth
# resolution and Postgres connection logic live in ONE place. Provides:
#   - log / err                    coloured status + error printers
#   - TF_DIR / PG_DATABASE          defaults (overridable via the environment)
#   - preflight_and_auth            tool + DATABRICKS_HOST checks, auth precedence
#   - resolve_connection            sets ENDPOINT_NAME/PG_HOST/PG_USER, exports PGPASSWORD
#   - run_sql                       psql wrapper (fail-fast, quiet, no pager)
#
# The caller is expected to have run `set -euo pipefail`; the functions here
# `exit` on error, which terminates the sourcing script as intended.
# -----------------------------------------------------------------------------

# Guard: this is a library, not an entrypoint.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "common.sh is a library; source it from another script, don't run it." >&2
  exit 2
fi

# Defaults — derived from this file's location (sql/), overridable by the caller.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$(dirname "$_COMMON_DIR")}"
PG_DATABASE="${PG_DATABASE:-databricks_postgres}"

log() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[0;31mError:\033[0m %s\n' "$*" >&2; }

# preflight_and_auth — verify required tooling + DATABRICKS_HOST, then resolve
# auth precedence: PAT > OAuth M2M (client id/secret) > config profile.
# When an EXPLICIT credential is present, clear any lingering
# DATABRICKS_CONFIG_PROFILE so the credential — not a stale cached profile — is
# authoritative. The CLI otherwise gives DATABRICKS_CONFIG_PROFILE precedence
# over env-var creds, silently shadowing the SP (auth resolves via the profile,
# ignoring CLIENT_ID/SECRET) and can fail "invalid_grant: Refresh token is
# invalid" on a stale profile token. With no explicit credential, profile-based
# resolution is left intact so a workspace profile alone still works.
preflight_and_auth() {
  command -v psql >/dev/null       || { err "psql not found (brew install libpq)"; exit 1; }
  command -v terraform >/dev/null  || { err "terraform not found"; exit 1; }
  command -v databricks >/dev/null || { err "databricks CLI not found"; exit 1; }
  : "${DATABRICKS_HOST:?set DATABRICKS_HOST (source ../env.sh)}"

  if [[ -n "${DATABRICKS_TOKEN:-}" ]]; then
    export DATABRICKS_CONFIG_PROFILE="" DATABRICKS_AUTH_TYPE="pat"
  elif [[ -n "${DATABRICKS_CLIENT_ID:-}" && -n "${DATABRICKS_CLIENT_SECRET:-}" ]]; then
    export DATABRICKS_CONFIG_PROFILE="" DATABRICKS_AUTH_TYPE="oauth-m2m"
  fi
}

# resolve_connection — read the dev endpoint from terraform output and resolve
# Postgres connection details via the TYPED `databricks postgres` subcommands
# (not the raw `databricks api .../postgres/...` passthrough, which resolves auth
# differently and can latch onto a stale cached U2M token). Sets ENDPOINT_NAME,
# PG_HOST, PG_USER and exports PGPASSWORD (a short-lived OAuth token) + PGSSLMODE.
resolve_connection() {
  log "Reading endpoint from terraform output ($TF_DIR)"
  ENDPOINT_NAME="$(terraform -chdir="$TF_DIR" output -raw dev_endpoint_name 2>/dev/null || true)"
  [[ -n "$ENDPOINT_NAME" && "$ENDPOINT_NAME" != "null" ]] \
    || { err "no dev_endpoint_name output — run 'terraform apply' first"; exit 1; }

  PG_HOST="$(databricks postgres get-endpoint "${ENDPOINT_NAME}" -o json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["hosts"]["host"])')"
  PG_USER="$(databricks current-user me \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["userName"])')"

  log "Minting short-lived Postgres credential"
  PGPASSWORD="$(databricks postgres generate-database-credential "${ENDPOINT_NAME}" -o json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
  export PGPASSWORD PGSSLMODE="require"
}

# run_sql — psql wrapper: fail on the first SQL error, quiet, no pager.
# Uses PG_HOST/PG_USER/PG_DATABASE set by resolve_connection.
run_sql() {
  psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d "$PG_DATABASE" \
    -v ON_ERROR_STOP=1 -qAt "$@"
}
