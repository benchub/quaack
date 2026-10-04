# 094-named-and-variadic-arguments results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 11201 | 3320 | - | 127 | - |
| a longer look-back | 50081 | 3320 | - | 555 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 127 total blocks on the slow literals, and pass minimax.
