# 032-coalesce-wrapper results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5000 | 6568 | 5007 | - | - |
| the top MCV | 400000 | 6568 | 6568 | - | - |
| a status that isn't the COALESCE default | 75000 | 6568 | 6572 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 5007 total blocks on the slow literals, and pass minimax.
