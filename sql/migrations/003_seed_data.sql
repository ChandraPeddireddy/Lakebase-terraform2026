-- 003_seed_data.sql
-- Seed/reference data. ON CONFLICT DO NOTHING keeps the insert idempotent so a
-- re-run (or a manual replay) never duplicates or errors on the natural keys.

INSERT INTO app.customers (email, full_name) VALUES
    ('ada@example.com',   'Ada Lovelace'),
    ('alan@example.com',  'Alan Turing'),
    ('grace@example.com', 'Grace Hopper')
ON CONFLICT (email) DO NOTHING;

INSERT INTO app.orders (customer_id, amount_cents, status)
SELECT c.id, v.amount_cents, v.status
FROM (VALUES
    ('ada@example.com',   1299, 'paid'),
    ('alan@example.com',   4999, 'pending'),
    ('grace@example.com',  2500, 'paid')
) AS v(email, amount_cents, status)
JOIN app.customers c ON c.email = v.email
-- Only seed orders once: skip if this customer already has any order.
WHERE NOT EXISTS (SELECT 1 FROM app.orders o WHERE o.customer_id = c.id);
