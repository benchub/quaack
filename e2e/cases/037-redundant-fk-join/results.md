# 037-redundant-fk-join results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 19041 | 833 | 215 | - | - |
| the last day only | 321 | 651 | 8 | - | - |
| after the data | 0 | 3 | 3 | - | - |

Every claim holds.
