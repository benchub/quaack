# 007-expression-lower-email results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 3084 | - | 4 | - |
| stored in lower case | 1 | 3084 | - | 4 | - |
| no such user | 0 | 3084 | - | 3 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 4 total blocks on the slow literals, and pass 14b.
