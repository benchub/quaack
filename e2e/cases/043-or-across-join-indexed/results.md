# 043-or-across-join-indexed results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 11 | 6812 | 33 | - | - |
| neither matches | 0 | 6812 | 15 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 33 total blocks on the slow literals, and pass 14b.
