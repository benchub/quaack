# 070-keyset-pagination-index results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 50 | 4988 | - | 4 | - |
| first page, cursor past the newest order | 50 | 4988 | - | 4 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 4 total blocks on the slow literals, and pass minimax.
