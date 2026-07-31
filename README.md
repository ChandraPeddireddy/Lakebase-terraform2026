# Lakebase (OLTP) Terraform quickstart

Terraform setup for managing a Databricks **Lakebase** project, branch, and
endpoint on Azure Databricks.

Follows: <https://learn.microsoft.com/en-us/azure/databricks/oltp/projects/automate-with-terraform>

## Prerequisites

| Tool | Needs |
|---|---|
| Terraform | ≥ 1.0 |
| Databricks CLI | any (for `databricks auth env`) |
| Azure CLI | any (optional, for Azure workspaces) |

This config is fully parameterized (see [Configuration](#configuration)) so any
team can point it at their own workspace and project by copying two template
files — no `.tf` edits required.

## Auth

Set `DATABRICKS_HOST` plus **one** credential in `env.sh`. Two methods work:

- **PAT (Personal Access Token)** — simplest. Create at *User Settings →
  Developer → Access tokens*. The `dapi…` value goes in `DATABRICKS_TOKEN`.
  Authenticates as you, so your account needs **CAN MANAGE** on the project.
- **OAuth M2M (service principal)** — recommended for shared/CI use so
  automation isn't tied to a personal identity. Create an SP, generate an OAuth
  secret (`dose…`, *not* `dapi…`), grant it **CAN MANAGE** on the project, and
  set `DATABRICKS_CLIENT_ID` (a UUID) + `DATABRICKS_CLIENT_SECRET`.

> CAN USE is not enough for either method — it can't create/update resources.
> Common mistake: pasting a `dapi…` PAT into `DATABRICKS_CLIENT_SECRET`. A PAT
> is a bearer token (`DATABRICKS_TOKEN`), not an OAuth secret — mixing them up
> fails with `invalid_client` at the OAuth token endpoint.

## Setup steps

```bash
cd /Users/animesh.jha/projects/lakebase-terraform

# 1. Auth — set DATABRICKS_HOST + one credential (see Auth above), then source
cp env.sh.example env.sh
# edit env.sh
source env.sh

# 2. Configure — override any defaults for your team (optional)
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: e.g. project_id, pg_version, display name

# 3. Initialize (downloads the databricks provider)
terraform init

# 4. Format + preview
terraform fmt
terraform plan

# 5. Create project + dev branch + endpoint
terraform apply

# 6. Inspect
terraform output
terraform output dev_branch_name
terraform output dev_endpoint_name
terraform output branch_names
```

Both `env.sh` and `terraform.tfvars` are gitignored, so per-team secrets and
values never get committed — only the `.example` templates are tracked.

## Command reference

| Command | What it does |
|---|---|
| `terraform init` | Downloads providers, sets up `.terraform/` (run once) |
| `terraform fmt` | Auto-formats `.tf` files |
| `terraform validate` | Checks config is syntactically valid |
| `terraform plan` | Dry-run — **always read before apply** |
| `terraform apply` | Creates/updates resources (add `-auto-approve` to skip prompt) |
| `terraform output [name]` | Prints output values |
| `terraform state list` | Lists tracked resources |
| `terraform destroy` | Tears down everything it manages |

## Configuration

All tunable values live in `variables.tf` with defaults that reproduce the
original quickstart. Override them in `terraform.tfvars` — see
`terraform.tfvars.example` for the full annotated list. Highlights:

| Variable | Default | Purpose |
|---|---|---|
| `project_id` | `my-app` | Project id (immutable — changing recreates it) |
| `project_display_name` | `My Application` | UI display name |
| `pg_version` | `17` | Postgres major version (14–17) |
| `enable_pg_native_login` | `false` | Native Postgres username/password login |
| `purge_on_delete` | `false` | Hard-delete on destroy (skip 7-day retention) |
| `create_dev_branch` | `true` | Set `false` to manage the project only |
| `dev_branch_id` | `dev` | Development branch id |
| `dev_endpoint_type` | `ENDPOINT_TYPE_READ_WRITE` | or `…READ_ONLY` |

Inputs are validated (e.g. `pg_version` must be 14–17, `project_id` must be a
valid slug), so bad values fail at `plan` instead of at the API.

## What gets created

Order of operations: **Project → Branch → Endpoint**

- `databricks_postgres_project.app` — top-level project (`project_id`, `pg_version`).
  Creating it auto-provisions a `production` branch + `primary` read-write endpoint.
- `databricks_postgres_branch.dev` — isolated dev branch. Also gets its own
  implicit `primary` endpoint. Skipped entirely when `create_dev_branch = false`.
- `databricks_postgres_endpoint.dev_primary` — adopts the dev branch's implicit
  `primary` endpoint via `replace_existing = true`.

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Provider + version constraints, env-var auth |
| `variables.tf` | Input variables + validation (all tunables) |
| `main.tf` | Project, branch, endpoint, and data sources |
| `outputs.tf` | Output values (steps 3–7) |
| `terraform.tfvars.example` | Config template (copy to `terraform.tfvars`) |
| `env.sh.example` | Auth env vars template (copy to `env.sh`) |
| `.gitignore` | Ignores `env.sh`, `*.tfvars`, state, `.terraform/` |

## Cleanup / gotchas

- **Delete the dev branch** (guide step 8): remove `databricks_postgres_branch.dev`,
  `databricks_postgres_endpoint.dev_primary`, and the
  `data "databricks_postgres_endpoints" "dev"` block (plus their outputs), then
  `terraform apply`. Terraform destroys the endpoint before the branch.
- **Deleting a project soft-deletes it** (7-day retention). For immediate hard
  delete: add `purge_on_delete = true` to the project, `apply`, then remove the
  resource and `apply` again.
- **Drift**: changes made via UI/CLI/API are **not** detected by Terraform. Manage
  these resources through Terraform only.
- **Sibling serialization**: Lakebase processes one role/database/endpoint op at a
  time per branch. Add explicit `depends_on` between siblings to avoid
  conflicting-operations errors.
- **`prevent_destroy`**: add a `lifecycle { prevent_destroy = true }` block to a
  production project to block accidental deletion.
