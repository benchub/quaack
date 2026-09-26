SELECT id, due_date, amount_cents
FROM public.invoices
WHERE customer_id = 42 AND status = 'overdue';
