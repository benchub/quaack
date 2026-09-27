# 055-low-selectivity results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 4958 | - | 417 | - |
| a rare status | 1 | 4958 | - | 135 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 417 total blocks on the slow literals, and pass 14b.
