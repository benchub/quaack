# 092-at-time-zone-to-range results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1440 | 4958 | 23 | - | - |
| the day DST ends | 1500 | 4958 | 23 | - | - |
| the day DST starts | 1380 | 4958 | 22 | - | - |
| another zone | 1440 | 4958 | 23 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 23 total blocks on the slow literals, and pass 14b.
