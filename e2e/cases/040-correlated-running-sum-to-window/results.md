# 040-correlated-running-sum-to-window results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 500 | 127706 | 508 | - | - |
| another account | 500 | 127930 | 508 | - | - |
| account with no rows | 0 | 3 | 3 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 508 total blocks on the slow literals, and pass 14b.
