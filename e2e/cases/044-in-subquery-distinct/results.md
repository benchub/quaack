# 044-in-subquery-distinct results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 23 | 20 | - | - |
| no such customer | 0 | 9 | 6 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 20 total blocks on the slow literals, and pass 14b.
