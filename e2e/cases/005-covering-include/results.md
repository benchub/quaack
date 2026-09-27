# 005-covering-include results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 2505 | - | 11 | - |
| another merchant | 1 | 2505 | - | 11 | - |
| merchant with no payments | 1 | 3 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 11 total blocks on the slow literals, and pass 14b.
