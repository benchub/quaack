# 048-recursive-cte-plus-index results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 111 | 12155 | 4414 | 8663 | 240 |
| another root | 111 | 12155 | 4414 | 8663 | 241 |
| not a root | 0 | 12155 | 9 | 8663 | 7 |

Every claim holds.
