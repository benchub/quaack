CREATE INDEX ON public.orders (created_at) INCLUDE (total_cents);
