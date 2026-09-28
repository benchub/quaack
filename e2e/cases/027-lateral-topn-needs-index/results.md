# 027-lateral-topn-needs-index results.

Total blocks (DESIGN.md step 13), from `ruby e2e/verify.rb`.
Category: `index`.

| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |
| --- | ---: | ---: | ---: | ---: | ---: |
| slow (from the plan) | 3000 | 13624 | - | 3635 | - |
| silver customers | 27000 | 117762 | - | 27851 | - |

Every claim holds.

**For 20260922-65:** QUAACK's top-ranked fix must touch at most 3635 total blocks on the slow literals, and pass 14b.
