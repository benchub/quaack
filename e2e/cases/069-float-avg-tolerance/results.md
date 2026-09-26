# 069-float-avg-tolerance results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 20001 | 4063682 | 2697 | - | - |
| a narrower batch range | 5001 | 1016076 | 2588 | - | - |

Every claim holds.
