# 036-distinct-join-to-exists results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `none`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 550 | 6844 | 8944 | - | - |
| a lower threshold | 1000 | 6844 | 4642 | - | - |
| nobody qualifies | 0 | 4964 | 4958 | - | - |

Every claim holds.
