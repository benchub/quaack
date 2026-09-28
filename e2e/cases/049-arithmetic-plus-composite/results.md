# 049-arithmetic-plus-composite results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 20 | 3822 | 3822 | 3874 | 23 |
| another merchant and bucket | 20 | 3822 | 3822 | 3874 | 23 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 23 total blocks on the slow literals, and pass 14b.
