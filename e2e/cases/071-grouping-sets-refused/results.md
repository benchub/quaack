# 071-grouping-sets-refused results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `refused`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 15 | 618 | - | - | - |

Every claim holds.

**For 20260922-65:** `quaacks intake` must refuse the query with `unsupported_construct`.
