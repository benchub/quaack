# 091-substring-to-like results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2500 | 3739 | 107 | - | - |
| another prefix | 2500 | 3739 | 108 | - | - |
| no match | 0 | 3739 | 3 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 107 total blocks on the slow literals, and pass 14b.
