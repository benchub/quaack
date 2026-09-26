CREATE INDEX ON public.telemetry (device_id, reported_at DESC) INCLUDE (battery);
