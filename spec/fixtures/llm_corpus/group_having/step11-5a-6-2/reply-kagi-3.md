{"indexes":["CREATE INDEX ON public.orders USING btree (status) INCLUDE (user_id, total_cents) WHERE status IN ('delivered', 'cancelled', 'pending', 'shipped', 'refunded')"]}
