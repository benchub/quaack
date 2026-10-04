# 028-cte-materialized-fence results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 6 | 6359 | 16 | - | - |
| another customer | 6 | 6359 | 16 | - | - |
| customer with no orders | 0 | 6359 | 6 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 16 total blocks on the slow literals, and pass minimax.
