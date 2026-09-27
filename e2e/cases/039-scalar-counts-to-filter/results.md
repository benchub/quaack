# 039-scalar-counts-to-filter results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 14874 | 4958 | - | - |
| worst case: all three are the top MCV | 1 | 14874 | 4958 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 4958 total blocks on the slow literals, and pass 14b.
