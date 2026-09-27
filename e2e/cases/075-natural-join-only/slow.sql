SELECT e.id, k.label, e.happened_at
FROM ONLY public.events e
NATURAL JOIN public.event_kinds k
WHERE e.account_id = 17;
