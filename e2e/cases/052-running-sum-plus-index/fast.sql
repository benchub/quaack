SELECT l.id, l.posted_at, l.amount,
       sum(l.amount) OVER (ORDER BY l.posted_at) AS balance
FROM public.ledger l
WHERE l.account_id = 55
ORDER BY l.posted_at;
