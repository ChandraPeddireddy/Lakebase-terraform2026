# SQL migrations

Versioned, forward-only SQL migrations for the Lakebase database. This is
deployed and managed **separately** from the Terraform infra — Terraform creates
the project/branch/endpoint; these migrations manage the schema and data *inside*
the database.

## Design

Standard sequential-migration pattern (Flyway/Rails-style), kept minimal:

- **Sequentially numbered files** in `migrations/` (`NNN_description.sql`) applied
  in ascending order.
- **Forward-only and immutable** — never edit a migration once it has been
  applied anywhere. Add a new, higher-numbered file instead.
- **State lives in the database** in `app.schema_migrations`, so the runner is
  stateless. Each applied migration records its filename, a **SHA-256 checksum**,
  and a timestamp.
- **Idempotent** — re-running applies only what's pending; already-applied
  migrations are skipped. A checksum guard aborts if an applied file was changed.
- **Transactional** — each migration and its ledger insert run in a single
  transaction, so a failure leaves nothing half-applied.

```
sql/
├── migrations/
│   ├── 001_create_schema.sql       # CREATE SCHEMA app
│   ├── 002_create_tables.sql       # tables + indexes
│   ├── 003_seed_data.sql           # idempotent seed/reference data
│   ├── 004_create_roles.sql        # app_ro / app_rw group roles + grants
│   └── 005_create_login_user.sql   # app_service login role (no password)
├── deploy.sh                       # the migration runner
├── rotate_password.sh              # admin: set/rotate a role's password
└── README.md
```

The intended order is **schema → tables → data**, which is just the numeric
order. Add more the same way (`004_…`, `005_…`).

## Prerequisites

| Tool | Notes |
|---|---|
| `psql` | `brew install libpq` (client only) |
| `terraform` | endpoint connection details come from `terraform output` |
| `databricks` CLI | mints the short-lived Postgres token |

The infra must already be applied (`terraform apply` in the parent dir) so
`dev_endpoint_name` output exists.

## Usage

```bash
source ../env.sh        # DATABRICKS_HOST + DATABRICKS_TOKEN (see ../README.md Auth)

./deploy.sh             # apply all pending migrations
./deploy.sh --status    # list applied vs pending; change nothing
./deploy.sh --dry-run   # list what would be applied; change nothing
```

No connection strings or passwords are ever hardcoded: the runner reads the
endpoint from Terraform, looks up your Postgres username (your Databricks email),
and mints a fresh, short-lived OAuth token as the password on each run.

### Optional overrides

| Env var | Default | Purpose |
|---|---|---|
| `PG_DATABASE` | `databricks_postgres` | Target database name |
| `TF_DIR` | parent of `sql/` | Where to read `terraform output` |

## Adding a migration

1. Create the next-numbered file, e.g. `migrations/004_add_widgets.sql`.
2. Write forward-only DDL/DML. Prefer idempotent statements
   (`CREATE TABLE IF NOT EXISTS`, `INSERT … ON CONFLICT DO NOTHING`) as a
   robustness backstop.
3. `./deploy.sh --dry-run` to preview, then `./deploy.sh` to apply.
4. Commit the new file. **Never edit an already-applied migration** — the
   checksum guard will (correctly) refuse to run.

## Password & role management (admin)

Roles and grants are managed as ordinary migrations (`004`, `005`) because they
are forward-only DDL. **Passwords are not** — a password is a secret and must
never live in a git-tracked file. Set or rotate one with `rotate_password.sh`,
which generates a strong password, applies it via `ALTER ROLE … WITH PASSWORD`
over TLS, and optionally stores it in a Databricks secret scope. It never writes
the password to disk or prints it unless you ask.

```bash
source ../env.sh

# Generate a strong password and set it (not printed, not stored):
./rotate_password.sh --role app_service

# Generate + store in a Databricks secret scope (recommended).
# The scope itself is created by Terraform (see ../secrets.tf); this writes the
# value into it at runtime so the password never lands in Terraform state:
./rotate_password.sh --role app_service --secret-scope lakebase --secret-key app_service_pw

# Generate + print once (capture it yourself):
./rotate_password.sh --role app_service --show

# Provide your own password (read from stdin, never from argv/history):
echo 'my-password' | ./rotate_password.sh --role app_service --password-stdin
```

The role model (from the migrations):

| Role | Login | Privileges |
|---|---|---|
| `app_ro` | no | `SELECT` on `app.*` (group role) |
| `app_rw` | no | `app_ro` + `INSERT/UPDATE/DELETE` (group role) |
| `app_service` | yes | member of `app_rw`; the app's login account |

`ALTER DEFAULT PRIVILEGES` is set so tables added by **future** migrations are
granted to `app_ro`/`app_rw` automatically.

> **Native login must be enabled** for password auth to actually connect. This
> project ships with `enable_pg_native_login = false`, so setting a password
> succeeds but the role can't log in with it until you flip that flag (see the
> parent [`README.md`](../README.md) / `terraform.tfvars`) and `terraform apply`.
> Human users connect with a short-lived OAuth token regardless.

## Rollbacks

This runner is intentionally forward-only (no `down` scripts). To reverse a
change, write a new migration that undoes it. For a full reset in a **throwaway
dev** database you can `DROP SCHEMA app CASCADE;` and re-run `./deploy.sh` — never
do this against data you care about.
