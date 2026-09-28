# 079-ordered-set-aggregates results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 2 | 5061 | - | 43 | - |
| other customers | 2 | 5061 | - | 40 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 43 total blocks on the slow literals, and pass 14b.
