# 004-sort-under-limit results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 20 | 2508 | - | 23 | - |
| another author | 20 | 2508 | - | 23 | - |
| author with no posts | 0 | 6 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 23 total blocks on the slow literals, and pass 14b.
