-- 006_create_nba_tables.sql
-- Writable app-side tables for the NBA (Next Best Action) workload. These live
-- in schema `app` so they inherit the app_ro/app_rw default privileges set up in
-- 004 (no per-table GRANTs needed here).
--
-- Forward-only and immutable: never edit this file once applied to a shared
-- environment — add a higher-numbered migration instead. IF NOT EXISTS keeps the
-- DDL re-runnable even though the runner already guarantees single application.
--
-- NOT created here: `nba_member_features`. That is the Delta->Lakebase SYNCED
-- table — created and owned by the synced-table pipeline (see
-- scripts/sync_member_features.sh), read-only in Postgres, and it lives in the
-- `public` schema. Do not FK to it: the sync can reload/replace it wholesale.

-- Candidate next-best-actions (reference data the scorer ranks over).
CREATE TABLE IF NOT EXISTS app.nba_action_catalog (
    action_id    TEXT        PRIMARY KEY,
    action_name  TEXT        NOT NULL,
    category     TEXT,
    description  TEXT,
    is_active    BOOLEAN     NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Served recommendations: one row per (member, action) per scoring run, so a
-- single scoring emits several ranked rows — hence a surrogate PK, not
-- (member_id, scored_at). member_id is stored as a value (no FK to the synced
-- feature table by design). TEXT member_id tolerates non-numeric / zero-padded
-- member identifiers; change to BIGINT if the source guarantees integer ids.
CREATE TABLE IF NOT EXISTS app.nba_recommendations (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id     TEXT             NOT NULL,
    action_id     TEXT             NOT NULL REFERENCES app.nba_action_catalog (action_id),
    score         DOUBLE PRECISION NOT NULL,
    rank          INT,
    model_version TEXT,
    scored_at     TIMESTAMPTZ      NOT NULL DEFAULT now()
);

-- "Latest recommendations for a member" is the hot serving lookup.
CREATE INDEX IF NOT EXISTS idx_nba_reco_member_scored
    ON app.nba_recommendations (member_id, scored_at DESC);

-- Outcome telemetry for offline evaluation / model retrain. No FK on action_id:
-- telemetry ingestion must never be blocked by referential integrity, and
-- retired actions may still appear in historical events. outcome is left free-
-- form (e.g. presented|accepted|rejected|ignored) so evolving event taxonomies
-- don't require a schema change.
CREATE TABLE IF NOT EXISTS app.nba_feedback (
    event_id     TEXT             PRIMARY KEY,
    member_id    TEXT             NOT NULL,
    action_id    TEXT             NOT NULL,
    outcome      TEXT             NOT NULL,
    reward       DOUBLE PRECISION,
    occurred_at  TIMESTAMPTZ      NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_nba_feedback_member_time
    ON app.nba_feedback (member_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_nba_feedback_action
    ON app.nba_feedback (action_id);
