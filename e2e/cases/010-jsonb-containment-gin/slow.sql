SELECT id, received_at, payload ->> 'account' AS account
FROM public.webhooks
WHERE payload @> '{"type": "refund"}';
