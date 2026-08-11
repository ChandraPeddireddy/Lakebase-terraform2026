-- 002_create_tables.sql
-- Core tables for the sample app. Uses IF NOT EXISTS so the DDL is safe to
-- re-run; the migration runner already guarantees single application, but
-- idempotent DDL keeps things robust against partial failures.

CREATE TABLE IF NOT EXISTS app.customers (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       TEXT        NOT NULL UNIQUE,
    full_name   TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app.orders (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  BIGINT      NOT NULL REFERENCES app.customers (id) ON DELETE CASCADE,
    amount_cents BIGINT      NOT NULL CHECK (amount_cents >= 0),
    status       TEXT        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'paid', 'cancelled')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON app.orders (customer_id);
