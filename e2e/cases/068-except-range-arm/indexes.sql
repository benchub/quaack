CREATE INDEX ON public.orders (total_cents) INCLUDE (customer_id);
