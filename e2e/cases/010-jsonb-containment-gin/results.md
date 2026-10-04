# 010-jsonb-containment-gin results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 800 | 5715 | - | 804 | - |
| a type that doesn't exist | 0 | 5715 | - | 4 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 804 total blocks on the slow literals, and pass minimax.
