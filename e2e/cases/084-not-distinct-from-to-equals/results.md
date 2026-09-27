# 084-not-distinct-from-to-equals results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 334 | 6015 | 173 | - | - |
| another team | 498 | 6015 | 173 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 173 total blocks on the slow literals, and pass 14b.
