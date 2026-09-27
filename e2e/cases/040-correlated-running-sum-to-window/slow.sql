SELECT l.id, l.posted_at, l.amount,
       (SELECT sum(l2.amount) FROM public.ledger l2
        WHERE l2.account_id = l.account_id AND l2.posted_at <= l.posted_at) AS balance
FROM public.ledger l
WHERE l.account_id = 55
ORDER BY l.posted_at;
