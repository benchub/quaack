# 064-max-to-order-limit-trap results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `trap`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 4 | 4 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK must reject the rewrite in `fast.sql`.
