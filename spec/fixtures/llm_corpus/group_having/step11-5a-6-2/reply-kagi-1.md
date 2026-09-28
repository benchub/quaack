```json
{"indexes": ["CREATE INDEX ON public.orders USING btree (user_id, total_cents) WHERE status = 'delivered'"]}
```

Rationale: every mechanical candidate was unused in the worst-case literal (status = 'delivered', ~42% of rows), so a partial index keyed to that most common value — with `user_id` and `total_cents` inside so the aggregation can be fed from the index — covers exactly the case the mechanical btree candidates all missed, while the predicate stays on the low-cardinality `status` column.
