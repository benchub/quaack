# 029-cte-referenced-twice results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2 | 7644 | 29 | - | - |
| same customer twice | 2 | 7644 | 29 | - | - |
| customers with no orders | 2 | 7644 | 9 | - | - |

Every claim holds.
