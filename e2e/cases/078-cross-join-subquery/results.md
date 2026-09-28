# 078-cross-join-subquery results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 60 | 9916 | - | 10 | - |
| the last day | 1440 | 9916 | - | 24 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 10 total blocks on the slow literals, and pass 14b.
