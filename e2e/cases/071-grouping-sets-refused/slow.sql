SELECT region, tier, count(*) AS customers
FROM public.customers
GROUP BY ROLLUP (region, tier);
