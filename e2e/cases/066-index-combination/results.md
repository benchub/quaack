# 066-index-combination results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5 | 16049 | - | 7153 | - |
| a longer window | 5 | 16049 | - | 11738 | - |
| after the data | 0 | 4974 | - | 6 | - |

Every claim holds.
