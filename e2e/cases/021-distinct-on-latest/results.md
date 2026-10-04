# 021-distinct-on-latest results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 5 | 9321 | - | 17 | - |
| other devices | 5 | 9321 | - | 7 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 17 total blocks on the slow literals, and pass minimax.
