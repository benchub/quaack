-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.telemetry (
    id           bigint PRIMARY KEY,
    device_id    integer NOT NULL,
    reported_at  timestamptz NOT NULL,
    battery      integer NOT NULL,
    raw          text NOT NULL
);

INSERT INTO public.telemetry (id, device_id, reported_at, battery, raw)
SELECT i, 1 + i % 5000, timestamptz '2025-01-01 00:00:00+00' + i * interval '1 second', 100 - i % 100,
       repeat('r', 60)
FROM generate_series(1, 600000) AS i;
VACUUM ANALYZE;
