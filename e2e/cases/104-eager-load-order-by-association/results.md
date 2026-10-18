# 104-eager-load-order-by-association results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 25 | 6844 | 353 | - | - |
| shipped orders | 25 | 6844 | 68 | - | - |
| cancelled orders | 25 | 6844 | 347 | - | - |
| a deep page | 25 | 8443 | 8441 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 353 total blocks on the slow literals, and pass minimax.
