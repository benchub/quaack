# 068-except-range-arm results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 475 | 1331 | - | 554 | - |
| a lower threshold | 225 | 1330 | - | 1033 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 554 total blocks on the slow literals, and pass 14b.
