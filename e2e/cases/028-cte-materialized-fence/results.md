# 028-cte-materialized-fence results.

Total blocks (README step 13), from `ruby e2e/verify.rb`.
Category: `rewrite`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 6 | 6406 | 16 | - | - |
| another customer | 6 | 6406 | 16 | - | - |
| customer with no orders | 0 | 6406 | 6 | - | - |

Every claim holds.
