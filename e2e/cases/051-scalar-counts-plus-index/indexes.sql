CREATE INDEX ON public.orders (created_at) INCLUDE (status);
