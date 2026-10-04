# 084-not-distinct-from-to-equals results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 334 | 6015 | 173 | - | - |
| another team | 498 | 6015 | 173 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 173 total blocks on the slow literals, and pass minimax.
