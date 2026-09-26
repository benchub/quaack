# 001-cross-table-or results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 11 | 6818 | 4990 | 6818 | 36 |
| tracking number belongs to the same customer | 10 | 6818 | 4990 | 6818 | 36 |
| email matches, tracking number doesn't exist | 10 | 6818 | 4987 | 6818 | 32 |
| tracking number matches, email doesn't exist | 1 | 6818 | 4976 | 6818 | 22 |
| neither matches | 0 | 6818 | 4973 | 6818 | 18 |
| tracking number of a pending order (NULL in the table) | 10 | 6818 | 4987 | 6818 | 32 |

Every claim holds.
