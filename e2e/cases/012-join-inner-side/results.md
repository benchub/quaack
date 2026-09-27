# 012-join-inner-side results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 30 | 11172 | - | 146 | - |
| another customer | 30 | 11172 | - | 146 | - |
| customer with no orders | 0 | 26 | - | 6 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 146 total blocks on the slow literals, and pass 14b.
