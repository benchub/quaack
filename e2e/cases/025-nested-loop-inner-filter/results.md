# 025-nested-loop-inner-filter results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 500 | 6812 | - | 2618 | - |
| silver instead of gold | 2000 | 6812 | - | 6812 | - |
| worst case: top MCV | 10000 | 6812 | - | 6812 | - |
| a status nobody has | 0 | 4958 | - | 2118 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 2618 total blocks on the slow literals, and pass 14b.
