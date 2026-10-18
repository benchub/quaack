SELECT DISTINCT orders.*, customers.email AS customer_email
FROM public.orders
INNER JOIN public.customers ON customers.id = orders.customer_id
WHERE customers.region = 'eu' AND orders.status = 'shipped';
