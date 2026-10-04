# 077-unnest-array-join results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3 | 3334 | - | 15 | - |
| other skus | 3 | 3334 | - | 15 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 15 total blocks on the slow literals, and pass minimax.
