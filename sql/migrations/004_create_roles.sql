-- 004_create_roles.sql
-- Role model for the app schema: two NOLOGIN "group" roles that bundle
-- privileges, granted to login users in later migrations. This keeps privileges
-- centralized — grant/revoke a person or service by adding/removing a group,
-- never by editing per-object grants.
--
--   app_ro  — read-only  (SELECT)
--   app_rw  — read-write  (SELECT/INSERT/UPDATE/DELETE), inherits app_ro
--
-- CREATE ROLE has no IF NOT EXISTS, so each is guarded by a pg_roles check to
-- stay idempotent/re-runnable.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ro') THEN
    CREATE ROLE app_ro NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw NOLOGIN;
  END IF;
END
$$;

-- app_rw is a superset of app_ro.
GRANT app_ro TO app_rw;

-- Schema access.
GRANT USAGE ON SCHEMA app TO app_ro;

-- Privileges on existing tables.
GRANT SELECT                          ON ALL TABLES    IN SCHEMA app TO app_ro;
GRANT INSERT, UPDATE, DELETE          ON ALL TABLES    IN SCHEMA app TO app_rw;
GRANT USAGE, SELECT                   ON ALL SEQUENCES IN SCHEMA app TO app_rw;

-- Privileges on tables/sequences created *later* (e.g. by future migrations).
-- Applies to objects created by the current role in schema app.
ALTER DEFAULT PRIVILEGES IN SCHEMA app
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA app
  GRANT INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
