# 020-clock-anchor-current-date results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 8639 | 3677 | - | 94 | - |
| last week | 50000 | 3677 | - | 617 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 94 total blocks on the slow literals, and pass minimax.
