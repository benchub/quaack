# 075-natural-join-only results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 400 | 2550 | - | 411 | - |
| another account | 400 | 2550 | - | 412 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 411 total blocks on the slow literals, and pass minimax.
