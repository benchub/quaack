# 013-group-by-index-only results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 4 | 2505 | - | 6 | - |
| another tenant | 4 | 2505 | - | 6 | - |
| tenant with no tickets | 0 | 3 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 6 total blocks on the slow literals, and pass 14b.
