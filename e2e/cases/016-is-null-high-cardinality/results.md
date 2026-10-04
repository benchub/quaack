# 016-is-null-high-cardinality results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 100 | 4242 | - | 2508 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 2508 total blocks on the slow literals, and pass minimax.
