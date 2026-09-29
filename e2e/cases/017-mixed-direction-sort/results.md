# 017-mixed-direction-sort results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 4449 | - | 13 | - |
| another game | 10 | 4449 | - | 13 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 13 total blocks on the slow literals, and pass 14b.
