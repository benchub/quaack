# 024-between-numeric-range results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 58 | 3677 | - | 51 | - |
| worst case: nearly everything | 500000 | 3677 | - | 3677 | - |
| typical: one middle bucket | 1112 | 3677 | - | 61 | - |

Every claim holds.
