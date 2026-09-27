{"indexes":["CREATE INDEX ON public.orders USING brin (created_at)","CREATE INDEX ON public.users USING btree (id) INCLUDE (email) WHERE country = 'US'"]}
