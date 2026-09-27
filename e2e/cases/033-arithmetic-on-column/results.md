# 033-arithmetic-on-column results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 500 | 3185 | 504 | - | - |
| the lowest bucket | 500 | 3185 | 503 | - | - |
| above the data | 0 | 3185 | 3 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 504 total blocks on the slow literals, and pass 14b.
