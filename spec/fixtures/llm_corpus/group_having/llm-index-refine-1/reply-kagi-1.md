{"indexes":["CREATE INDEX ON public.orders USING btree (user_id) INCLUDE (status, total_cents) WHERE status IS NOT NULL"]}
