WITH averages AS (
    SELECT customer_id, avg(total_cents) AS avg_cents
    FROM public.orders
    GROUP BY customer_id
)
SELECT o.id, o.customer_id, o.total_cents
FROM public.orders o
JOIN averages a ON a.customer_id = o.customer_id
WHERE o.created_at >= '2025-12-10 00:00:00+00'
  AND o.total_cents > a.avg_cents;
