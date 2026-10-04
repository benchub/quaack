# 034-not-in-to-not-exists results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 100 | 374270 | 2542 | - | - |
| silver instead of gold | 400 | 1492806 | 7942 | - | - |
| region with no gold customers | 0 | 741 | 741 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 2542 total blocks on the slow literals, and pass minimax.
