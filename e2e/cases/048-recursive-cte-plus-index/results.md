# 048-recursive-cte-plus-index results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 111 | 12155 | 4414 | 8663 | 240 |
| another root | 111 | 12155 | 4414 | 8663 | 241 |
| not a root | 0 | 12155 | 9 | 8663 | 7 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 240 total blocks on the slow literals, and pass minimax.
