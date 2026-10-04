# 042-duplicate-subquery-to-lateral results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 878 | 25032 | 13618 | - | - |
| an earlier cutoff | 734 | 23160 | 13618 | - | - |
| everyone qualifies | 1000 | 26618 | 13618 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 13618 total blocks on the slow literals, and pass minimax.
