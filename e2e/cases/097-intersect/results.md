# 097-intersect results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 7600 | 9916 | - | 118 | - |
| narrower windows | 400 | 9916 | - | 63 | - |

Every claim holds.
