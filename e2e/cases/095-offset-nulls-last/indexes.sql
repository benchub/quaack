CREATE INDEX ON public.shipments (carrier, shipped_at DESC NULLS LAST, id DESC);
