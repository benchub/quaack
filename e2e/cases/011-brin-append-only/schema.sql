-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.readings (
    id           bigint PRIMARY KEY,
    sensor_id    integer NOT NULL,
    recorded_at  timestamptz NOT NULL,
    value        integer NOT NULL
);

-- Rows arrive in time order, so recorded_at's correlation is 1.
INSERT INTO public.readings (id, sensor_id, recorded_at, value)
SELECT i, 1 + i % 50, timestamptz '2025-01-01 00:00:00+00' + i * interval '2 seconds', (i * 31) % 1000
FROM generate_series(1, 1000000) AS i;
VACUUM ANALYZE;
