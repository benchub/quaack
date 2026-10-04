{"indexes":["CREATE INDEX ON public.line_items USING brin (order_id)","CREATE INDEX ON public.orders USING brin (created_at)","CREATE INDEX ON public.orders USING brin (id, created_at)"]}
