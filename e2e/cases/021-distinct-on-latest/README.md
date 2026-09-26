# Case 021: Latest row per device with DISTINCT ON.

**Category:** `index`, new index only.

**Exercises:** DISTINCT ON with a matching ORDER BY; IN list; INCLUDE column for an index-only scan (5a-1).

## Setup.

`telemetry` has 600,000 rows for 5,000 devices. Every `reported_at` is distinct.

## Slow query (`slow.sql`).

Each device's latest battery reading. With no index, Postgres scans the whole table to sort a few hundred rows.

## Expected result.

`telemetry (device_id, reported_at DESC) INCLUDE (battery)`: sorted to match the `DISTINCT ON`, and index-only.

## Proof.

`ruby e2e/verify.rb 021` checks the claims above. The measured table is in `results.md`.
