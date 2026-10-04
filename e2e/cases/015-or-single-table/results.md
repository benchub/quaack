# 015-or-single-table results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2 | 4340 | - | 8 | - |
| both terms hit the same row | 1 | 4340 | - | 7 | - |
| neither matches | 0 | 4340 | - | 6 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 8 total blocks on the slow literals, and pass minimax.
