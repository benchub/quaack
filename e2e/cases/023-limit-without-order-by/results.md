# 023-limit-without-order-by results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5 | 1950 | - | 8 | - |
| another customer | 5 | 2717 | - | 8 | - |

Every claim holds.
