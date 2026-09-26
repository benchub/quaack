SELECT (SELECT count(*) FROM public.orders
        WHERE status = 'pending' AND created_at >= '2025-12-01 00:00:00+00') AS pending,
       (SELECT count(*) FROM public.orders
        WHERE status = 'cancelled' AND created_at >= '2025-12-01 00:00:00+00') AS cancelled,
       (SELECT count(*) FROM public.orders
        WHERE status = 'shipped' AND created_at >= '2025-12-01 00:00:00+00') AS shipped;
