CREATE INDEX ON public.orders (customer_id) INCLUDE (id, created_at);
