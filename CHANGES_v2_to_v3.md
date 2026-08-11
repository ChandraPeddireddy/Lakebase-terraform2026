# Change summary — `terraform-v2-admin` → `terraform-v3-oauth-secrets`

**Reviewer handover.** This branch builds directly on your `terraform-v2-admin`
work. It is a clean linear stack of **11 commits**, no merge commits, no rebase
of your existing history — your v2 commits are untouched at the base.

- **Base (merge-base / v2 HEAD):** `1c2692f` — *Add Terraform-managed secret scope for role passwords*
- **v3 HEAD:** `cd4e7ca` — *Fix DEPLOYMENT_STEPS.md: stray code fence + hardcoded teardown path*
- **Diff:** `git diff terraform-v2-admin..terraform-v3-oauth-secrets`
- **Net:** 13 files, +632 / −63. All new `.tf`/`.sh` code is additive; the two
  edits to existing scripts (`deploy.sh`, `rotate_password.sh`) are net **reductions**
  (logic extracted to a shared library, not removed).

## What this branch adds, in one line

Everything needed to (1) run the SQL/deploy scripts under a **service-principal
OAuth identity** (not just a personal PAT) — the customer/CI auth path — and (2)
grant Lakebase access to **Databricks users and SPs declaratively from Terraform**,
by role, with no hardcoded identities.

Two design decisions were locked in **with architect consent** and are reflected
throughout — please review against these, they are intentional:
1. Use the **Postgres Autoscaling API** (Beta surface — accepted risk).
2. App connects via **native Postgres login using a stored role password**, and
   that password lives in a **Databricks-backed secret scope** (NOT Azure Key
   Vault), written **at runtime** by `rotate_password.sh` so **no plaintext ever
   lands in Terraform state** (`manage_secret_value` stays `false`).

---

## Files changed

| File | +/− | What |
|---|---|---|
| `roles.tf` | **new** +32 | Layer-1: one `databricks_postgres_role` per identity (`for_each`) |
| `variables.tf` | +55 | `db_identity_roles` map + 4 validations |
| `outputs.tf` | +21 | `db_identity_grants` list that drives the grant script |
| `sql/common.sh` | **new** +80 | Shared auth/preflight/connection library (sourced by all 3 scripts) |
| `sql/grant_access.sh` | **new** +98 | Layer-2: applies `app_ro`/`app_rw` group membership atomically |
| `sql/deploy.sh` | +5 / −37 | Migrated to typed CLI + `common.sh` |
| `sql/rotate_password.sh` | +5 / −25 | Migrated to typed CLI + `common.sh` |
| `DEPLOYMENT_STEPS.md` | **new** +238 | First-time + incremental deploy/verify runbook |
| `README.md`, `sql/README.md` | +36 / +41 | Document the identity model & file tree |
| `env.sh.example` | +8 | Option C: OAuth U2M via CLI profile |
| `terraform.tfvars.example` | +11 | `db_identity_roles` example shape |
| `.gitignore` | +2 | Ignore `tfplan` / `*.tfplan` binary plan artifacts |

---

## The 11 commits, grouped by theme, with the *why*

### Theme 1 — Make the scripts work under OAuth (SP / CLI profile), not just PAT

These three commits are the operational core. In v2 the `sql/` scripts assumed a
personal PAT. A customer or CI runner authenticates as a **service principal
(OAuth M2M)**, and that path was broken. Each fix below was **verified live**
against a real Lakebase endpoint.

**`7585bc4` — Support OAuth/profile auth in sql/ scripts, not just PAT**
- *Problem:* `deploy.sh`/`rotate_password.sh` **unconditionally** cleared
  `DATABRICKS_CONFIG_PROFILE`. With no PAT present, that wiped the only auth the
  CLI had (the profile) and left it with nothing → auth failure for OAuth U2M/M2M.
- *Fix:* only force-PAT / wipe-profile **when `DATABRICKS_TOKEN` is actually set**.
  No PAT → leave profile-based OAuth resolution intact.
- Documents the CLI-profile path as **Option C** in `env.sh.example`.

**`bd13df6` — Use typed `databricks postgres` subcommands instead of raw `api` passthrough**
- *Problem:* raw `databricks api get/post /api/2.0/postgres/...` resolves auth
  differently from the typed CLI and can **latch onto a stale cached U2M token**,
  failing `invalid_grant: Refresh token is invalid` even with valid M2M env creds.
  This blocked the scripts under the exact SP auth used in shared/CI environments.
- *Fix:* switch to first-class commands — `databricks postgres get-endpoint`
  (host) and `databricks postgres generate-database-credential` (short-lived
  token). Also gitignore `tfplan`/`*.tfplan`.

**`735cbf6` (part 1) — Auth precedence: PAT > OAuth M2M > config profile**
- *Problem:* even after `7585bc4`, an OAuth **M2M** credential (CLIENT_ID/SECRET,
  no PAT) was still **silently shadowed** by any lingering config profile — the
  CLI gives the profile precedence and ignores the SP creds (verified: auth
  resolved as `databricks-cli`, `client_id` "not used"), and can fail
  `invalid_grant` on a stale profile token.
- *Fix:* clear the profile when **either** a PAT **or** M2M creds are present.
  Precedence is now explicit and documented: **PAT > OAuth M2M > config profile**.

### Theme 2 — Declarative, role-based identity access (the headline feature)

**`8254a84` — Manage Databricks identity access as Terraform + SQL, parameterized by role**

This is the feature to review most carefully. It introduces a **two-layer model**
driven by a single `db_identity_roles` map — **no hardcoded identities in code**.

*Why two layers* (this is subtle and was verified empirically — see below):
- **Layer 1 — `roles.tf` (`databricks_postgres_role`, `for_each`):** creates one
  Postgres role per identity, **bound to OAuth login**. This part **must** go
  through the Databricks API. A plain SQL `CREATE ROLE` **cannot** establish the
  Databricks-identity/OAuth linkage — an unprovisioned user hitting the SQL
  Editor gets *"permission denied — ask the owner to create a PostgreSQL role for
  your Databricks identity."*
- **Layer 2 — `sql/grant_access.sh`:** applies the `app_ro`/`app_rw` **GROUP**
  membership that actually confers table access. This part **must** be SQL,
  because the role API's `membership_roles` field only accepts predefined roles
  and **silently drops** our custom `app_ro`/`app_rw` groups (verified).

Key design choices in this commit worth a reviewer's eye:
- `for_each` keyed by a **stable slug** (not `count`) so add/remove of one
  identity never reshuffles the others in Terraform state.
- `replace_existing = true` so a pre-existing/hand-created role is **adopted**
  rather than failing "already exists".
- `access` map value drives layer 2: `read` → `app_ro` (SELECT), `readwrite` →
  `app_rw` (SELECT/INSERT/UPDATE/DELETE), `none` → login only.
- Verified live: applied 2 roles (1 adopted, 1 created); app SP → `app_rw`,
  human user → `app_ro`.

### Theme 3 — Review-hardening fixes (self-review via `/code-review`)

I ran a code review on the feature above and fixed every finding, one at a time,
each verified live. These are the commits that make it production-representative.

**`735cbf6` (parts 2 & 3) — atomic grants + safe output shape**
- *Atomic grants:* grants previously ran **one `psql` per identity** under
  `set -e`, so one bad row aborted mid-loop leaving a **partial,
  iteration-order-dependent** set of grants — and still printed a precomputed
  success count. Now **all statements batch into one `BEGIN/COMMIT`** over a
  single connection: all-or-nothing rollback, one round trip, and the "done"
  line reports the **real** count only if the transaction committed. (Verified:
  a batch with one invalid role rolls back the valid grant too.)
- *Output shape:* `db_identity_grants` was a **map keyed by principal**, which
  fails plan with **"duplicate object key"** if two slugs share a principal, and
  re-derived the grant target from the var. Now a **list of `{role, access}`**,
  reading `role` from the resource's **actual `spec.postgres_role`** — no
  duplicate-key crash, and the GRANT always targets the role Terraform really
  created (coupling is explicit, can't drift).

**`cdedb2a` — Extract shared auth/connection logic into `sql/common.sh`**
- *Why:* all three scripts carried a near-identical ~40-line block (preflight,
  `DATABRICKS_HOST` guard, auth-precedence, typed-CLI connection resolution). I
  had to hand-apply the same fix to all three **twice** during this work — that
  is exactly the drift risk of triplicated logic.
- *Fix:* one sourced library providing `log`/`err`, `TF_DIR`/`PG_DATABASE`
  defaults, `preflight_and_auth`, `resolve_connection`, `run_sql`. Each script
  keeps its own (genuinely script-specific) arg parsing. **Net −126/+15** across
  the three. The library **refuses to be run directly** (it's `source`-only).
  Behavior verified unchanged against the live deploy.

**`4adc3e5` — Fully declarative access levels + guard the `create_dev_branch` conflict**
- *Access levels:* the `readwrite` case only **granted** `app_rw`, never
  **revoking** a prior direct `app_ro`. A `read → readwrite` transition then left
  the role in **both** groups directly. Privilege was still correct (`app_rw`
  includes `app_ro`), but the DB membership no longer mirrored the declared
  access level — misleading to an audit and to REVOKE-based teardown. Now each
  access level sets the **complete desired membership** (grant wanted, revoke
  unwanted), relying on `app_rw`'s inherited `app_ro` (migration `004`) so read
  access is retained without a stale direct grant. `read ↔ readwrite ↔ none` now
  round-trips cleanly.
- *Config guard:* `roles.tf`'s `for_each` is gated on `create_dev_branch`, so a
  populated `db_identity_roles` with `create_dev_branch = false` **silently
  created zero roles** and left connections failing "permission denied" with no
  signal. Added a **cross-variable validation** that fails at **plan** time with
  a clear message. (Verified on TF 1.15.8: bad combo errors at plan; normal plan
  unaffected.)

### Theme 4 — Deployment runbook (`DEPLOYMENT_STEPS.md`)

Five commits building and hardening a portable deploy/verify runbook. Reviewer
context on *why it iterated*:

- **`0f49fc4`** — initial clean-room deploy & verify runbook (setup/auth → init →
  plan/apply → SQL layers → verify as owner SP **and** as a human user, the
  SQL-Editor read-only test → teardown/troubleshooting).
- **`bd5c7ee`** — remove the hardcoded `/tmp/Lakebase-terraform2026` clone path
  (`/tmp` is wiped on reboot; a customer's clone lives elsewhere). All commands
  now repo-relative.
- **`31ccb7a`** — **split into two workflows**: **A. First-time deploy** (the
  `rm -rf ... tfstate` clean-room path) vs **B. Incremental change** (edit → plan
  → apply → re-run only the affected idempotent SQL). Adds a loud warning: **never
  `rm -rf` state on a live deployment** — that makes Terraform forget it owns the
  resources → "already exists" on next apply.
- **`87e2d40`** — remove hardcoded `--profile lakebase-sandbox` (a personal CLI
  profile) and the hardcoded endpoint path; introduce a `USER_PROFILE` variable
  and resolve the endpoint from `terraform output -raw dev_endpoint_name`
  (project-agnostic).
- **`cd4e7ca`** — fix a stray unbalanced code fence and a leftover `/tmp`
  teardown path found in a self-review of the doc.

---

## Review checklist / what to focus on

- [ ] **Two-layer model in `roles.tf` + `grant_access.sh`** — the empirically-found
      constraint (API for OAuth-bound role, SQL for group membership) is the crux.
- [ ] **Auth precedence** in `sql/common.sh` (`preflight_and_auth`) — PAT > M2M >
      profile. Confirm it matches how your CI/customer runner authenticates.
- [ ] **`db_identity_roles` validations** in `variables.tf` (slug regex,
      identity_type/access enums, and the `create_dev_branch` cross-var guard).
- [ ] **Atomic grant transaction** in `grant_access.sh` — single `BEGIN/COMMIT`.
- [ ] **`db_identity_grants` output** is a list (not map) reading actual
      `spec.postgres_role` — prevents duplicate-key plan crash and drift.
- [ ] **Secret handling** — confirm `manage_secret_value = false` intent: password
      written by `rotate_password.sh` at runtime, never in state.

## Verification status

Every functional change in this branch was **applied and verified live** against
a real `lakebase-demo-dev` deployment (7 resources, 5 migrations, password
stored in the scope, 2 identity grants, read-as-human works + write denied). The
environment has since been **torn down** (slug freed) — redeploy anytime via
`DEPLOYMENT_STEPS.md`.

## Not in scope / open follow-ups (not blockers for this review)

1. Generate an OAuth secret for the app SP so it can authenticate at runtime.
2. Rotation schedule (Job/CI) for `rotate_password.sh`.
3. Remote state backend (Azure) — state is currently local (POC only).

## Privacy note

Tracked files contain **no personal identifiers** — host/email/SP-IDs/project
live only in the gitignored `env.sh`, `terraform.tfvars`, `terraform.tfstate`;
docs and `*.example` files use placeholders. (Non-sensitive app IDs appear in
some commit-message prose; history was intentionally not rewritten.)
