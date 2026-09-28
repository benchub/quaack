{"indexes":["CREATE INDEX ON public.orders USING btree (created_at DESC, id DESC, total_cents) WHERE (updated_at <= created_at)"]}
