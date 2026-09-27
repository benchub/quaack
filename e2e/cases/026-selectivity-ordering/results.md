# 026-selectivity-ordering results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 12 | 5919 | - | 4 | - |
| thread in another tenant | 12 | 5916 | - | 5 | - |
| tenant and thread don't match | 0 | 5919 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 4 total blocks on the slow literals, and pass 14b.
