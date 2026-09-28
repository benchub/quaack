# 052-running-sum-plus-index results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 100 | 228877 | 3261 | 5473 | 107 |
| another account | 100 | 233374 | 3261 | 5539 | 107 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 107 total blocks on the slow literals, and pass 14b.
