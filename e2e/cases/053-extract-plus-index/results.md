# 053-extract-plus-index results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 4958 | 4958 | 4958 | 175 |
| another month | 1 | 4958 | 4958 | 4958 | 169 |
| a year with no data | 1 | 4958 | 4958 | 4958 | 3 |

Every claim holds.
