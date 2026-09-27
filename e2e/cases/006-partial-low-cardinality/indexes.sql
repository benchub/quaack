CREATE INDEX ON public.jobs (queued_at, id) WHERE status = 'failed';
