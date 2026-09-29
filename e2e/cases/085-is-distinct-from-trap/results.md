# 085-is-distinct-from-trap results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `trap`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 1 | 454 | 454 | - | - |

Every claim holds.

**For 20260922-65:** QUAACK must reject the rewrite in `fast.sql`.
