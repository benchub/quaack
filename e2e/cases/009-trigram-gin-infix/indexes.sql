CREATE INDEX ON public.contacts USING gin (full_name gin_trgm_ops);
