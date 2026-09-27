# 073-right-join-using results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `none`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 904 | 3443 | - | 1154 | - |
| worst case: top MCV | 361600 | 7123 | - | 450608 | - |

Every claim holds.
