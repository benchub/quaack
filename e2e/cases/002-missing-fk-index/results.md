# 002-missing-fk-index results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 4964 | - | 22 | - |
| another customer | 10 | 4964 | - | 22 | - |
| customer with no orders | 0 | 4964 | - | 12 | - |

Every claim holds.
