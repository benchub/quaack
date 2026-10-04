{"indexes":["CREATE INDEX ON public.orders USING btree (user_id) INCLUDE (total_cents) WHERE status <> 'delivered'"]}
