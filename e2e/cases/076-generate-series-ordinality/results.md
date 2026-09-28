# 076-generate-series-ordinality results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 7 | 16070 | - | 162 | - |
| days with no data | 7 | 16070 | - | 24 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 162 total blocks on the slow literals, and pass 14b.
