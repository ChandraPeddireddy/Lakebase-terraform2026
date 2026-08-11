-- 005_create_login_user.sql
-- A login role for the application ("service account"), granted the app_rw
-- group from 004. The role is created WITH LOGIN but WITHOUT a password here —
-- passwords are secrets and must never live in a git-tracked migration. Set /
-- rotate the password out-of-band with sql/rotate_password.sh.
--
-- Until a password is set (and Postgres native login is enabled on the
-- project), this role cannot actually connect — which is intentional: the DDL
-- is safe to commit, the credential is not.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_service') THEN
    -- NOLOGIN-by-default guard, then flip LOGIN below so re-runs are harmless.
    CREATE ROLE app_service LOGIN;
  END IF;
END
$$;

-- Ensure capabilities are correct even if the role pre-existed.
ALTER ROLE app_service LOGIN;

-- Grant the read-write group.
GRANT app_rw TO app_service;
