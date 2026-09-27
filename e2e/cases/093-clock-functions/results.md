# 093-clock-functions results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5083 | 3185 | - | 49 | - |
| the next week | 35577 | 3185 | - | 327 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 49 total blocks on the slow literals, and pass 14b.
