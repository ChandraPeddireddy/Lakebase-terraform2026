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

> **Schema & data (DDL/DML)** are managed separately from this infra, as
> versioned SQL migrations under [`sql/`](sql/README.md). Terraform creates the
> project/branch/endpoint; the migration runner manages what lives *inside* the
> database. Deploy them after `terraform apply` with `cd sql && ./deploy.sh`.

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
| `sql/` | Versioned SQL migrations + runner (schema/tables/data) — see [`sql/README.md`](sql/README.md) |
| `.gitignore` | Ignores `env.sh`, `*.tfvars`, state, `.terraform/` |

## Deleting a project: soft delete vs. purge

`terraform destroy` (or removing the project resource and running `apply`) does
**not** immediately free the project. Deletion behavior is controlled by
`purge_on_delete`:

| Mode | `purge_on_delete` | What happens | Slug freed? |
|---|---|---|---|
| **Soft delete** (default) | `false` | Project is soft-deleted with a **7-day retention window** (`purge_time` is 7 days out). | Not until purge_time — the `project_id` slug stays **reserved**. |
| **Hard delete / purge** | `true` | Project is destroyed immediately, no retention. | Immediately. |

**When to use which:**

- **Soft delete** (`false`) — the safe default. Use for anything you might want
  to recover, and always for **production**. A destroy is reversible-ish: the
  data is retained for 7 days.
- **Purge** (`true`) — use for **throwaway/dev/CI** projects you re-create often.
  Because soft delete reserves the slug, a soft-deleted project blocks you from
  re-applying with the **same `project_id`** until its 7-day window expires.

Set it in `terraform.tfvars`:

```hcl
purge_on_delete = true   # dev/CI: hard-delete on destroy, free the slug now
```

### Fixing `project slug already exists in the workspace`

This error at `apply` time means a project with your `project_id` is still
**soft-deleted** and holding the slug (typical after a `destroy` with the default
`purge_on_delete = false`, then an immediate re-`apply`). There is no undelete
API. Two ways forward:

1. **Purge the leftover soft-deleted project** to free the slug, then re-apply.
   Requires the `databricks` CLI with PAT auth (see [Auth](#auth)):

   ```bash
   source env.sh
   # Force PAT auth so the CLI doesn't fall back to the OAuth cache:
   export DATABRICKS_AUTH_TYPE=pat DATABRICKS_CONFIG_PROFILE=

   # Confirm it's soft-deleted (look for delete_time / purge_time):
   databricks api get "/api/2.0/postgres/projects/<project_id>"

   # Purge it (irreversible — only for a project you intend to discard):
   databricks api delete "/api/2.0/postgres/projects/<project_id>?purge=true"

   terraform apply
   ```

2. **Pick a new `project_id`** in `terraform.tfvars` and `apply`, leaving the old
   one to expire on its own after 7 days.

> ⚠️ Purge is irreversible. Only run it against a project you're certain is a
> discarded/soft-deleted leftover — verify `delete_time` is set first.

**Recommendation — what should be standard:** keep `purge_on_delete = false`
(soft delete) as the standing default so accidental destroys are recoverable, and
flip it to `true` **only** in dev/CI `terraform.tfvars` where you tear down and
re-create the same `project_id` frequently.

## Cleanup / gotchas

- **Delete the dev branch** (guide step 8): remove `databricks_postgres_branch.dev`,
  `databricks_postgres_endpoint.dev_primary`, and the
  `data "databricks_postgres_endpoints" "dev"` block (plus their outputs), then
  `terraform apply`. Terraform destroys the endpoint before the branch.
- **Drift**: changes made via UI/CLI/API are **not** detected by Terraform. Manage
  these resources through Terraform only.
- **Sibling serialization**: Lakebase processes one role/database/endpoint op at a
  time per branch. Add explicit `depends_on` between siblings to avoid
  conflicting-operations errors.
- **`prevent_destroy`**: add a `lifecycle { prevent_destroy = true }` block to a
  production project to block accidental deletion.
