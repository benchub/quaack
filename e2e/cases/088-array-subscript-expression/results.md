# 088-array-subscript-expression results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 600 | 3750 | - | 603 | - |
| a common first tag | 3087 | 3750 | - | 3093 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 603 total blocks on the slow literals, and pass 14b.
