# 031-numeric-literal-on-bigint results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 10 | 4958 | 13 | - | - |
| another customer | 10 | 4958 | 13 | - | - |
| customer with no orders | 0 | 4958 | 3 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 13 total blocks on the slow literals, and pass 14b.
