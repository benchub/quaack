# 009-trigram-gin-infix results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 22 | 3014 | - | 28 | - |
| a common name part | 176 | 3014 | - | 304 | - |
| no match | 0 | 3014 | - | 4 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 28 total blocks on the slow literals, and pass 14b.
