SELECT customer_id,
       count(DISTINCT status) AS statuses,
       string_agg(status, ',' ORDER BY created_at) AS history,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY total_cents) AS median_cents
FROM public.orders
WHERE customer_id IN (4242, 31337)
GROUP BY customer_id;
