{"indexes": ["CREATE INDEX ON public.orders USING brin (created_at)", "CREATE INDEX ON public.users (id) INCLUDE (email) WHERE country = 'US'"]}
