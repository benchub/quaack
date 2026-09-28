{"indexes": ["CREATE INDEX ON public.line_items USING btree (product_id, quantity) INCLUDE (order_id) WHERE quantity >= 0"]}
