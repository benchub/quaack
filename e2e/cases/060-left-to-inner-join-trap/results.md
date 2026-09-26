# 060-left-to-inner-join-trap results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `trap`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1200 | 5699 | 7181 | - | - |

Every claim holds.
