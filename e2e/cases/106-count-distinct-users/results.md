# 106-count-distinct-users results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 24 | 19750 | 14019 | - | - |
| submissions | 8 | 15932 | 14019 | - | - |
| no such kind | 0 | 14022 | 14022 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 14019 total blocks on the slow literals, and pass minimax.
