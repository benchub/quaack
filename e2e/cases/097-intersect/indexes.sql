CREATE INDEX ON public.orders (created_at) INCLUDE (customer_id);
