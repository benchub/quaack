CREATE INDEX ON public.webhooks USING gin (payload jsonb_path_ops);
