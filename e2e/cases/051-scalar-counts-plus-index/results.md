# 051-scalar-counts-plus-index results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 14874 | 4958 | 231 | 77 |
| a shorter window | 1 | 14874 | 4958 | 81 | 27 |

Every claim holds.
