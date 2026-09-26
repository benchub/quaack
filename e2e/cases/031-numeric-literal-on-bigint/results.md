# 031-numeric-literal-on-bigint results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 4958 | 13 | - | - |
| another customer | 10 | 4958 | 13 | - | - |
| customer with no orders | 0 | 4958 | 3 | - | - |

Every claim holds.
