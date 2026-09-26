CREATE TABLE public.employees (
    id          bigint PRIMARY KEY,
    name        text NOT NULL,
    manager_id  bigint REFERENCES public.employees (id)
);

INSERT INTO public.employees (id, name, manager_id)
SELECT i, 'Employee ' || i, CASE WHEN i <= 10 THEN NULL ELSE 1 + i % 500 END
FROM generate_series(1, 20000) AS i;

CREATE INDEX employees_manager_id_idx ON public.employees (manager_id);
VACUUM ANALYZE;
