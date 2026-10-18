# 105-union-feed-to-union-all results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 20 | 18128 | 22 | - | - |
| another group | 20 | 18126 | 22 | - | - |
| a longer page | 500 | 18128 | 312 | - | - |
| no such group | 0 | 18 | 9 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 22 total blocks on the slow literals, and pass minimax.
