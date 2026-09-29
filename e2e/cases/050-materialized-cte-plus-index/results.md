# 050-materialized-cte-plus-index results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `both`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 125 | 9609 | 9091 | 9609 | 128 |
| another account | 125 | 9609 | 9091 | 9609 | 128 |
| worst case: top MCV | 125 | 9609 | 9091 | 9609 | 128 |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 128 total blocks on the slow literals, and pass 14b.
