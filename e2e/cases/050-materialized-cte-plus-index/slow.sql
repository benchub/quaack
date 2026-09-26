WITH purchases AS MATERIALIZED (
    SELECT id, account_id, created_at FROM public.events WHERE kind = 'purchase'
)
SELECT id, created_at
FROM purchases
WHERE account_id = 17;
