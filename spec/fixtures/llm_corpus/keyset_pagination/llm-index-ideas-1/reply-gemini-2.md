{"indexes": ["CREATE INDEX orders_brin_created_at_idx ON public.orders USING brin (created_at)", "CREATE INDEX orders_brin_created_at_id_idx ON public.orders USING brin (created_at, id)"]}
