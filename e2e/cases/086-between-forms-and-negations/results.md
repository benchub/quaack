# 086-between-forms-and-negations results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 363 | 4696 | - | 1007 | - |
| another price band | 365 | 4696 | - | 1006 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 1007 total blocks on the slow literals, and pass 14b.
