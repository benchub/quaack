# 089-array-subquery results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3 | 13243 | - | 22 | - |
| other articles | 3 | 13243 | - | 22 | - |

Every claim holds.
