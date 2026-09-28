# 008-like-prefix-pattern-ops results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 25 | 3410 | - | 8 | - |
| wider prefix | 250 | 3410 | - | 17 | - |
| no match | 0 | 3410 | - | 6 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 8 total blocks on the slow literals, and pass 14b.
