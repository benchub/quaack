# 023-limit-without-order-by results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5 | 1178 | - | 8 | - |
| another customer | 5 | 1173 | - | 8 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 8 total blocks on the slow literals, and pass 14b.
