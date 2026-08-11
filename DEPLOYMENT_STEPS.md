# Deployment steps — Lakebase Terraform (v3)

Commands to deploy and verify the `terraform-v3-oauth-secrets` branch.

Assumes: `env.sh` holds the automation SP's OAuth M2M creds
(`DATABRICKS_HOST` + `DATABRICKS_CLIENT_ID` + `DATABRICKS_CLIENT_SECRET`),
`terraform.tfvars` is configured, terraform + databricks CLI + libpq installed.

All commands are **repo-relative** — run them from the root of your clone. The
scripts resolve paths relative to themselves (`$(dirname)` / `terraform -chdir`),
so the repo can live anywhere; nothing depends on a fixed absolute path.

## Two workflows — pick the right one

| | **A. First-time deploy** | **B. Incremental change** |
|---|---|---|
| When | Fresh clone / brand-new environment | Every change after the first deploy |
| Wipe state (`rm -rf`) | Yes — nothing exists yet | **NEVER** — state is your source of truth |
| `terraform init` | Yes | Only if providers/backend changed |
| Steps | Phase 0 → 1 → 2 → 3 → verify | **Just the [Incremental loop](#b-incremental-change-the-everyday-workflow)** |

> ⚠️ **NEVER run `rm -rf ... terraform.tfstate` on a live deployment.** The state
> file is Terraform's record of what it created. Deleting it makes Terraform
> forget it owns the resources — the next `apply` tries to recreate them and
> fails with "already exists" (or orphans them). The `rm -rf` in Phase 1 is
> ONLY for a from-scratch clone or a deliberate clean-room test.

Terraform is declarative: after the first deploy, you **edit config and re-plan**.
`plan` diffs your config against the state file and shows only the delta — add one
identity and it's "1 to add, 0 to change, 0 to destroy", nothing else disturbed.
That is the everyday path (workflow B); the full first-time sequence (workflow A)
is below it.

---

# A. First-time deploy

---

## Phase 0 — Setup (once per shell)

```bash
# Clone the repo wherever you keep your IaC (NOT /tmp — it's wiped on reboot),
# then cd into it. Skip the clone if you already have a checkout.
git clone https://github.com/ChandraPeddireddy/Lakebase-terraform2026.git
cd Lakebase-terraform2026
git checkout terraform-v3-oauth-secrets

# First time only: create your local config from the templates and fill them in
#   cp env.sh.example env.sh                 # set DATABRICKS_HOST + creds
#   cp terraform.tfvars.example terraform.tfvars   # set project_id, identities, etc.

# Auth: load automation SP M2M creds; ensure no profile/PAT shadows them
source env.sh
unset DATABRICKS_CONFIG_PROFILE DATABRICKS_TOKEN

# Put psql on PATH (libpq is keg-only on macOS/Homebrew; adjust for your OS)
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

# Sanity checks
git rev-parse --abbrev-ref HEAD                            # -> terraform-v3-oauth-secrets
git log --oneline -1                                       # -> latest commit
databricks auth describe | grep -i "Authenticated with"    # -> oauth-m2m
```

---

## Phase 1 — Clean-room Terraform init

```bash
# Wipe local terraform artifacts for a true fresh deploy
rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup tfplan

terraform init       # downloads provider, writes lock file
terraform validate   # -> Success! The configuration is valid.
```

---

## Phase 2 — Plan & apply infra

```bash
terraform plan -out=tfplan
# EXPECT: Plan: 7 to add, 0 to change, 0 to destroy
#   project, dev branch, endpoint, secret scope, secret ACL, 2 identity roles
#   verify: enable_pg_native_login = true, purge_on_delete = false

terraform apply tfplan
# EXPECT: Apply complete! Resources: 7 added
```

---

## Phase 3 — SQL layers (schema -> password -> grants)

```bash
cd sql

# 3a. Migrations
./deploy.sh --dry-run      # EXPECT: 5 pending
./deploy.sh                # EXPECT: Done — applied 5 migration(s)

# 3b. Set app_service password + store in secret scope
./rotate_password.sh --role app_service --secret-scope lakebase --secret-key app_service_pw
# EXPECT: Password updated. / Stored in secret lakebase/app_service_pw

# 3c. Identity grants (app SP -> app_rw, you -> app_ro)
./grant_access.sh --dry-run    # preview the transaction
./grant_access.sh              # EXPECT: Done — applied grants for 2 identities in one transaction
```

---

## Phase 4 — Verify as the automation SP (owner)

```bash
# still in sql/ — resolve connection for ad-hoc psql
ENDPOINT_NAME="projects/lakebase-demo-dev/branches/dev/endpoints/primary"
PG_HOST="$(databricks postgres get-endpoint "$ENDPOINT_NAME" -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["hosts"]["host"])')"
PG_USER="$(databricks current-user me | python3 -c 'import sys,json;print(json.load(sys.stdin)["userName"])')"
export PGPASSWORD="$(databricks postgres generate-database-credential "$ENDPOINT_NAME" -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
export PGSSLMODE=require

psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d databricks_postgres -c "\dt app.*"
psql -h "$PG_HOST" -p 5432 -U "$PG_USER" -d databricks_postgres -c "SELECT count(*) FROM app.customers;"   # -> 3
```

---

## Phase 5 — Verify as YOU (the real SQL-Editor test)

```bash
# Connect using YOUR identity via the lakebase-sandbox profile (NOT the SP)
EP="projects/lakebase-demo-dev/branches/dev/endpoints/primary"
YOUR_HOST="$(databricks postgres get-endpoint "$EP" --profile lakebase-sandbox -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["hosts"]["host"])')"
YOU="$(databricks current-user me --profile lakebase-sandbox -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["userName"])')"
export PGPASSWORD="$(databricks postgres generate-database-credential "$EP" --profile lakebase-sandbox -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
export PGSSLMODE=require

# Read should work:
psql -h "$YOUR_HOST" -p 5432 -U "$YOU" -d databricks_postgres -c "SELECT count(*) FROM app.customers;"   # -> 3
# Write should be DENIED (you are read-only):
psql -h "$YOUR_HOST" -p 5432 -U "$YOU" -d databricks_postgres -c "INSERT INTO app.customers(email,full_name) VALUES('x@x.com','x');"   # -> permission denied
```

Then open the **SQL Editor** in the workspace UI, point it at the **dev** branch
endpoint, and confirm you can browse `app.customers` / `app.orders`.

---

# B. Incremental change (the everyday workflow)

After the first deploy exists, you **never wipe state and never re-init** (unless
providers/backend changed). You edit config, preview the delta, apply it, and
re-run only the SQL layer affected. Terraform's state file makes `plan` show just
what changed.

```bash
# 1. Setup this shell (same as Phase 0, but NO rm -rf, NO fresh clone)
cd <your-repo-clone>
source env.sh
unset DATABRICKS_CONFIG_PROFILE DATABRICKS_TOKEN
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

# 2. Make your change — edit a .tf file or terraform.tfvars. Examples:
#    - add/remove an identity in db_identity_roles
#    - change an identity's access (read <-> readwrite <-> none)
#    - bump pg_version, change endpoint type, etc.

# 3. Preview EXACTLY the delta (read this every time before applying)
terraform plan -out=tfplan
#    e.g. "Plan: 1 to add, 0 to change, 0 to destroy" — only your change

# 4. Apply just that delta
terraform apply tfplan

# 5. Re-run ONLY the SQL layer affected by the change (all idempotent):
cd sql
./grant_access.sh          # if you changed db_identity_roles (identities/access)
# ./deploy.sh              # if you ADDED a migration (NNN_*.sql) — applies only new ones
# ./rotate_password.sh --role app_service --secret-scope lakebase --secret-key app_service_pw
#                         # if you need to rotate the app password
```

**Notes**
- `terraform plan` with no config change prints *"No changes. Your infrastructure
  matches the configuration."* — proof the state is in sync.
- Adding a migration: create the next `NNN_*.sql`, never edit an applied one
  (the checksum guard rejects edits). `deploy.sh` applies only pending files.
- Removing an identity: delete its entry from `db_identity_roles`, `apply`
  (Terraform drops the role), then `grant_access.sh` reconciles remaining grants.
- If you edit `versions.tf` (provider/version) or add a backend, run
  `terraform init` once before `plan`.

---

## Teardown (when done)

```bash
cd /tmp/Lakebase-terraform2026

# To free the project slug IMMEDIATELY (so you can redeploy the same project_id):
#   1. set purge_on_delete = true in terraform.tfvars
#   2. terraform apply -auto-approve      # records purge intent
#   3. terraform destroy -auto-approve    # hard-deletes, frees slug now
# Then set purge_on_delete back to false.
#
# Default (purge_on_delete = false): terraform destroy soft-deletes with a 7-day
# retention window; the slug stays reserved until it expires.
```

---

## Notes / troubleshooting

- **`psql: command not found`** — re-run `export PATH="/opt/homebrew/opt/libpq/bin:$PATH"`
  (does not persist across new terminal tabs).
- **Auth resolves to the wrong identity** — ensure `DATABRICKS_CONFIG_PROFILE`
  and `DATABRICKS_TOKEN` are unset when using M2M env creds (Phase 0). The scripts
  clear the profile automatically when M2M/PAT creds are present, but a clean env
  is unambiguous.
- **"no dev_endpoint_name output"** — run `terraform apply` first (Phase 2).
- **"project slug already exists"** on apply — a prior soft-deleted project holds
  the slug; purge it (see Teardown) or pick a new `project_id`.
- **Endpoint host changes** on every project recreate — always resolve it from
  `databricks postgres get-endpoint`, never hardcode.
```
