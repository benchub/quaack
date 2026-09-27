SELECT product_id, sum(delta) AS net
FROM public.stock_moves
WHERE product_id IN (101, 2002, 3303, 4404, 5505)
GROUP BY product_id;
