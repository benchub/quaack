# Case 104: eager_load ordered by the association's column.

**Category:** `rewrite`, rewrite only.

**Exercises:** LEFT OUTER JOIN from Rails' eager_load on a belongs_to; validated FK plus NOT NULL assumption (assumption-check); ORDER BY the joined table's column under a LIMIT.

## Setup.

Case 001's `customers` and `orders`, with `orders.customer_id` and `customers.name` indexed. `orders.customer_id` is `NOT NULL` with a validated foreign key. Each customer has one pending order, one cancelled one, and eight shipped ones.

## Slow query (`slow.sql`).

An admin page lists the first 25 pending orders by customer name, as Rails writes `Order.where(status: "pending").eager_load(:customer).order("customers.name", :id).limit(25)`. `eager_load` joins a `belongs_to` association with a `LEFT OUTER JOIN`. A `LEFT JOIN` must keep every order, so Postgres reads `orders` first: it scans all 500,000 orders, joins each pending one to its customer, and sorts them all by name to keep 25.

## Expected result.

The same query with an inner join. Stated assumptions: `orders.customer_id` is `NOT NULL`, and its foreign key to `customers.id` is valid, so every order has exactly one customer and the `LEFT JOIN` never fills a row with `NULL`. An inner join's tables can go in either order, so Postgres walks `customers_name_idx` in name order, looks up each customer's orders by `orders_customer_id_idx`, and stops after 25 rows.

The transform rule `left_join_to_inner` makes exactly this rewrite from `slow.sql`.

## Notes.

The deep page, 49,000 rows in, only proves equivalence. It isn't a literals set, since literals keeps a `LIMIT` at its slow literal.

## Proof.

`ruby e2e/verify.rb 104` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
