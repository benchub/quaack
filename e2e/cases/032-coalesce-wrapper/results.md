# 032-coalesce-wrapper results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5000 | 6568 | 5007 | - | - |
| worst case: top MCV | 400000 | 6568 | 6568 | - | - |
| a status that isn't the COALESCE default | 75000 | 6568 | 6572 | - | - |

Every claim holds.
