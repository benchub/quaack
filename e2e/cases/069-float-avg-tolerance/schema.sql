-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.samples (
    id         bigint PRIMARY KEY,
    sensor_id  integer NOT NULL,
    batch      integer NOT NULL,
    value      double precision NOT NULL
);

INSERT INTO public.samples (id, sensor_id, batch, value)
SELECT i, 1 + i % 2000, i / 1000, ((i * 0.37) % 100) + 0.1
FROM generate_series(1, 400000) AS i;

CREATE INDEX samples_sensor_id_idx ON public.samples (sensor_id);
CREATE INDEX samples_batch_idx ON public.samples (batch);
VACUUM ANALYZE;
