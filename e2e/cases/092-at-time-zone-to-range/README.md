# Case 092: Local date via AT TIME ZONE.

**Category:** `rewrite`, rewrite only.

**Exercises:** AT TIME ZONE; AT LOCAL; range in another time zone, across a DST change.

## Setup.

Case 001's `customers` and `orders`, with `created_at` indexed.

## Slow query (`slow.sql`).

Orders placed on a New York calendar day. Converting the column hides it from the index.

## Expected result.

A half-open range between New York midnights, converted back to `timestamptz`. It holds on the 23- and 25-hour days when daylight saving time starts and ends, which two of the literal sets check.

## Proof.

`ruby e2e/verify.rb 092` checks the claims above. The measured table is in `results.md`, which also gives the bound the end-to-end test holds QUAACK to. A named index or rewrite is one way to reach that bound, not the only acceptable answer.
