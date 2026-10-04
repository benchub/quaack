```json
{"rewrites":[{"transformation":"Replaces the correlated EXISTS subquery (whose SELECT list was a constant placeholder $2) with an uncorrelated IN subquery projecting li.product_id, renumbering the remaining placeholders ($3 -> $2, $4 -> $3); semantically an EXISTS-to-IN semi-join conversion.","assumptions":[{"kind":"not_null","table":"public.line_items","column":"product_id"},{"kind":"not_null","table":"public.products","column":"id"}]}]}
```
