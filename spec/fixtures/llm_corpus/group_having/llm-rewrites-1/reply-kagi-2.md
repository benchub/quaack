```json
{
  "rewrites": [
    {
      "sql": "SELECT o.user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o WHERE o.status = $1 GROUP BY o.user_id HAVING count(*) > $2 ORDER BY spent DESC",
      "transformation": "Baseline rewrite: drop the table alias dependency in ORDER BY is kept as-is; instead normalize the aggregate sort expression to the output alias so the planner can sort on the already-computed aggregate. Semantically identical to the original for every data set.",
      "assumptions": []
    },
    {
      "sql": "SELECT o.user_id, count(o.user_id) AS order_count, sum(o.total_cents) AS spent FROM public.orders o WHERE o.status = $1 GROUP BY o.user_id HAVING count(o.user_id) > $2 ORDER BY spent DESC",
      "transformation": "Replace count(*) with count(o.user_id). Since user_id is NOT NULL, count(user_id) counts exactly the same rows as count(*) and may allow the planner to scan the narrower orders_user_id_idx (index-only scan) for the aggregation instead of the full-width heap.",
      "assumptions": [
        {"kind": "not_null", "table": "public.orders", "column": "user_id"}
      ]
    },
    {
      "sql": "SELECT user_id, order_count, spent FROM (SELECT o.user_id AS user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o WHERE o.status = $1 GROUP BY o.user_id HAVING count(*) > $2) t ORDER BY spent DESC",
      "transformation": "Split aggregation and sorting into a derived table: the inner query performs the filtered GROUP BY/HAVING aggregation, and the outer query only sorts the (small) surviving groups. This can avoid carrying the sort below the aggregate and keeps the sort input to the filtered result set.",
      "assumptions": []
    },
    {
      "sql": "SELECT o.user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o WHERE o.status = $1 AND o.user_id IS NOT NULL GROUP BY o.user_id HAVING count(*) > $2 ORDER BY spent DESC",
      "transformation": "Add a redundant explicit NOT NULL predicate on the group-by column. It is always true given the NOT NULL constraint, but it gives the planner additional selectivity/validity information that can enable an index-only scan on orders_user_id_idx for the grouping.",
      "assumptions": [
        {"kind": "not_null", "table": "public.orders", "column": "user_id"}
      ]
    },
    {
      "sql": "SELECT o.user_id, count(*) AS order_count, sum(o.total_cents)::bigint AS spent FROM public.orders o WHERE o.status = $1 GROUP BY o.user_id HAVING count(*) > $2 ORDER BY spent DESC",
      "transformation": "Annotate the aggregate result with its natural type (sum(integer) is already bigint), keeping column types identical to the original while writing the ORDER BY against the output alias rather than a recomputed aggregate expression, letting the planner reuse the aggregate output for the sort key.",
      "assumptions": [
        {"kind": "not_null", "table": "public.orders", "column": "total_cents"}
      ]
    }
  ]
}
```
