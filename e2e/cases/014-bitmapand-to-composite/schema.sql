-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.listings (
    id           bigint PRIMARY KEY,
    city_id      integer NOT NULL,
    bedrooms     integer NOT NULL,
    price_cents  integer NOT NULL,
    title        text NOT NULL
);

-- 300 cities, 1 to 6 bedrooms.
INSERT INTO public.listings (id, city_id, bedrooms, price_cents, title)
SELECT i, 1 + (i * 7) % 300, 1 + (i / 7) % 6, 50000 + (i * 97) % 500000, 'Listing ' || i || repeat(' ', 40)
FROM generate_series(1, 600000) AS i;

CREATE INDEX listings_city_id_idx ON public.listings (city_id);
CREATE INDEX listings_bedrooms_idx ON public.listings (bedrooms);
VACUUM ANALYZE;
