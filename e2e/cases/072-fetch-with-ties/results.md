# 072-fetch-with-ties results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 120 | 3853 | - | 124 | - |
| another game | 120 | 3853 | - | 124 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 124 total blocks on the slow literals, and pass minimax.
