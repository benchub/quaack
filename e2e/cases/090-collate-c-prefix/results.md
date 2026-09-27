# 090-collate-c-prefix results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2779 | 2586 | - | 90 | - |
| another prefix | 279 | 2586 | - | 68 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 90 total blocks on the slow literals, and pass 14b.
