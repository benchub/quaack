# Case 067: = ANY(array) with unqualified names.

**Category:** `index`, new index only.

**Exercises:** = ANY(array) atom; relation qualification (input); CASE in the select list.

## Setup.

Case 001's `customers` and `orders`, with no index on `orders.customer_id`. The query doesn't qualify its table name.

## Slow query (`slow.sql`).

Orders for a few customers, passed as one array parameter, as many drivers do.

## Expected result.

`orders (customer_id)`. input must qualify `orders` as `public.orders` first, using the plan's `search_path`.

## Proof.

`ruby e2e/verify.rb 067` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
