# 022-window-running-total results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 500 | 3277 | - | 511 | - |
| another account | 500 | 3277 | - | 511 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 511 total blocks on the slow literals, and pass 14b.
