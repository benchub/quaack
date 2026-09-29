# 036-distinct-join-to-exists results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `none`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 550 | 3013 | 3013 | 3013 | 3013 |
| a lower threshold | 1000 | 3013 | 3013 | 3013 | 3013 |
| nobody qualifies | 0 | 3018 | 3012 | 9 | 3 |

Every claim holds.

**For 20260922-65:** QUAACK must accept nothing and report a negative result (15a).
