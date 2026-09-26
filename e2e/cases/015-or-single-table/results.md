# 015-or-single-table results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2 | 4340 | - | 8 | - |
| both terms hit the same row | 1 | 4340 | - | 7 | - |
| neither matches | 0 | 4340 | - | 6 | - |

Every claim holds.
