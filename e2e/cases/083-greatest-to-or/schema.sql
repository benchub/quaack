CREATE TABLE public.docs (
    id          bigint PRIMARY KEY,
    created_at  timestamptz NOT NULL,
    updated_at  timestamptz,
    priority    integer NOT NULL,
    note        text NOT NULL
);

-- 60% of docs were updated, within a day of creation. 30% have an empty note.
INSERT INTO public.docs (id, created_at, updated_at, priority, note)
SELECT i, timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute',
       CASE WHEN i % 5 < 3 THEN timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
                                + ((i * 37) % 1440) * interval '1 minute' END,
       i % 10,
       CASE WHEN i % 10 < 3 THEN '' ELSE 'note ' || i END
FROM generate_series(1, 500000) AS i;

CREATE INDEX docs_created_at_idx ON public.docs (created_at);
CREATE INDEX docs_updated_at_idx ON public.docs (updated_at);
VACUUM ANALYZE;
