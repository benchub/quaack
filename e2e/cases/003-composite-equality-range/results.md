# 003-composite-equality-range results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 509 | - | 19 | - |
| another account | 10 | 510 | - | 19 | - |
| a whole month | 43 | 509 | - | 52 | - |
| an empty window | 0 | 509 | - | 12 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 19 total blocks on the slow literals, and pass 14b.
