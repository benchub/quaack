SELECT (SELECT count(*) FROM public.orders WHERE status = 'pending') AS pending,
       (SELECT count(*) FROM public.orders WHERE status = 'cancelled') AS cancelled,
       (SELECT count(*) FROM public.orders WHERE status = 'shipped') AS shipped;
