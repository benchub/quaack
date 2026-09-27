# 096-group-by-distinct-order-using results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 4 | 7771 | - | 12 | - |
| another tenant | 4 | 7771 | - | 12 | - |

Every claim holds.
