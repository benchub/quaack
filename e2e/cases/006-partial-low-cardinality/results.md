# 006-partial-low-cardinality results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 50 | 7785 | - | 52 | - |
| worst case: top MCV | 50 | 7785 | - | 7785 | - |
| typical: another MCV | 50 | 7785 | - | 7785 | - |

Every claim holds.
