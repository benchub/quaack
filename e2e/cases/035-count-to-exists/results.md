# 035-count-to-exists results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1000 | 13618 | 4618 | - | - |
| worst case: top MCV | 1000 | 13618 | 5576 | - | - |
| a status nobody has | 0 | 13618 | 4958 | - | - |

Every claim holds.
