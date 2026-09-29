# 018-in-list results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5 | 3751 | - | 140 | - |
| other products | 5 | 3751 | - | 128 | - |
| products with no moves | 0 | 3751 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 140 total blocks on the slow literals, and pass 14b.
