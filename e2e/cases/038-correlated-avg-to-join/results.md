# 038-correlated-avg-to-join results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3107 | 79125 | 5030 | - | - |
| a longer window | 31158 | 809850 | 5675 | - | - |
| after the data | 0 | 3 | 3 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 5030 total blocks on the slow literals, and pass 14b.
