# 043-or-across-join-indexed results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 11 | 6812 | 33 | - | - |
| neither matches | 0 | 6812 | 15 | - | - |

Every claim holds.
