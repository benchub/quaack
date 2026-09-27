WITH o AS (
    SELECT customer_id, total_cents FROM public.orders
)
SELECT 'first' AS who, count(*) AS orders, sum(total_cents) AS total FROM o WHERE customer_id = 4242
UNION ALL
SELECT 'second', count(*), sum(total_cents) FROM o WHERE customer_id = 31337;
