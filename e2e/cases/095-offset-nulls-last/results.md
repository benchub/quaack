# 095-offset-nulls-last results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 20 | 3879 | - | 6 | - |
| another carrier | 20 | 3879 | - | 6 | - |
| a deep page | 20 | 5075 | - | 5922 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 6 total blocks on the slow literals, and pass 14b.
