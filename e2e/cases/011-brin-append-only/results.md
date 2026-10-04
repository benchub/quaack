# 011-brin-append-only results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 50 | 7427 | - | 136 | - |
| a whole day | 50 | 7367 | - | 392 | - |
| before the data starts | 0 | 7356 | - | 11 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 136 total blocks on the slow literals, and pass minimax.
