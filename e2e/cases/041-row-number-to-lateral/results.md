# 041-row-number-to-lateral results.

Total blocks (DESIGN.md's blocks-metric), from `ruby e2e/verify.rb`.
Category: `none`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3000 | 3059 | 3018 | 3059 | 3018 |
| silver customers | 27000 | 27442 | 27128 | 27442 | 27128 |

Every claim holds.

**For 20260922-65:** QUAACK must accept nothing and report a negative result (negative-result).
