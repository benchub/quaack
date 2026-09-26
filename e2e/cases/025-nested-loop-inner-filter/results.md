# 025-nested-loop-inner-filter results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 500 | 7118 | - | 2618 | - |
| silver instead of gold | 2000 | 6812 | - | 6812 | - |
| a status nobody has | 0 | 4958 | - | 2118 | - |

Every claim holds.
