# 014-bitmapand-to-composite results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 286 | 378 | - | 289 | - |
| another city and size | 285 | 378 | - | 288 | - |
| no such city | 0 | 3 | - | 3 | - |

Every claim holds.
