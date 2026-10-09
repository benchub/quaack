{"rewrites": [
  {"sql": "WITH r AS MATERIALIZED (SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE u.country = $1 AND o.created_at >= $2 AND o.created_at < $3) SELECT * FROM r ORDER BY created_at DESC LIMIT $4", "transformation": "materialize the join", "assumptions": []},
  {"sql": "WITH r AS MATERIALIZED (SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE u.country = $1 AND u.name IS NOT NULL AND o.created_at >= $2 AND o.created_at < $3) SELECT * FROM r ORDER BY created_at DESC LIMIT $4", "transformation": "skip incomplete users", "assumptions": []}
]}
