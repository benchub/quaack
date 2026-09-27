CREATE INDEX ON public.payments (merchant_id) INCLUDE (amount_cents);
