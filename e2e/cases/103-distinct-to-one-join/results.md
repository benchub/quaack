# 103-distinct-to-one-join results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 100000 | 7843 | 5576 | - | - |
| another region | 100000 | 7843 | 5576 | - | - |
| pending orders | 12500 | 6812 | 6812 | - | - |
| no such region | 0 | 630 | 618 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 5576 total blocks on the slow literals, and pass minimax.
