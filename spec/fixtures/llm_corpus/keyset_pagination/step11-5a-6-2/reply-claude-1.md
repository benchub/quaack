{"indexes": ["CREATE INDEX ON public.orders USING btree ((updated_at <= created_at), created_at DESC, id DESC)"]}
