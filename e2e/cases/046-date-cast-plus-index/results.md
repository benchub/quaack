# 046-date-cast-plus-index results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1440 | 4958 | 4958 | 4958 | 26 |
| another day | 1440 | 4958 | 4958 | 4958 | 25 |
| a day with no data | 0 | 4958 | 4958 | 4958 | 6 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 26 total blocks on the slow literals, and pass minimax.
