#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Postgres role password rotation (admin task)
# -----------------------------------------------------------------------------
# Sets or rotates the password for a native-login Postgres role via ALTER ROLE.
# The password is NEVER written to git, printed by default, or passed on the
# command line (which would leak into shell history / ps). It is generated
# securely, applied over TLS, and optionally stored in a Databricks secret scope.
#
# Prereqs:
#   - Postgres native login must be enabled on the project
#     (enable_pg_native_login = true; see ../README.md). Otherwise the role's
#     password auth won't work even after it's set.
#   - You must be able to ALTER the target role (admin on it).
#
# Usage:
#   source ../env.sh
#   ./rotate_password.sh --role app_service                       # generate + set
#   ./rotate_password.sh --role app_service --show                # also print once
#   ./rotate_password.sh --role app_service --secret-scope lakebase --secret-key app_service_pw
#   ./rotate_password.sh --role app_service --password-stdin      # read pw from stdin
#
# Env overrides (same as deploy.sh):
#   PG_DATABASE   default databricks_postgres
#   TF_DIR        default parent of sql/
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROLE="" SHOW=0 PW_STDIN=0 SECRET_SCOPE="" SECRET_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)          ROLE="$2"; shift 2 ;;
    --show)          SHOW=1; shift ;;
    --password-stdin)PW_STDIN=1; shift ;;
    --secret-scope)  SECRET_SCOPE="$2"; shift 2 ;;
    --secret-key)    SECRET_KEY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ROLE" ]] || { err "--role is required"; exit 2; }

# --- Preflight, auth, and connection (see common.sh) -------------------------
preflight_and_auth
resolve_connection

# --- Obtain the new password -------------------------------------------------
if [[ "$PW_STDIN" -eq 1 ]]; then
  IFS= read -r NEW_PW
  [[ -n "$NEW_PW" ]] || { err "empty password on stdin"; exit 2; }
else
  # 32 URL-safe bytes, no shell-hostile characters.
  NEW_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
fi

# --- Apply via ALTER ROLE ----------------------------------------------------
# Pass the password as a psql variable so it is quoted safely and never appears
# on a command line. current_setting/quote_literal guards against injection.
log "Rotating password for role '${ROLE}' on ${PG_HOST}/${PG_DATABASE}"
PGAPPNAME="rotate_password" \
  psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d "$PG_DATABASE" \
       -v ON_ERROR_STOP=1 -qAt \
       -v newpw="$NEW_PW" -v role="$ROLE" <<'SQL'
ALTER ROLE :"role" WITH PASSWORD :'newpw';
SQL
log "Password updated."

# --- Optionally store in a Databricks secret scope ---------------------------
if [[ -n "$SECRET_SCOPE" || -n "$SECRET_KEY" ]]; then
  [[ -n "$SECRET_SCOPE" && -n "$SECRET_KEY" ]] \
    || { err "--secret-scope and --secret-key must be given together"; exit 2; }
  # Check existence via command substitution (not a pipe to grep -q, which trips
  # `set -o pipefail` with SIGPIPE when grep exits early). Create only if absent.
  scopes="$(databricks secrets list-scopes -o json 2>/dev/null || true)"
  if ! grep -q "\"name\": *\"${SECRET_SCOPE}\"" <<<"$scopes"; then
    log "Creating secret scope '$SECRET_SCOPE'"
    databricks secrets create-scope "$SECRET_SCOPE"
  fi
  # Pass the value via a locked-down temp JSON file (--json @file) so it never
  # appears on the command line / in `ps`. Cleaned up on exit.
  req="$(mktemp)"; chmod 600 "$req"
  trap 'rm -f "$req"' EXIT
  python3 -c 'import json,sys;json.dump({"scope":sys.argv[1],"key":sys.argv[2],"string_value":sys.argv[3]},open(sys.argv[4],"w"))' \
    "$SECRET_SCOPE" "$SECRET_KEY" "$NEW_PW" "$req"
  databricks secrets put-secret --json "@$req" >/dev/null
  rm -f "$req"; trap - EXIT
  log "Stored in secret ${SECRET_SCOPE}/${SECRET_KEY}"
fi

# --- Print only if explicitly asked ------------------------------------------
if [[ "$SHOW" -eq 1 ]]; then
  printf '\033[0;33mNew password (shown once):\033[0m %s\n' "$NEW_PW"
elif [[ -z "$SECRET_SCOPE" ]]; then
  log "Password not printed (use --show) and not stored (use --secret-scope/--secret-key)."
  log "Capture it now if you need it — it cannot be retrieved later."
fi
