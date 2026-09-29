# 081-boolean-tests results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 36 | 6945 | - | 39 | - |
| another assignee | 47 | 6945 | - | 42 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 39 total blocks on the slow literals, and pass 14b.
