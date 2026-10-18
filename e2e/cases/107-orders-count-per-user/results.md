# 107-orders-count-per-user results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 75000 | 34358 | 30715 | - | - |
| refunded | 25000 | 41370 | 30715 | - | - |
| no such status | 0 | 25003 | 25003 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 30715 total blocks on the slow literals, and pass minimax.
