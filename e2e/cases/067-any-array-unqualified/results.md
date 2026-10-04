# 067-any-array-unqualified results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 30 | 4958 | - | 39 | - |
| other customers | 30 | 4958 | - | 33 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 39 total blocks on the slow literals, and pass minimax.
