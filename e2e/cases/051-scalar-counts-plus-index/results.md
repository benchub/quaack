# 051-scalar-counts-plus-index results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 14874 | 4958 | 231 | 77 |
| a shorter window | 1 | 14874 | 4958 | 81 | 27 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 77 total blocks on the slow literals, and pass minimax.
