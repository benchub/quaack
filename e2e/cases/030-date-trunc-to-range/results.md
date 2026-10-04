# 030-date-trunc-to-range results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 31 | 5034 | 590 | - | - |
| another month | 30 | 5034 | 570 | - | - |
| a month with no data | 0 | 5034 | 6 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 590 total blocks on the slow literals, and pass minimax.
