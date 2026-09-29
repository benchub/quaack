# 073-right-join-using results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 904 | 3443 | - | 257 | - |
| worst case: top MCV | 361600 | 7123 | - | 1915 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 257 total blocks on the slow literals, and pass 14b.
