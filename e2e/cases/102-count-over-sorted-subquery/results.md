# 102-count-over-sorted-subquery results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 409 | 7 | - | - |
| a user with no posts | 1 | 8 | 5 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 7 total blocks on the slow literals, and pass minimax.
