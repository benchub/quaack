# 047-not-in-plus-index results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 100 | 115599 | 5699 | 374270 | 2542 |
| silver instead of gold | 400 | 445299 | 5699 | 1492806 | 7942 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 2542 total blocks on the slow literals, and pass 14b.
