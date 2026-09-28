{"indexes":["CREATE INDEX ON public.orders USING btree (created_at DESC, id DESC) WHERE (updated_at <= created_at)"]}
