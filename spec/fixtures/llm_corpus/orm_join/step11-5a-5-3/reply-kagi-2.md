{"indexes":["CREATE INDEX ON public.orders USING brin (created_at)","CREATE INDEX ON public.users USING btree (country) INCLUDE (id, email, name) WHERE country IS NOT NULL"]}
