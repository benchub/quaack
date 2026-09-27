# 083-greatest-to-or results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2192 | 3847 | 40 | - | - |
| a week earlier | 12272 | 3847 | 161 | - | - |
| after the data | 0 | 3847 | 6 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 40 total blocks on the slow literals, and pass 14b.
