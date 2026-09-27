SELECT id, posted_at, amount,
       avg(amount) OVER w AS moving_avg,
       sum(amount) OVER w AS moving_sum
FROM public.ledger
WHERE account_id = 55
WINDOW w AS (ORDER BY posted_at ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
ORDER BY posted_at;
