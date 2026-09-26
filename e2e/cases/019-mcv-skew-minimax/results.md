# 019-mcv-skew-minimax results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3 | 3753 | - | 253 | - |
| worst case: top MCV, the giant tenant | 3 | 3693 | - | 3693 | - |
| typical: a mid-histogram tenant | 3 | 3753 | - | 253 | - |

Every claim holds.
