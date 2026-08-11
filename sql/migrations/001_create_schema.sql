-- 001_create_schema.sql
-- Creates the application schema. All app objects live here (not `public`) so
-- they are namespaced and easy to manage/drop as a unit.
--
-- Migrations are forward-only and immutable: never edit a file once it has been
-- applied to any shared environment — add a new, higher-numbered migration
-- instead. The runner (deploy.sh) checksums each file and refuses to run if an
-- already-applied migration has changed.

CREATE SCHEMA IF NOT EXISTS app;

COMMENT ON SCHEMA app IS 'Application-owned objects for the Lakebase quickstart.';
