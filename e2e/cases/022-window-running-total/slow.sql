SELECT id, posted_at, amount,
       sum(amount) OVER (ORDER BY posted_at, id) AS balance
FROM public.ledger
WHERE account_id = 55
ORDER BY posted_at, id;
