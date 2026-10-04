# 097-intersect results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 7600 | 9916 | - | 118 | - |
| narrower windows | 400 | 9916 | - | 63 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 118 total blocks on the slow literals, and pass minimax.
