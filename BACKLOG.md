# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## How this file works.

- Each task has an ID made of the date it was added and a number: `YYYYMMDD-N`. IDs never change and never get reused, even if a task is dropped.
- New tasks get the date they're added. Tasks from reviews, test findings, or new ideas go at the end of the section they belong to, or under "Added later" if no section fits.
- **Depends on** lists tasks that must be done first. "None" means the task can start any time.
- **Design** points to the section the task comes from.
- **Status** is `todo`, `in progress`, `done`, or `dropped`.
- **Open questions** are things I already know I'll need to ask about. Every task will get more questions when we pick it up.
- Each task is built test first. CLAUDE.md has the rules.
- Finished tasks move to BACKLOG-COMPLETE.md, and a one-line stub stays here. Never reopen a finished task. Add a new one instead.
- Tasks name DESIGN.md's steps by slug, such as `index-rank`. A stub keeps its task's old title, which may use an old step ID such as `5a-7`; DESIGN.md's "Old step IDs" table maps those to slugs.

## Foundations.

### 20260922-1. Project skeleton. Done, see BACKLOG-COMPLETE.md.

### 20260922-2. Test database harness. Done, see BACKLOG-COMPLETE.md.

### 20260922-3. Governed store. Done, see BACKLOG-COMPLETE.md.

### 20260922-4. Enclave command-line script. Done, see BACKLOG-COMPLETE.md.

### 20260922-5. Driver transport. Done, see BACKLOG-COMPLETE.md.

### 20260922-6. LLM client. Done, see BACKLOG-COMPLETE.md.

## Trust boundary.

### 20260922-7. Egress function and whitelist. Done, see BACKLOG-COMPLETE.md.

### 20260922-8. Error filtering. Done, see BACKLOG-COMPLETE.md.

### 20260922-9. Leak tests. Done, see BACKLOG-COMPLETE.md.

### 20260922-10. Inbound check for rewrite candidates. Done, see BACKLOG-COMPLETE.md.

### 20260922-11. Inbound check for index DDL. Done, see BACKLOG-COMPLETE.md.

### 20260922-12. Inbound check for step 10 inserts. Done, see BACKLOG-COMPLETE.md.

## Input.

### 20260922-13. Input intake. Done, see BACKLOG-COMPLETE.md.

### 20260922-14. Fully qualify relations. Done, see BACKLOG-COMPLETE.md.

### 20260922-15. Canonical plan form. Done, see BACKLOG-COMPLETE.md.

## Production inventory.

### 20260922-16. Production inventory. Done, see BACKLOG-COMPLETE.md.

## Schema, statistics, and classification.

### 20260922-17. 3a relations. Done, see BACKLOG-COMPLETE.md.

### 20260922-18. 3b schema dump and subset. Done, see BACKLOG-COMPLETE.md.

### 20260922-19. 3c statistics. Done, see BACKLOG-COMPLETE.md.

### 20260922-20. 3d volatility check. Done, see BACKLOG-COMPLETE.md.

### 20260922-21. 3e literal set. Done, see BACKLOG-COMPLETE.md.

### 20260922-22. 3f PII and low-cardinality classification. Done, see BACKLOG-COMPLETE.md.

### 20260922-23. 3g redaction. Done, see BACKLOG-COMPLETE.md.

### 20260922-24. 3h clock anchoring. Done, see BACKLOG-COMPLETE.md.

## Run server.

### 20260922-25. Run server checks. Done, see BACKLOG-COMPLETE.md.

### 20260922-26. 4a racetrack setup. Done, see BACKLOG-COMPLETE.md.

### 20260922-27. 4b arena setup. Done, see BACKLOG-COMPLETE.md.

### 20260922-28. 5 plan gate. Done, see BACKLOG-COMPLETE.md.

### 20260922-29. 5a-4 single-candidate testing. Done, see BACKLOG-COMPLETE.md.

### 20260922-30. 5a-1 generator one. Done, see BACKLOG-COMPLETE.md.

### 20260922-31. 5a-2 generator two. Done, see BACKLOG-COMPLETE.md.

### 20260922-32. 5a-3 dedupe and filter. Done, see BACKLOG-COMPLETE.md.

### 20260922-33. 5a-5 generator three. Done, see BACKLOG-COMPLETE.md.

### 20260922-34. 5a-6 refinement round. Done, see BACKLOG-COMPLETE.md.

### 20260922-35. 5a-7 combination and ranking. Done, see BACKLOG-COMPLETE.md.

### 20260922-36. Step 5 orchestration. Done, see BACKLOG-COMPLETE.md.

### 20260922-37. 6a rewrite generation. Done, see BACKLOG-COMPLETE.md.

### 20260922-38. 6b assumption check. Done, see BACKLOG-COMPLETE.md.

### 20260922-39. 7 operator candidates. Done, see BACKLOG-COMPLETE.md.

### 20260922-40. 8 structural discards. Done, see BACKLOG-COMPLETE.md.

### 20260922-41. 8 mechanical index search per candidate. Done, see BACKLOG-COMPLETE.md.

### 20260922-42. 8 three-configuration pruning. Done, see BACKLOG-COMPLETE.md.

### 20260922-43. 9 predicate atom extraction. Done, see BACKLOG-COMPLETE.md.

### 20260922-44. 9 value pools. Done, see BACKLOG-COMPLETE.md.

### 20260922-45. 9 scenario builder. Done, see BACKLOG-COMPLETE.md.

### 20260922-46. 9a, 9b, and 9e arena transaction runner. Done, see BACKLOG-COMPLETE.md.

### 20260922-47. 9d result comparator. Done, see BACKLOG-COMPLETE.md.

### 20260922-48. 9c vacuity guard. Done, see BACKLOG-COMPLETE.md.

### 20260922-49. Step 9 orchestration. Done, see BACKLOG-COMPLETE.md.

### 20260922-50. 10a counterexample generation. Done, see BACKLOG-COMPLETE.md.

### 20260922-51. 10b and 10c compare and roll back. Done, see BACKLOG-COMPLETE.md.

### 20260922-52. 11 LLM index search per candidate. Done, see BACKLOG-COMPLETE.md.

### 20260922-53. 12a build and hide indexes. Done, see BACKLOG-COMPLETE.md.

### 20260922-54. 12b run discipline. Done, see BACKLOG-COMPLETE.md.

### 20260922-55. 13 baseline runs. Done, see BACKLOG-COMPLETE.md.

### 20260922-56. 13a index baselines. Done, see BACKLOG-COMPLETE.md.

### 20260922-57. 14 candidate runs. Done, see BACKLOG-COMPLETE.md.

### 20260922-58. 14a and 14b metric and minimax rule. Done, see BACKLOG-COMPLETE.md.

### 20260922-59. 14c production result comparison. Done, see BACKLOG-COMPLETE.md.

### 20260922-60. 14d selection. Done, see BACKLOG-COMPLETE.md.

### 20260922-61. Burndown counters. Done, see BACKLOG-COMPLETE.md.

### 20260922-62. 15 main report. Done, see BACKLOG-COMPLETE.md.

### 20260922-63. 15a negative result. Done, see BACKLOG-COMPLETE.md.

### 20260922-64. 15b burndown tables. Done, see BACKLOG-COMPLETE.md.

### 20260922-65. Full pipeline. Done, see BACKLOG-COMPLETE.md.

### 20260922-66. Run teardown. Done, see BACKLOG-COMPLETE.md.

## Added later.

### 20260923-1. Postgres 17 parser under Postgres 18. Done, see BACKLOG-COMPLETE.md.

### 20260923-2. Enclave deploys by gem install only. Done, see BACKLOG-COMPLETE.md.

### 20260923-3. Rename the enclave gem to quaacks. Done, see BACKLOG-COMPLETE.md.

### 20260923-4. Harden the runtime boundary check. Done, see BACKLOG-COMPLETE.md.

### 20260923-5. Discover spec suites instead of listing them. Done, see BACKLOG-COMPLETE.md.

### 20260923-7. Simplify and relax the static boundary checker. Done, see BACKLOG-COMPLETE.md.

### 20260923-11. Index candidate and statistics shapes. Done, see BACKLOG-COMPLETE.md.

### 20260923-12. 5a-2 on rewrite plans. Done, see BACKLOG-COMPLETE.md.

### 20260923-13. Tighten the runtime boundary checker tests. Done, see BACKLOG-COMPLETE.md.

### 20260923-14. Finish the index candidate and statistics shapes. Done, see BACKLOG-COMPLETE.md.

### 20260923-15. Finish the test database harness without ForkGuard. Done, see BACKLOG-COMPLETE.md.

### 20260923-16. Harness loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-17. Index shape loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-18. Runtime checker test loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-19. MCV frequencies in the statistics input. Done, see BACKLOG-COMPLETE.md.

### 20260923-20. Finish 5a-1 generator one. Done, see BACKLOG-COMPLETE.md.

### 20260923-21. index-from-query loose ends.

Still open from the reviews of 20260922-30 and 20260923-20:
- **Join reduction.** index-from-query decides nullability from syntax alone. Once a strict WHERE conjunct on a table rejects its nulls, Postgres reduces the outer join. Then it pushes down that table's `IS NULL` and the ON conjuncts `Join#keeps?` drops, but index-from-query still skips them. HypoPG examples: `c LEFT JOIN o ... WHERE o.region = 3 AND o.note IS NULL` misses `orders(note, region)`. `c LEFT JOIN o ON o.customer_id = c.id AND c.region = 5 WHERE o.status = 1` uses `customers(region)`.
- **Tests:** nullability at depth for RIGHT and FULL joins (two mutants survive), "USING always counts" for outer joins, and the error sentinel test checking `full_message` and the cause.
- **Comment:** "a join to one still counts for the table on the other side" isn't true for an outer join to a derived table.
- **Smaller gaps:** an ORDER BY on a nullable-side table's columns becomes a wasted key; `FOR UPDATE OF o` is falsely refused; `(o).*` isn't recognized as a star; `AS o(a, b)` alias lists aren't modeled; INCLUDE covers only the select list and GROUP BY; a prefix LIKE needs `text_pattern_ops` unless the collation is C; incremental sort isn't handled.

- **Depends on:** 20260923-20.
- **Came from:** Both reviews of 20260922-30, both reviews of 20260923-20, and the 20260922-30 builder's notes.
- **Design:** index-from-query.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260923-22. MCV statistics loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-23. Dedupe repeated ORDER BY columns in 5a-1. Done, see BACKLOG-COMPLETE.md.

### 20260923-24. index-from-plan loose ends.

Still open from the reviews of 20260922-31:
- **Needs a decision:** common values spelled differently get a wasted partial. For example, `n = 1.5` on a numeric that pg_stats prints as `1.50` looks rare. Either skip the partial when the column side is cast, or treat a non-MCV literal as unknown when MCVs plus nulls cover about 1.
- **Booleans never reach the partial path.** Postgres prints `b = false` as `(NOT b)`, so a partial like `WHERE NOT deleted` is never proposed.
- `(InitPlan 1).col1` conditions are dropped whole, since pg_query can't parse them.
- `COLLATE` filters propose nothing.
- A 3,000-deep plan raises SystemStackError. Whoever parses stored plans should pass `max_nesting: false`.
- **Test gaps:** a blanket `rescue ArgumentError` stays green; sort equality columns from deeper scans; column refs inside function arguments; "skips a relation with no statistics" is weak.
- Fix the grammar slip "a Actual Rows".

- **Depends on:** 20260922-31.
- **Came from:** Both reviews of 20260922-31.
- **Design:** index-from-plan.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Treat a non-MCV literal as unknown when MCVs plus nulls cover about all rows.
- **Status:** todo

### 20260923-25. Static checker loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-26. Egress loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-27. Qualify relations loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-28. Canonical plan loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-29. Finish predicate atom extraction. Done, see BACKLOG-COMPLETE.md.

### 20260923-30. Predicate atom loose ends.

Still open from the reviews of 20260922-43:
- **Needs a decision:** NATURAL JOIN gives no atoms. When both sides are plain tables, compute the common columns, or emit a marker that can't be replaced, so the report counts it.

- **Depends on:** 20260923-29.
- **Came from:** Both reviews of 20260922-43, the second review of 20260923-29, and the builder's notes.
- **Design:** rewrite-test and vacuity-guard.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Emit a marker the report counts, and list NATURAL JOIN as unsupported in v1.
- **Status:** todo

### 20260923-31. Finish 5a-3 dedupe and filter. Done, see BACKLOG-COMPLETE.md.

### 20260923-32. Finish the governed store. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-34. Governed store loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-36. index-dedupe loose ends.

Still open from the reviews of 20260922-32 and 20260923-31:
- **Some existing indexes never count as covering.** `IndexCandidate.from_ddl` returns nil for `ON ONLY` indexes on a partitioned parent, for any `WITH (...)` index, and for `NULLS NOT DISTINCT` unique indexes. A candidate identical to one is tested as new, and negative-result won't report it as a duplicate.
- `IndexSql.normalize_predicate` should re-parse its output. `'x'::mytype(lower('bob'))` is stored as `'x'::mytype()`.
- The doc comment should say array bounds on a cast (`status::text[12345]`) aren't checked, like integer typmods.
- Dead code: `left = unwrap(node.lexpr)` in `column_comparison?`, and the unreachable `A_Const` check in `plain_type?`.

- **Depends on:** 20260923-31.
- **Came from:** The reviews of 20260922-32 and 20260923-31, and the builder's notes.
- **Design:** index-dedupe.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260923-37. Arena runner loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-38. Error filtering loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-39. Finish 5a-4 single-candidate testing. Done, see BACKLOG-COMPLETE.md.

### 20260923-40. Allowlist loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-53. Finish the enclave CLI. Done, see BACKLOG-COMPLETE.md.

### 20260923-54. Finish the 9d result comparator. Done, see BACKLOG-COMPLETE.md.

### 20260923-55. Round-trip guard for deparsed SQL. Done, see BACKLOG-COMPLETE.md.

### 20260923-56. Finish 5a-4, second pass. Done, see BACKLOG-COMPLETE.md.

### 20260923-57. Rewrite candidate check loose ends.

Still open from the reviews of 20260922-10:
- `RewriteCandidateCheck` still has its own qualify and `plain_table!`. Switch it to `Relations.check`, so its non-table rules become per-kind. Its spec expectations change with it.

- **Depends on:** 20260922-10.
- **Came from:** The reviews of 20260922-10.
- **Design:** What goes into the enclave.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260923-58. Enclave CLI loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-1. 5a-4 loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-2. Pin hidden_differences? for every row in a tie group. Done, see BACKLOG-COMPLETE.md.

### 20260924-3. Intake loose ends.

Still open from the reviews of 20260922-13:
- **Orphaned partial runs.** SIGKILL, an OOM kill, or SIGXFSZ during intake can leave a 0700 run directory holding production literals, and print no run ID. Tiny signal windows around `Store.create` and after `done` do the same. Add a sweeper, such as `quaacks teardown --orphans`, or have intake sweep old runs with no finished marker.
- **The query isn't checked against the plan.** A SELECT query with an UPDATE's plan is accepted. Compare the relations and statement type.

- **Depends on:** 20260922-13.
- **Came from:** Both reviews of 20260922-13.
- **Design:** input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-4. Parenthesize what pg_query deparses wrong. Done, see BACKLOG-COMPLETE.md.

### 20260924-5. Rerun 9d comparisons with the fixture loaded in reverse. Done, see BACKLOG-COMPLETE.md.

### 20260924-6. Narrow the fixture-compare fail-closed rule for top-N queries.

Any `ORDER BY ... LIMIT` whose output includes a type left out of the tiebreaker (json, jsonb, xml, citext, hstore, PostGIS, interval, numeric[], and composites of those) is refused, even when the sort key is unique. That refuses every candidate for common top-N queries over such tables, and those are prime rewrite targets. Options: rerun both queries without their LIMIT and OFFSET, and refuse only on a real hidden tie. Or add `::text` sort keys for left-out columns.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **Design:** fixture-compare.
- **Status:** todo

### 20260924-7. fixture-compare comparator loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-8. Burndown loose ends.

**Needs a decision,** from the second review of 20260922-61:
- Refuse misuse, such as calling `record_dedupe` twice on the same Dedupe. (The `since` part is settled: 20261001-20 has index-test derive its starting count from the stored dedupe state.)
- Tie `record_single_candidate_test`'s report to the Dedupe's proposals.
- index-test's `unrenderable` refusal is counted as `hypopg_refused`.

- **Depends on:** 20260922-61.
- **Came from:** Both reviews of 20260922-61.
- **Design:** burndown.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Build all three.
- **Status:** todo

### 20260924-9. Load-order loose ends.

**Needs a decision,** from the reviews of 20260924-5:
- A third load order, such as rotating each table's run by one. It would catch a tie pick exactly in the middle of an odd-sized group, and a rare top-N heapsort pick, which both orders agree on today.
- Self-referencing foreign keys always fail the reverse load, as `reverse_load_failed`, which discards every candidate for tree-shaped tables. Keep such tables in forward order, or reverse them level by level.

- **Depends on:** 20260924-5.
- **Came from:** Both reviews of 20260924-5.
- **Design:** fixture-compare.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Fix self-referencing FKs (reverse them level by level, or keep such tables in forward order, whichever is sound) and add a third load order.
- **Status:** todo

### 20260924-10. index-rank loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-11. Finish 3g redaction. Done, see BACKLOG-COMPLETE.md.

### 20260924-12. Finish 3h clock anchoring. Done, see BACKLOG-COMPLETE.md.

### 20260924-13. Leak-test helper loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-14. LLM client loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-15. 3h clock anchoring loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-16. Finish 3g redaction, part two. Done, see BACKLOG-COMPLETE.md.

### 20260924-17. Teardown loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-18. Governed store loose ends, part two. Done, see BACKLOG-COMPLETE.md.

### 20260924-19. 3a relations loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-20. Driver transport loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-21. 9d Shape deparses without the round-trip guard. Done, see BACKLOG-COMPLETE.md.

### 20260924-22. 3b schema dump loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-23. Deparse loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-24. Production inventory loose ends.

Still open from the build and reviews of 20260922-16:
- No `statement_timeout` on the production connection, so a host that silently drops packets hangs the step. The operator's `PGCONNECT_TIMEOUT` covers only the connect.
- The recorded "production values" are the operator's session values, including `PGOPTIONS` and `ALTER ROLE ... SET`. Fix the DESIGN.md wording, or connect with `options: ""`.
- Qualify `current_setting` and `json_array_elements_text` with `pg_catalog.`, so a role's search_path can't shadow them.
- `"memory_command": null` counts as not configured, but DESIGN.md says it's `bad_config`. There's no upper bound on the memory size.
- A background child holding stdout makes the memory command wait out its timeout, and a `setsid` child escapes the process-group kill.
- `ProductionServer` prints NOTICE lines into the rake output.
- **Surviving mutants:** config's invalid UTF-8 handling; memory's double space before the unit, `reap`, TIMEOUT and MAX_OUTPUT values, and spawn failure; inventory closing its connection; the step's hardcoded `major_version`.

- **Depends on:** 20260922-16.
- **Came from:** The build and reviews of 20260922-16.
- **Design:** inventory.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-25. redact loose ends.

Still open from the reviews of 20260922-23, 20260924-11, and 20260924-16:
- **Decided, not built:** a plan more than about 48 levels deep can't go out through egress. Refuse it with a clear rule, and list it as unsupported in v1.
- Placeholders of different types can collide on one plan literal. With `$1 = 101` and `$2 = B'101'`, `X'05'` matches 101. No value leaks, but `$n` and the row annotation can be wrong. Prefer the candidate whose type matches the literal's cast.
- Expressions Postgres treats as equal but that are written differently get separate placeholders. They fail closed as `prepare_failed`.
- Date and timestamp normalization for row annotations, through the racetrack.
- Masks on planner-made TRUE and FALSE inflate the masked count.
- The 42P18 retry depends on English `lc_messages`, and preparing in a failed transaction gives 3B001, not 25P02.
- PredicateAtoms should use redact's numbering. SingleCandidateTest and ArenaRunner should adopt Binding, so types get declared through PREPARE.

- **Depends on:** 20260924-16.
- **Came from:** The reviews of 20260922-23, 20260924-11, and 20260924-16.
- **Design:** redact.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-26. statistics loose ends.

Still open from the build and reviews of 20260922-19:
- pg_stats and pg_stats_ext silently hide columns the operator can't SELECT, so a role with limited privileges gets missing statistics with no error. Detect it, and refuse or record it.
- Values and names aren't converted to UTF-8, unlike SchemaDump. A non-UTF-8 database with non-ASCII values may be refused at the store write.
- The pg_stats inherited-filter mutant is killed only by luck, since row order decides which duplicate wins.
- A column type whose array delimiter isn't a comma, such as `box`, makes PgArray raise and abort statistics. List it as unsupported in v1, or skip it.

- **Depends on:** 20260922-19.
- **Came from:** The build and reviews of 20260922-19.
- **Design:** statistics.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-27. 3f classification loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-28. literals loose ends.

Still open from the build and reviews of 20260922-21:
- Django date filters get no worst-case or typical value. psycopg2 writes `'...'::timestamptz`, `'...'::date`, and `'{..}'::bigint[]`, which redact turns into cast placeholders, and literals always falls back on those. Handle a cast placeholder whose cast matches the column's type.
- The boolean `t`/`f` check at `literal_set.rb:326` survives mutation. Pin it with a planted bad value, or drop it.

- **Depends on:** 20260922-21.
- **Came from:** The build and reviews of 20260922-21.
- **Design:** literals.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-29. Run server check loose ends.

Still open from the build and reviews of 20260922-25:
- Per-tablespace `random_page_cost` and `seq_page_cost` aren't checked. Record production's tablespace spcoptions in inventory, then compare them.
- `shared_preload_libraries` that change plans, such as pg_hint_plan, aren't compared.
- PGTZ and PGDATESTYLE in the operator's environment change both sessions' TimeZone and DateStyle, so the check compares session values, not server values.
- The debug_parallel_query test goes through the recorded-value path, not the boot_val path its name suggests.

- **Depends on:** 20260922-25.
- **Came from:** The build and reviews of 20260922-25.
- **Design:** inventory and run-server.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-30. Include extensions in the 3b schema dump. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20260925-1. Index DDL check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-2. Insert check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-3. Plan gate loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-4. 5a-5 generator three: the LLM loop. Done, see BACKLOG-COMPLETE.md.

### 20260925-5. Generator three piece one loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-6. Enclave subcommand for the mechanical half of step 5. Done, see BACKLOG-COMPLETE.md.

### 20260925-7. Enclave subcommand: `quaacks run-server` (step 4). Done, see BACKLOG-COMPLETE.md.

### 20260925-8. Enclave subcommand: `quaacks qualify` (step 1 qualification and 3a relations). Done, see BACKLOG-COMPLETE.md.

### 20260925-9. Enclave subcommand: `quaacks schema-dump` (3b). Done, see BACKLOG-COMPLETE.md.

### 20260925-10. Enclave subcommand: `quaacks statistics` (3c). Done, see BACKLOG-COMPLETE.md.

### 20260925-11. Enclave subcommand: `quaacks volatility` (3d). Done, see BACKLOG-COMPLETE.md.

### 20260925-12. Enclave subcommand: `quaacks literals` (3e). Done, see BACKLOG-COMPLETE.md.

### 20260925-13. Enclave subcommand: `quaacks classify` (3f). Done, see BACKLOG-COMPLETE.md.

### 20260925-14. Enclave subcommand: `quaacks redact` (3g). Done, see BACKLOG-COMPLETE.md.

### 20260925-15. Enclave subcommand: `quaacks anchor` (3h). Done, see BACKLOG-COMPLETE.md.

### 20260925-16. Enclave subcommand: `quaacks racetrack-setup` (4a). Done, see BACKLOG-COMPLETE.md.

### 20260925-17. Possible flake in the run-server success test. Done, see BACKLOG-COMPLETE.md.

### 20260925-18. Qualify loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-19. Schema-dump loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-20. Statistics step: test the read failure. Done, see BACKLOG-COMPLETE.md.

### 20260925-21. Name the function in a 3d refusal. Done, see BACKLOG-COMPLETE.md.

### 20260925-22. Name the missing input when a step's store entry is absent. Done, see BACKLOG-COMPLETE.md.

### 20260925-23. Anchor step loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-24. Index-search loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-1. Driver finds the jump server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-2. Build and record the run server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-3. Generator three follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20260928-1. `quaack setup`: one command for steps 2 through 4. Done, see BACKLOG-COMPLETE.md.

### 20260928-2. `quaack start --captured-at`.

`quaacks intake` takes `--captured-at <time>` (DESIGN.md's input, clock-anchor), but `quaack start` accepts exactly `--server`, `--query`, and `--plan`, so an operator starting from the laptop can't pass it. The clock is then anchored at intake time, which is wrong for a plan captured earlier. Accept an optional `--captured-at` and pass it through.

- **Depends on:** None.
- **Came from:** Writing the user-facing README (2026-09-28).
- **Design:** input, clock-anchor.
- **Status:** todo

### 20260928-3. LLM provider seam, configuration, and Anthropic auth without a key. Done, see BACKLOG-COMPLETE.md.

### 20260928-4. OpenAI-compatible LLM adapter. Done, see BACKLOG-COMPLETE.md.

### 20260928-5. LLM provider seam loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260928-6. LLM provider seam loose ends, part two. Done, see BACKLOG-COMPLETE.md.

### 20260929-1. OpenAI-compatible adapter loose ends.

These are minor findings from the build and round-one review of 20260928-4:
- **Unverified provider facts.** The build couldn't reach any provider's docs (blocked by network policy), so these are unchecked:
  - which providers enforce JSON schemas today, one of 20260928-4's own bullets;
  - the base URLs and example models in README.md's provider table;
  - whether Gemini's compatible endpoint, Ollama, and OpenRouter accept `max_completion_tokens` (add a fallback to `max_tokens` if one doesn't).

  Check them with docs access or against live providers (`script/llm_smoke.rb`). Until then, soften the README's wording: "check your provider's docs; these were current when written".
- **Reasoning models run short.** They spend `max_completion_tokens` on reasoning too, and the callers send 4000 or 8000. A long think ends with finish reason `length` and empty content, which is `llm_bad_response`. Pick a non-reasoning example model for OpenAI, or document the headroom they need, or add a per-provider token multiplier or a `reasoning_effort` setting.
- **The fallback fires on any 400 or 422 while a schema is sent.** An unrelated 400, such as context too long, costs one extra counted attempt. A provider that answers a schema-validation miss with a 400 (Groq's `json_validate_failed`, from memory) turns schema mode off for the whole run. Narrow the trigger to errors whose `param` is `response_format` (the gem exposes `error.param`), or document it.
- **`script/llm_smoke.rb`'s Groq example contradicts itself.** It sets `GROQ_API_KEY` with no `api_key_env`, so the key is read from `OPENAI_API_KEY` and the example fails `llm_auth`. Show `OPENAI_API_KEY=$GROQ_API_KEY`, or a driver.json with `api_key_env`.
- **The shared example "keeps the API key out of its error messages" is weak for OpenAI.** FakeOpenAI's error bodies never echo the key. Plant the sentinel key in the scripted 401 body.
- **No openai_compatible spec for the CLI's default builder.** The case in `cli_run_spec.rb` under "with the real client builder" still builds with FakeLLM. See 20260928-6.
- **The openai gem sends `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, and `OPENAI_CUSTOM_HEADERS` to any `base_url`,** Groq included. The README only warns about it. Stop passing them to non-OpenAI base URLs.
- **`OPENAI_BASE_URL` is honored when the `llm` block has no `base_url`,** matching the gem. Decide whether that's wanted.
- **`reask?` checks `error.rule == "llm_bad_response"`,** which is always true there. Drop the check or explain it.
- **Untested: the `text &&` guard in `reask?`** (`client.rb`). Dropping it keeps every spec green, and then a schema ask that the adapter itself failed (cut short, a refusal, or empty) re-asks with a nil assistant turn and costs an extra call. Add a spec: with a schema, `finish_reason: "length"` gives `llm_bad_response` with one counted call.
- **Untested: how narrow the fallback trigger is.** Widening `rescue *REJECTED` to every `APIStatusError` keeps every spec green, and then a schema ask whose 429s or 5xxs outlast the retries would fire the fallback and could turn schema mode off for the run. Add a spec: with a schema, three 429s give `llm_rate_limited` with three calls, each carrying `response_format`.
- **Untested: the adapter's `::OpenAI::Errors::Error` rescue branch.** Plant a body that makes the gem raise `ConversionError`, and assert `llm_bad_response` with a nil cause. Or drop the branch if no realistic body reaches it.
- **`choices: null` gives a different detail** ("couldn't be read as a message") than a missing `choices` ("had no choices"), and no spec covers the null case. Both are a clean `llm_bad_response`.
- **A `base_url` ending in `/chat/completions` fails with a confusing 404.** The `openai` gem appends `/chat/completions` itself, so the user's first live run went to `.../openai/v1/chat/completions/chat/completions` and failed `llm_bad_request`. Provider docs usually show the full endpoint URL, so this mistake will be common. Refuse it in `LLM.settings` with a usage error naming `base_url` (for example, "base_url must be the API root, such as https://api.groq.com/openai/v1, without /chat/completions"), or strip the suffix. `script/llm_smoke.rb` could also print the rule and message instead of a stack trace.
- **Stray lockfile line.** 20260928-4's Gemfile.lock change also added a `bundler` checksum line. Drop it, or keep it knowingly.

- **Depends on:** 20260928-4.
- **Came from:** The build report and both reviews of 20260928-4.
- **Design:** Where QUAACK runs.
- **Status:** todo

### 20260929-3. `quaack deploy`: show progress, and diagnose PATH. Done, see BACKLOG-COMPLETE.md.

### 20260929-4. Say why driver.json is bad. Done, see BACKLOG-COMPLETE.md.

### 20260929-5. Say why intake can't read the query or plan. Done, see BACKLOG-COMPLETE.md.

### 20260929-6. `quaack deploy` diagnosis: close test gaps and fix wording. Done, see BACKLOG-COMPLETE.md.

### 20260929-7. Say which clients `run_server_other_clients` saw. Done, see BACKLOG-COMPLETE.md.

### 20260929-8. `run_server_other_clients` may count QUAACK's own session. Done, see BACKLOG-COMPLETE.md.

### 20260929-9. The full check fails on a Mac whose pg_dump is older than 18. Done, see BACKLOG-COMPLETE.md.

### 20260929-10. The leak check sees BUNDLER_VERSION in a script's environment. Done, see BACKLOG-COMPLETE.md.

### 20260929-11. `run_server_other_clients` clients list: minor test gaps. Done, see BACKLOG-COMPLETE.md.

### 20260929-12. `clients` shape checks: round-two test gaps. Done, see BACKLOG-COMPLETE.md.

### 20260929-13. Build the prompt-pack database once per spec process. Done, see BACKLOG-COMPLETE.md.

### 20260929-14. pg_dump finder: minor findings.

Minor findings from the first review of 20260929-9.

- When no pg_dump of the server's major is found, three examples fail, not one: the replay gate, `TestPgDump.bin`'s own example, and the `PromptPack.with_env` example. CLAUDE.md says the replay spec "fails once". Gate the two finder examples the same way, or reword CLAUDE.md.
- Three pieces of code have no automated test: the load-time gate in `spec/pipeline_replay_spec.rb`, which was only checked by hand; `E2ERun.with_env`'s PATH change; and `TestPgDump.version`'s exit-status check. Ignoring the exit status survives the specs.
- If `QUAACK_TEST_PG_BIN` holds a pg_dump of the wrong major, the harness quietly falls back to the Homebrew keg. That matches the user's answer, "checks first", and the not-found message lists what each directory held. Consider saying so when it happens.

- **Depends on:** 20260929-9.
- **Came from:** Review of 20260929-9, round one.
- **Design:** none. Test harness only.
- **Status:** todo

### 20260929-15. `TestPgDump.server_major`'s regex is under-tested. Done, see BACKLOG-COMPLETE.md.

### 20260929-16. PgBouncer support: minor findings.

Minor findings from the review of 20260929-8.

- DESIGN.md's run-server says a pooler must hold no idle server backends when the check runs, but not how the operator gets there. After an earlier run, or a psql session through the pooler, PgBouncer can hold several idle backends. Every one but the one QUAACK reuses then fails `run_server_other_clients`. Say how to clear them: PgBouncer's `RECONNECT` or `KILL`, waiting out `server_idle_timeout`, or `pg_terminate_backend` on the named pids. Also put this in the README's troubleshooting.
- `TestPostgres::Server#pgbouncer_port`: if PgBouncer's startup fails partway, such as on the readiness timeout, the next call starts `pgbouncer -d` again, and probably fails with a confusing error because one is already running.

- **Depends on:** 20260929-8.
- **Came from:** Review of 20260929-8, round one.
- **Design:** run-server.
- **Status:** todo

### 20260929-17. Test the prompt-pack template's recovery from a failed build. Done, see BACKLOG-COMPLETE.md.

### 20260929-18. The prompt pack's leak check flags LLM replies that invent a sentinel date.

A hand run of `script/prompt_pack/run.rb orm_join group_having` finished, then `check_leaks` aborted. It found the `min_quantity_since` sentinel date, `2024-02-08`, in these three committed replies:

- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-4/reply-claude-3.md`
- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-5/reply-gemini-3.md`
- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-9/reply-claude-3.md`

It's a false positive. No prompt in the corpus holds that date. The models generated runs of consecutive dates, such as 2024-02-01 to 2024-02-13, that happen to cross it. Still, the script can't finish on main today. Pick a fix: move the sentinel dates somewhere a model won't wander into, such as a far-off year, or scan only the prompts, since replies can't leak what the prompts never held.

- **Depends on:** nothing open.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness and prompt pack only.
- **Status:** todo

### 20260929-19. Schema dump selects `pg_catalog` when an extension lives there. Done, see BACKLOG-COMPLETE.md.

### 20260929-21. The full schema dump misses schemas that FK parent tables live in. Done, see BACKLOG-COMPLETE.md.

### 20260929-22. The subset dump takes a query table in a system schema.

With a `pg_toast` table as a query relation, the subset's `--table` dump fails with `pg_dump_failed`. With `pg_catalog.pg_namespace`, the subset probably gets catalog DDL. `Relations.check` may let catalog tables through, since they're relkind `r`. A query on a system catalog isn't something QUAACK can tune, so refuse it cleanly, with a rule such as `system_relation`, early in qualify. List it as unsupported in v1.

- Also from the 20260929-19 review: suppose no `public` schema exists, and every query relation and extension is in a system schema. Then the full dump gets no `--schema` flags, and pg_dump dumps every schema. Refusing system relations fixes this too.

- **Depends on:** 20260929-19.
- **Came from:** The build and review of 20260929-19.
- **Design:** qualify, schema-dump.
- **Status:** todo

### 20260929-23. Pin the underscore in `SchemaDump.system_schema?`. Done, see BACKLOG-COMPLETE.md.

### 20260929-24. Scrub every Bundler variable, not a named list. Done, see BACKLOG-COMPLETE.md.

### 20260929-25. Pin the guard on EXTRACT field lowercasing in the query redaction. Done, see BACKLOG-COMPLETE.md.

### 20260929-26. The full dump misses objects in other schemas that dumped objects depend on.

Found while building 20260929-21. `pg_dump --schema=X` dumps only the objects in X. So anything a dumped object depends on in another schema is missing, and arena's load fails with `arena_dump_load_failed`. The builder confirmed each case below with a throwaway spec:

1. **A sibling FK.** A table in a dumped schema has an FK into a schema that isn't dumped, and it isn't in the query's FK chain. For example, `s.sib REFERENCES z.p`, with the query on `s.q`. `--schema=s` brings in all of `s`, `s.sib` included, but not `z`. The ancestor schemas 20260929-21 adds come in whole too, so their other tables can do the same. This is the case most likely to hit the user's Canvas shard schemas.
2. **A column type or domain in another schema,** such as `CREATE DOMAIN types.pos ...` used by `s.q`.
3. **A column default that calls a function in another schema,** such as `DEFAULT util.one()`.
4. **A default that uses a sequence in another schema,** such as `DEFAULT nextval('seqs.ids')`.

Check constraints and triggers likely have the same gaps as items 2 to 4.

- **Needs a decision:** close the dumped schema set over dependencies, or refuse cleanly and list it as unsupported in v1. Closing over could mean the FKs of every table in the dumped schemas, or walking `pg_depend` from the dumped objects to the schemas they depend on. It could also pull in large unrelated schemas.

- **Depends on:** 20260929-21.
- **Came from:** The build of 20260929-21.
- **Design:** schema-dump, racetrack-setup.
- **Decided by the user (2026-10-05):** Refuse cleanly, and list it as unsupported in v1.
- **Status:** todo

### 20260929-27. LLM seam: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20260929-28. Arena runner cancel tests: pin the start time, and bound the wait. Done, see BACKLOG-COMPLETE.md.

### 20260929-29. An operator's cancel shouldn't count as disproving a rewrite.

In Counterexamples (`counterexamples.rb:89-91`) and ScenarioTests (`scenario_tests.rb`), a candidate query that fails with `statement_canceled` is recorded as a disproof, `match` false, just like a timeout. It errs on the safe side, since it can only reject a rewrite. But a cancel from someone else says nothing about the candidate: a valid rewrite is silently lost, and the report says "disproved in rewrite-test ... (rule statement_canceled)". RunDiscipline raises on a cancel that isn't its timeout. The arena side should probably do the same, and end the step with an environment error instead of recording a verdict.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** rewrite-test and counterexamples.
- **Status:** todo

### 20260929-30. Step 8 pruning doesn't test its reliance on HypoPG oid maps. Done, see BACKLOG-COMPLETE.md.

### 20260930-1. Teardown: capture the run's error exactly. Done, see BACKLOG-COMPLETE.md.

### 20260930-2. Pin that `system_schema?` matches `pg_` only as a prefix. Done, see BACKLOG-COMPLETE.md.

### 20260930-3. Anthropic credential checks: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20260930-4. An assertion in index_candidate_expression_spec passes a value as its failure message. Done, see BACKLOG-COMPLETE.md.

### 20260930-5. Clean up the operator-cancel test's canceler thread. Done, see BACKLOG-COMPLETE.md.

### 20260930-6. `clients` shape checks: minor findings, round three.

Minor findings from the review of 20260929-12:

- The 24-hour-clock test runs `BACKEND_START_SQL` alone, not `OTHER_CLIENTS_SQL`. Inlining an HH12 format into the query in place of the constant stays green before noon UTC. Assert `OTHER_CLIENTS_SQL.include?(BACKEND_START_SQL)`, or run the query itself against a temp view `pg_temp.pg_stat_activity` with a pinned afternoon `backend_start`.
- In enclave/spec/error_filter_spec.rb, the subclass cases' `to_json` override never runs, because egress's plain-data check rejects a subclass first. The comment saying it "writes itself out as a sentinel" is misleading. Fix the comment.
- Watch for a flake in "names the oldest other client first" (run_server_check_postgres_spec.rb). It failed once in one review run and passed on every rerun. Look into it only if it recurs.

- **Depends on:** 20260929-12.
- **Came from:** Review of 20260929-12, round one.
- **Design:** run-server.
- **Status:** todo

### 20260930-7. The OpenAI-compatible adapter says "isn't set" for an empty key variable. Done, see BACKLOG-COMPLETE.md.

### 20260930-8. Anthropic credential docs and one spec line: tidy. Done, see BACKLOG-COMPLETE.md.

### 20260930-9. Qualify the catalog names the run server check reads. Done, see BACKLOG-COMPLETE.md.

### 20260930-10. Drop or explain the `BUNDLE_SOMETHING` plant in isolated_install_spec. Done, see BACKLOG-COMPLETE.md.

### 20260930-11. A `bedrock` LLM provider: Anthropic models on AWS Bedrock. Done, see BACKLOG-COMPLETE.md.

### 20260930-12. Anthropic credential wording nits.

Minor findings from the review of 20260930-8:

- In DESIGN.md's LLM client section, "So an empty value there is `llm_auth`" leans on "there" to mean the first of the two variables that's set. Say it outright.
- The class comment in driver/lib/quaack/driver/llm/anthropic_adapter.rb still uses semicolons ("wins; then ... not empty; else ..."). Split it into sentences.

- **Depends on:** 20260930-8.
- **Came from:** Review of 20260930-8, round one.
- **Design:** LLM client.
- **Status:** todo

### 20260930-13. Run server check shadowing: one untested qualification, and operators.

Minor findings from the review of 20260930-9:

- In `RunServerCheck::PLANNER_SQL`, the second `pg_catalog.pg_settings_get_flags(name)`, the one in the WHERE clause, has no test that fails when it's unqualified. Under `search_path = public, pg_catalog`, a `public.pg_settings_get_flags` returning `'{}'` drops every EXPLAIN-flagged setting outside Query Tuning. A run server with `SET effective_io_concurrency = 7` then passes when it should fail with `run_server_guc_mismatch`. Add that example to the "a search_path whose public schema shadows the catalog" group. The reviewer confirmed it goes red with the qualifier removed.
- Operators (`=`, `<>`, `LIKE`, `= ANY`) in the check's SQL aren't qualified. Exploiting that needs a deliberately built operator in `public`, and a blunt one breaks the planner check first. List it as unsupported in v1 in DESIGN.md's run-server, or qualify with `OPERATOR(pg_catalog.=)`.

- **Depends on:** 20260930-9.
- **Came from:** Review of 20260930-9, round one.
- **Design:** run-server.
- **Status:** todo

### 20260930-14. Unqualified catalog names elsewhere in the enclave.

The 20260930-9 builder listed catalog relations and functions the enclave still reads without `pg_catalog.`, outside run-server. Each can be shadowed by the same search_path setup. Qualify them, or decide per step which are safe, such as ones on the arena, which QUAACK builds itself.

- arena_runner/sequences.rb: `pg_sequence`, `pg_get_serial_sequence()`.
- arena_schema.rb, arena_schema/domain_checks.rb, arena_schema/unique_indexes.rb: `format_type()`, `pg_get_expr()`, `pg_attribute`, `pg_attrdef`, `unnest()`, `pg_get_constraintdef()`, `pg_constraint`, `pg_class`, `pg_namespace`, `to_regclass()`, `pg_type`, `pg_get_indexdef()`, `generate_series()`, `pg_depend`, `pg_proc`, `pg_index`.
- assumption_check.rb, from_functions.rb, relation_qualifier.rb, steps/rewrite_check.rb: `unnest()`.
- index_build.rb: `pg_relation_size()`, `pg_class`, `pg_namespace`, `pg_index`, `unnest()`.
- measurement.rb: `pg_prepared_statements`.
- planner_statistics/catalog.rb: `pg_stats`. This one reads production, so it matters most.
- racetrack.rb: `count(*)`. redaction/binding.rb: `json_agg()`.
- result_comparison/tiebreaker.rb, scenarios/ties.rb, scenarios/values.rb, value_pools.rb: `pg_type`, `pg_range`, `pg_attribute`, `pg_collation`, `pg_enum`, `count()`.
- schema_dump.rb: `pg_database`, `current_database()`, `current_setting()`. These also read production.
- single_candidate_test.rb: the hypopg functions live in the extension's schema, not `pg_catalog`, so they need the extension's schema, not `pg_catalog.`.
- steps/index_search.rb: `format_type()`.

- **Depends on:** 20260930-9.
- **Came from:** The build of 20260930-9.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261001-14. Unreadable `~/.quaack/runs` reads as an unknown run ID.

Found by the build of 20260929-27. With `~/.quaack` or `~/.quaack/runs` unreadable (mode 000), `Runs#host` treats the run record as missing, so `quaack run` says "unknown run ID" instead of saying it can't read the record. Refuse an existing but unreadable path the way `DriverConfig.read` now does, with a message that names no absolute path.

- **Depends on:** 20260929-27.
- **Came from:** The build of 20260929-27.
- **Design:** Where QUAACK runs.
- **Status:** todo

### 20261001-15. DriverConfig: minor findings.

Minor findings from the review of 20260929-27:

- The not-a-regular-file check in `DriverConfig#there?` (driver_config.rb:35) is untested. A directory driver.json is already refused through EISDIR, so replacing the check with `true` stays green. It matters for a FIFO, where `File.read` would block. Add a FIFO example, or drop the check.
- In cli_run_spec.rb's unreadable-directory example, if the `mkdir_p` line raised, `locked` would be nil and the `ensure`'s `File.chmod(0o700, nil)` would hide the real error with a TypeError. Guard the chmod.
- A dangling driver.json symlink counts as no config, since `File.stat` follows it and gets ENOENT. A user whose symlink points at a moved file silently gets the defaults. Consider refusing a symlink whose target is missing.

- **Depends on:** 20260929-27.
- **Came from:** Review of 20260929-27, round one.
- **Design:** Where QUAACK runs.
- **Status:** todo

### 20261001-16. Bedrock provider: minor findings.

Minor findings from the review of 20260930-11:

- Keys for another provider break a one-run override. `check_applies` (llm.rb:267) checks keys against the provider after `QUAACK_LLM_PROVIDER` overrides it, so `QUAACK_LLM_PROVIDER=anthropic` against a bedrock block fails naming `aws_region`. The user's answer, 2026-10-01: loosen it. Ignore keys that belong to a provider other than the one in effect, so the override works for one run.
- A bad `AWS_REGION` or `AWS_DEFAULT_REGION` isn't checked (bedrock_adapter.rb:398). In bearer mode `"us east 1"` raises `URI::InvalidURIError` out of the client build, and `quaack run` crashes with a backtrace. In SigV4 mode the same typo reads as `llm_auth: the AWS credentials couldn't be loaded`. Apply the `aws_region` check to the variables, and make a bad value a usage error naming the variable, not the value.
- The region pattern (llm.rb:219) rejects `eusc-de-east-1`, the AWS European Sovereign Cloud region, since it requires a two-letter prefix. Allow `[a-z]{2,4}`.
- The "spec-time network guard, for Bedrock" describe (bedrock_adapter_spec.rb:317-340) builds `Anthropic::BedrockClient` outside `without_aws_credentials`, so it reads the developer's real `~/.aws/config` and `~/.aws/credentials`. It's harmless today. Wrap it.
- Mutation `credentials&.set?` to `credentials` (bedrock_adapter.rb:408) survives: no spec covers the chain returning credentials that aren't set, such as an empty key in a profile. Add one, or drop `.set?`.
- DESIGN.md's llm block paragraph still says the provider is "`anthropic` or `openai_compatible`", which contradicts the bedrock paragraph after it. Add bedrock to the list.
- README nit: the gem also reads `ANTHROPIC_BEDROCK_BASE_URL` when no `base_url` is set. Mention it, or say QUAACK ignores it.

- **Depends on:** 20260930-11.
- **Came from:** Review of 20260930-11, round one.
- **Design:** LLM client.
- **Status:** todo

### 20261001-17. Report payload: send what a legible report needs. Done, see BACKLOG-COMPLETE.md.

### 20261001-18. Report: readable HTML. Done, see BACKLOG-COMPLETE.md.

### 20261001-19. Record the rewrite stages in the burndown. Done, see BACKLOG-COMPLETE.md.

### 20261001-20. Record the index stages in the burndown. Done, see BACKLOG-COMPLETE.md.

### 20261001-21. Mechanical rewrite rules. Done, see BACKLOG-COMPLETE.md.

### 20261001-22. 6c: the rule generator, and `key_in_self_join`. Done, see BACKLOG-COMPLETE.md.

### 20261001-23. 6c: run the rules from `quaack run`, and count them. Done, see BACKLOG-COMPLETE.md.

### 20261001-24. 6c rule: `or_to_union`. Done, see BACKLOG-COMPLETE.md.

### 20261001-25. 6c rule: `not_in_to_not_exists`. Done, see BACKLOG-COMPLETE.md.

### 20261001-26. 6c rule: `distinct_join_to_exists`. Done, see BACKLOG-COMPLETE.md.

### 20261001-27. rewrite-rules rule: `unused_join_removal`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261001-28. Tell the LLM what the rules already made.

llm-rewrites' payload carries the rule-made rewrites' SQL, and the prompt says not to repeat them, as llm-index-ideas does with `mechanical_results`.

- **Depends on:** 20261001-23.
- **Came from:** 20261001-21.
- **Design:** llm-rewrites, rewrite-rules.
- **Status:** todo

### 20261001-29. Renumber step 6 in running order, and give the rules table examples. Dropped, see BACKLOG-COMPLETE.md.

### 20261002-1. Rule generator: minor findings.

Minor findings from both reviews of 20261001-22:

- **Legacy inheritance.** `AssumptionCheck`'s `unique` ignores `INHERITS` children, whose rows a parent's key doesn't cover, so `key_in_self_join` can drop rows on such a parent. Make `unique` unmet when the table has non-partition children, and list it in DESIGN.md as unsupported. Partitioned tables are fine.
- **Test gaps where a wrong change stays green:** no firing example on a non-public schema (`key_in_self_join.rb:51`, hardcoding `public` survives); no column-free arm predicate such as Rails's `1=0` (`arm.rb:99`); no IN inside a nested AND (`tree.rb:52`); the single-column guard (`arm.rb:79`) and single-statement guard (`tree.rb:37`); the marker's `over_cap` (`steps/rewrite_rules.rb:48`).
- The rules' exemption from `too_many` can't be observed, since the generator's cap and `RewriteCheck::MAX` are both 5. Share one constant.
- A rule file can't be required alone: it uses `RewriteRules::Rewrite`, defined in the file that requires it. Move `Rewrite` to its own file.
- `Tree::Names`'s comment says it avoids every name in the tree. It collects only names in column references.
- A query with three or more matching INs never gets its fully rewritten form, given depth two and the cap of five.
- Wider coverage for later: nested SELECTs and derived tables, unqualified columns, an IN in a join's ON, `= ANY (subquery)`.

- **Depends on:** 20261001-22.
- **Came from:** The build and both reviews of 20261001-22.
- **Design:** assumption-check, rewrite-rules.
- **Status:** todo

### 20261002-2. Running the rules: minor findings.

Minor findings from the build and both reviews of 20261001-23:

- **False rule bugs from rewrite-test and counterexamples.** `RuleBugs.disproved_by` counts any failed `rewrite_tested_<n>` whose rule isn't `discarded`. ScenarioTests also fails a rewrite with `unsupported_order` (a WITH TIES original, for one) and with ArenaRunner's errors: `query_failed`, `statement_timeout`, `statement_canceled`, `begin_failed`. None compared results. Use an allowlist, as result-comparison's `MISMATCHES` does. counterexamples can't be told apart yet: `rewrite_round_<n>` doesn't store the round's rule, and `match` is false for `query_failed` too. Store it.
- **Postgres 18 removes the one-arm self-join itself,** so `key_in_self_join`'s rewrite of `t.id IN (SELECT t2.id FROM t t2 WHERE P)` plans like the original and plan-pruning prunes it. DESIGN.md's rewrite-rules' table says each rule is something the planner doesn't do. Say which cases still matter (the `UNION ALL` arms, and servers before 18).
- `rewrite-check` has the double-store window that rewrite-rules closed: a call that dies after storing rewrites and before its marker stores them again on rerun.
- A rule-made rewrite that fails the checks counts in rewrite-rules' `failed_checks` and in plan-pruning's drops, so rewrite-rules' out isn't plan-pruning's in. Settle it with 20261001-19.
- A store where llm-rewrites ran before rewrite-rules existed gets its rule rewrites numbered after llm-rewrites'. DESIGN.md's rewrite-rules says "before llm-rewrites'" without the exception.
- `CounterexampleStage` asks `status` again right after `RewriteStage` did.
- Test gaps where a wrong change stays green: `rule_bugs` when nothing beat the original (`report_payload.rb:74`); "shows the rewrite-rules row first" only checks against rewrite-test (`report_spec.rb:188`); a rerun with two or more stored rule rewrites, or after a call that stored only some; the rewrite-rules and plan-pruning records going in one write; the rewrite-test disproof line's source label (`report.rb:171`).
- The spec helper `compared` builds result-comparison's entry by hand. Call `ResultComparison.entry`.
- An empty `rules` renders "made by QUAACK's rules " with nothing after it (`report.rb:113`).
- In a negative result, a rule-made rewrite that plan-pruning pruned now reads "(made by QUAACK's rule ...): disproved in rewrite-test ... (rule discarded)". 20261001-17 fixes the root cause.

- **Depends on:** 20261001-23.
- **Came from:** The build and both reviews of 20261001-23.
- **Design:** rewrite-rules, rewrite-test, counterexamples, report, burndown.
- **Status:** todo

### 20261002-15. 6c rule: `polymorphic_key_copy`, checked against the data. Done, see BACKLOG-COMPLETE.md.

### 20261002-16. `distinct_join_to_exists`: handle what Rails sends. Done, see BACKLOG-COMPLETE.md.

### 20261002-17. 6c rule: `implied_predicate_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261002-6. 6c rule: `shared_scan_cte`. Done, see BACKLOG-COMPLETE.md.

### 20261002-7. 6c rule: `transitive_predicate_copy`. Done, see BACKLOG-COMPLETE.md.

### 20261002-8. 6c rule: `cte_hoist_dedupe`. Done, see BACKLOG-COMPLETE.md.

### 20261002-9. 6c rule: `union_outer_filter_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261002-10. 6c rule: `existence_in_flip`. Done, see BACKLOG-COMPLETE.md.

### 20261002-11. 6c keeps up to ten rewrites. Done, see BACKLOG-COMPLETE.md.

### 20261002-13. Two bedrock driver specs fail on `main`. Done, see BACKLOG-COMPLETE.md.

### 20261002-14. The network guard specs read the real `~/.config/anthropic`.

`spec/network_guard_spec.rb` and `driver/spec/network_guard_spec.rb` build a real `Anthropic::Client`. Its constructor (`warn_env_shadow`, then `Anthropic::Credentials.auto_discoverable_credentials?`) reads `~/.config/anthropic/active_config` from the developer's home. Under a sandbox that blocks that path, the specs fail with `Errno::EPERM` instead of testing the guard. Specs shouldn't touch the developer's real credential files at all. Point the SDK's config discovery at an empty temp directory for these specs (whatever env var or home override the SDK honors), and check that the suite never opens anything under the real `~/.config/anthropic`. Check the other specs that build SDK clients for the same leak.

- **Depends on:** none.
- **Came from:** The 20261002-13 build, 2026-10-02.
- **Design:** Development (CLAUDE.md, the full check).
- **Status:** todo

### 20261002-3. `not_in_to_not_exists`: minor findings.

Minor findings from both reviews of 20261001-25:

- The fresh alias can collide with a table name or alias that no column mentions: `Tree::Names` collects only names in column references. The rewrite then fails to plan and plan-pruning drops it. Collect FROM names too.
- Untested lines: the fresh alias avoiding a taken name (`not_in_to_not_exists.rb:178`); `assumptions.uniq` (`:83`); `realias!` keeping column aliases (`:187`).
- A column whose type is a domain with a NOT NULL constraint doesn't count as not null, since `AssumptionCheck` reads only `pg_constraint`'s `n` and `p`. Conservative: a missed rewrite, not a wrong one.
- The rule assumes `=` gives true or false for two non-NULL values. A user-defined `=` that returns NULL breaks that. Noted in the rule's header.
- Extensions for later: row-valued NOT IN, set-operation subqueries arm by arm, NOT IN outside the top-level WHERE, `<> ALL`.

- **Depends on:** 20261001-25.
- **Came from:** The build and both reviews of 20261001-25.
- **Design:** assumption-check, rewrite-rules.
- **Status:** todo

### 20261002-4. `distinct_join_to_exists`: minor findings.

Minor findings from the build and both reviews of 20261001-26:

- No committed spec runs this rule through `quaacks rewrite-rules`; only `key_in_self_join` is covered that way. A review probe showed the path works. Add one.
- One guard in `Tree.tables?` (a FROM item with no table) is killed only by a pg_query segfault, not an assertion. Have the rule refuse a nil table explicitly.
- Composite keys are refused. Supporting them needs not-null stated per key column.
- A unique index in a different collation or operator class from its column could make DISTINCT's equality differ from the index's. An `AssumptionCheck` matter, shared with the other rules.
- Select-list expressions beside the key, and subqueries in conditions on the kept table alone, are refused though some are sound.
- `Catalog#columns` on a star with no single-column key costs a catalog query per column. One query for the table's keys would be cheaper.
- `spec/support/test_postgres.rb:245` raises when two spec processes remove the same stale container at once, which gives spurious red runs while agents run in parallel. Treat "already in progress" as success.

- **Depends on:** 20261001-26.
- **Came from:** The build and both reviews of 20261001-26.
- **Design:** assumption-check, rewrite-rules.
- **Status:** todo

### 20261002-5. `or_to_union`: minor findings.

Minor findings from both reviews of 20261001-24:

- **A clock literal outside the OR isn't anchored.** In `WHERE c.due >= 'today' AND (o.note = 'x' OR c.archived)`, the conjunct is copied into each arm, so its `$n` appears twice. `LiteralSet::Feeds` (`literal_set.rb:186`) then marks it `:shared_placeholder`, `ClockLiterals.implicit_types` finds no type, and the rewrite reads the real clock while the original reads the anchor. rewrite-test, counterexamples or result-comparison could then report a sound rewrite as a rule bug. Fix in clock-anchor: type a placeholder when every occurrence feeds a column of the same date type.
- **Guarding arms can raise.** Split arms are all evaluated, so `i.qty = 0 OR i.total / i.qty > 10 OR o.vip` raises division by zero where the original returns rows. Never wrong rows. Refuse, or note it in DESIGN.md.
- With LIMIT and no ORDER BY, the rewrite returns a different but valid set of rows. Confirm rewrite-test and counterexamples don't report that as a rule bug.
- Test gaps: the `@columns` cache key's schema part (`catalog.rb`); column names of 62 or 63 characters, which the `_1` suffix pushes past Postgres's limit (no rewrite results, but untested).
- DESIGN.md's row leaves out several refusals: a subquery in the select list or ORDER BY; unqualified columns, a bare `*`, or ORDER BY an output name; an unnamed cast, COALESCE or CASE over a column; NATURAL or USING joins; ONLY; column aliases.
- Extensions for later: composite keys, GROUP BY, outer joins, a bare `*`.

- **Depends on:** 20261001-24.
- **Came from:** Both reviews of 20261001-24.
- **Design:** clock-anchor, rewrite-rules.
- **Status:** todo

## After version 1.

These tasks are worth doing, but they don't block version 1. Pick them up after the full pipeline (20260922-65) works.

### 20260923-6. Test the runtime check's environment scrubbing. Done, see BACKLOG-COMPLETE.md.

### 20260923-8. Unit-test the RepoGems helper. Done, see BACKLOG-COMPLETE.md.

### 20260923-9. Close the test gaps in the spec task guards. Done, see BACKLOG-COMPLETE.md.

### 20260923-10. Stop local RSpec options from filtering out boundary specs. Done, see BACKLOG-COMPLETE.md.

### 20260923-41. Support DML statements.

INSERT, UPDATE, DELETE, and MERGE, at the top level or inside a CTE. A slow production query can be DML, but rewrite-test and result-comparison compare result rows, so this needs a design for comparing effects rather than rows. RelationQualifier's DML-target handling was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-42. Support SELECT INTO and locking clauses.

`SELECT ... INTO` and `FOR UPDATE`, `FOR SHARE`, and similar. Job-queue queries often use `FOR UPDATE SKIP LOCKED`. DESIGN.md refuses locking clauses in rewrite candidates, so decide how the original and its candidates are compared. RelationQualifier's locking-clause skip was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-43. Support TABLESAMPLE.

The `system` and `bernoulli` methods are volatile, so results aren't repeatable. The TABLESAMPLE handling in FunctionCalls and PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-44. Support richer functions in FROM.

`ROWS FROM(...)` over several functions, column definition lists, and non-FuncCall items in a function's place. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-45. Support JSON_TABLE and SQL/JSON.

JSON_TABLE (`JsonTable`) and the SQL/JSON constructors and functions: JSON_OBJECT, JSON_ARRAY, JSON_VALUE, JSON_QUERY, JSON_EXISTS, IS JSON, JSON(), JSON_SCALAR, JSON_SERIALIZE, and the JSON aggregates. The JSON_TABLE path swap in PredicateAtoms was last present in 6507105. The pg_query deparser segfaults on some forms, so test in child processes. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-46. Support XMLTABLE and XML functions.

XMLTABLE (`RangeTableFunc`), XmlExpr (including IS DOCUMENT and XMLROOT), and XmlSerialize. XMLROOT keyword handling in PredicateAtoms was last present in 6507105. Some XML deparse output is invalid SQL. See 20260923-30. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-47. Support CTE CYCLE and SEARCH.

The CYCLE mark redaction in PredicateAtoms, including typed marks, was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-48. Support rows outside row comparisons.

20260924-31 made plain row comparisons, such as keyset pagination `(created_at, id) < ($1, $2)`, supported in v1. `SupportedSql` still refuses a row anywhere else, as `RowExpr`: `ROW(a, b)` in the select list, `(a, b) IN ((1, 2), ...)`, `(a, b) = ANY(...)`, a row compared with a subquery, `IS DISTINCT FROM` between rows, nested rows, and one-element rows such as `ROW(a)`. Supporting them means adding them to `SupportedSql` and handling them in every walker that 20260923-33 lists.

Gaps in the supported comparisons are tracked elsewhere: pools for `=`/`<>` and expression rows in 20260926-55, and dropped keyset tie rows in 20260926-59.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-49. Support GROUPING SETS, ROLLUP, and CUBE.

GroupingSet, `GROUP BY ()`, and GROUPING(). The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-50. Support SIMILAR TO.

The SIMILAR TO reader in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-51. Support field selection.

`(t).x`, `(f(x)).y`, `(t).*`, and mixed forms. The volatility check has to see functions called through attribute notation. See 20260923-35. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260923-52. Support other SQL-syntax functions.

normalize, IS NORMALIZED, SYSTEM_USER, and COLLATION FOR. The normal-form keyword handling in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Status:** todo

### 20260926-4. Wire run discipline into steps 13 and 14. Done, see BACKLOG-COMPLETE.md.

### 20260926-5. Run discipline: tell timeouts apart from cancels, and allow one statement only. Done, see BACKLOG-COMPLETE.md.

### 20260926-6. Step 8 wiring. Done, see BACKLOG-COMPLETE.md.

### 20260926-7. Wire `quaack run` into the driver CLI. Done, see BACKLOG-COMPLETE.md.

### 20260926-8. Step 5 orchestration loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-9. Driver start and run server loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-10. Arena database: handle the dump's `CREATE SCHEMA public`. Done, see BACKLOG-COMPLETE.md.

### 20260926-11. Structural discard: compare typmods. Dropped, see BACKLOG-COMPLETE.md.

### 20260926-12. Assumption check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-13. Expression MCV classification: tests for the paths that aren't covered. Done, see BACKLOG-COMPLETE.md.

### 20260926-14. Wire steps 9 and 10 into the CLI and the pipeline. Done, see BACKLOG-COMPLETE.md.

### 20260926-15. Scenario builder and counterexample loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-16. `quaack run` loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-17. Arena setup loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-18. Parallel spec runs remove each other's Postgres containers. Done, see BACKLOG-COMPLETE.md.

### 20260926-19. Assumption and run discipline loose ends, part two. Done, see BACKLOG-COMPLETE.md.

### 20260926-20. Step 11 loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-21. Harness and driver loose ends, part three. Done, see BACKLOG-COMPLETE.md.

### 20260926-22. Steps 9 and 10 wiring loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-23. Index build loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-24. Assumption and timeout loose ends, part three. Done, see BACKLOG-COMPLETE.md.

### 20260926-25. Pipeline loose ends, part four. Done, see BACKLOG-COMPLETE.md.

### 20260926-26. Scenario and counterexample loose ends, part two. Done, see BACKLOG-COMPLETE.md.

### 20260926-27. Baseline loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-28. Operator rewrites skip steps 8 to 11. Done, see BACKLOG-COMPLETE.md.

### 20260926-29. Remaining test-infrastructure unknowns.

- The 1216-failure run is still unexplained. Two guesses, neither confirmed: spec processes in different PID namespaces or sandboxes on the same hostname, where `kill(0)` returns ESRCH; or containers dying outside our code, such as a Docker Desktop restart or OOM. Watch for a repeat.
- A resumed run still restarts counterexamples at round 1 (from 20260926-25).

- **Depends on:** 20260926-21, 20260926-25.
- **Came from:** Build of 20260926-21 and -25.
- **Design:** counterexamples; CLAUDE.md Development.
- **Status:** todo

### 20260926-30. Result comparison loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-31. Minimax and operator rewrite loose ends. Done, see BACKLOG-COMPLETE.md.


### 20260926-32. Measurement test gaps.

- No real-Postgres test produces an unstable literal. Making block counts move between runs deterministically, inside a read-only transaction, was hard, so only the `summarize` unit test covers that path.

- **Depends on:** 20260926-27, 20260926-31.
- **Came from:** Their build.
- **Design:** baseline.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-33. Wire steps 4b and 12 to 14 into the pipeline. Done, see BACKLOG-COMPLETE.md.

### 20260926-34. Report loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-35. Statistics spec restores the pg_stats grant. Done, see BACKLOG-COMPLETE.md.

### 20260926-36. Pipeline wiring and 3d follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20260926-37. Step 9 fixtures fail to load on realistic schemas. Done, see BACKLOG-COMPLETE.md.

### 20260926-38. Report loose ends, part two. Done, see BACKLOG-COMPLETE.md.

### 20260926-39. LLM payload fidelity. Done, see BACKLOG-COMPLETE.md.

### 20260926-40. Keyset pagination loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-41. Step 9: support expression unique indexes instead of refusing. Done, see BACKLOG-COMPLETE.md.

### 20260926-42. Report loose ends, part three.

- The ScenarioTests dropped count isn't stored anywhere readable. Store it in `rewrite_tested_<n>` and show it in the report.
- "Whether counterexamples covered them" shows only the `evidence` flag, because per-round covered shapes aren't stored.
- A plan node with no `Schema` is matched to a table by name only when exactly one subset table has that name.
- LLM call counts on a resumed run include only calls from the current process.

- **Depends on:** 20260926-34, -38.
- **Came from:** Their build and review.
- **Design:** report.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-43. Payload fidelity loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-44. Expression-unique loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-45. Driver, LLM client and harness items left from 20260924-13, -14, -20. Done, see BACKLOG-COMPLETE.md.

### 20260926-46. Driver crashes on the first counterexample round. Done, see BACKLOG-COMPLETE.md.

### 20260926-47. Refuse user-defined set-returning functions in FROM. Done, see BACKLOG-COMPLETE.md.

### 20260926-48. Anchor clock-reading date literals. Done, see BACKLOG-COMPLETE.md.

### 20260926-49. Schema dump, clock anchoring and deparse items left over.

- An empty conninfo has no defined behavior in the schema dump, and no test.
- Restore LLM candidates by their anchored form, not by position. This is a large redesign.
- The subset DDL doesn't restore into an empty arena on its own (schemas, types, extensions), and a partitioned query table needs its parent in the dump.
- Table sort order for EUC_JP and WIN1252 databases.

- **Depends on:** 20260924-15, -22, -23.
- **Came from:** Build and review of those tasks.
- **Design:** schema-dump, clock-anchor, input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-50. FROM functions: non-FuncCall items crash. Done, see BACKLOG-COMPLETE.md.

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty. Done, see BACKLOG-COMPLETE.md.

### 20260926-52. Anchor the clock in rewrite candidates too. Done, see BACKLOG-COMPLETE.md.


### 20260926-53. Candidate clock anchoring loose ends.

- `RewriteEntry.run_sql` falls back to `"sql"` for entries without `anchored_sql`. Only hand-written spec fixtures and stores from before the change hit it. Consider requiring `anchored_sql` and updating the fixtures (about 30 writes).

- **Depends on:** 20260926-52.
- **Came from:** 20260926-52 build and review.
- **Design:** clock-anchor.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-54. Test infrastructure items left from 20260923-16, -18, -25.

- **Dead admin connection (needs a user decision):** should `Server#admin` quietly reconnect when a spec leaves its admin connection dead? Reconnecting hides the `ConnectionLost` hint that a forked child must end with `exit!`.
- **Driver checker mode (needs a user decision):** pinning `names_only: true` for the real driver in the static checker needs a named driver-rules constant, or a planted fixture in the driver's tree.
- **Harness:**
  - child specs that load the root spec_helper
  - a repeated memoized backtrace
  - old image cleanup
  - moving child specs in-process
- **Symlinked Ruby:** `File.realpath` in `stdlib_dirs` matters only with a symlinked Ruby (rbenv), and it's untested.
- **Rake loop:** a rake loop that skips a non-root suite would go unnoticed. Only the root suite is checked, and the Rakefile says so.

- **Depends on:** 20260923-16, -18, -25.
- **Came from:** Their build and review.
- **Design:** none (CLAUDE.md Development).
- **Status:** todo

### 20260926-55. Keyset and expression-unique leftovers.

- No pools for `=` or `<>` row comparisons, or rows built on expressions (listed as a v1 limit).
- Perturb-and-retry for colliding expression keys.
- A generated column counts as NULL when an expression key is worked out.

- **Depends on:** 20260926-40, -44.
- **Came from:** Their build and review.
- **Design:** rewrite-test.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-56. Items left from 20260923-27, -28, -35, -38.

- **Needs a decision:** functions, types, operators, and names inside string literals aren't qualified. Rewrite them, or refuse them?
- **Shared parse helper:** merge PlanExpression's parse helper with CanonicalPlan's parse step. Refactor only, but it changes a shared signature.
- **ArgumentError rules:** give rules to the ArgumentErrors raised in PredicateAtoms and IndexCandidate. For IndexCandidate, decide whether to change the error class callers rescue.
- **Operator messages:** a driver-side table mapping rules to text for operators. The texts need deciding.

- **Depends on:** 20260923-27, -28, -35, -38.
- **Came from:** Their build and reviews.
- **Design:** qualify, volatility, input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Rewrite them (schema-qualify functions, types, operators and names inside string literals).
- **Status:** todo

### 20260926-57. Update the e2e corpus for keyset support, and check for other drift. Done, see BACKLOG-COMPLETE.md.


### 20260926-58. End-to-end runner over the e2e corpus (20260922-65, part two). Done, see BACKLOG-COMPLETE.md.

### 20260926-59. Keyset tie rows are dropped on realistic schemas. Done, see BACKLOG-COMPLETE.md.


### 20260926-60. A fixture load failure in the vacuity guard crashes step 9. Done, see BACKLOG-COMPLETE.md.

### 20260927-1. Set operations crash generator one (5a-1). Done, see BACKLOG-COMPLETE.md.

### 20260927-2. 5a-4 and the plan gate prepare with untyped parameters. Done, see BACKLOG-COMPLETE.md.

### 20260927-3. 5a-1 puts grouping and ordering columns in INCLUDE instead of the key. Done, see BACKLOG-COMPLETE.md.

### 20260927-4. 5a-1 gives no atoms for correlated subqueries. Done, see BACKLOG-COMPLETE.md.

### 20260927-5. 5a-1 gives no candidates in some common shapes. Done, see BACKLOG-COMPLETE.md.

### 20260927-6. Weak or unstable top picks. Done, see BACKLOG-COMPLETE.md.

### 20260927-7. e2e corpus fixes: 075 and 010. Done, see BACKLOG-COMPLETE.md.


### 20260927-8. e2e 097: top fix far above bound; CTEs and subqueries get no candidates. Done, see BACKLOG-COMPLETE.md.

### 20260927-9. 5a-7 ranking and combining are stricter than DESIGN.md. Done, see BACKLOG-COMPLETE.md.

### 20260927-10. Capture and restore relallvisible. Done, see BACKLOG-COMPLETE.md.

### 20260927-11. HypoPG size ignores B-tree deduplication. Done, see BACKLOG-COMPLETE.md.

### 20260927-12. e2e 086 misses its bound by 6 blocks. Done, see BACKLOG-COMPLETE.md.


### 20260927-13. 5a-1 adds a non-covering INCLUDE and no bare-key variant. Done, see BACKLOG-COMPLETE.md.

### 20260927-14. Typed-prepare loose ends, and e2e 020 and 099. Done, see BACKLOG-COMPLETE.md.

### 20260927-15. 5a-1 generation loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260927-16. one_statement? lets data-modifying CTEs and SELECT INTO through. Done, see BACKLOG-COMPLETE.md.


### 20260927-17. Covering-check and volatility-list gaps.

- `ColumnRefs.in` skips subqueries, so an outer-table column read only inside a correlated subquery isn't counted in `read_columns`, and an INCLUDE can look covering when it isn't. This costs performance only.
- `VOLATILE_FUNCTIONS` in `value?` is a fixed name list matched on the last name only. It misses user-defined volatile functions and wrongly flags a user function with a built-in's name. It's a backstop behind volatility.

- **Depends on:** 20260927-13, -15.
- **Came from:** Review of 20260927-13 to -16.
- **Design:** index-from-query.
- **Status:** todo

### 20260927-18. Make rewrite-test scenarios load instead of skipping them.

20260926-60 skips a rewrite-test scenario whose fixture won't load and marks its atoms untested. That's acceptable for now, but a scenario that won't load means those atoms go untested. Find out why such scenarios fail (constraints or triggers the scenario builder doesn't model: exclusion constraints, triggers on the arena tables, complex CHECKs, and so on), and make the builder produce rows that load. Or refuse the query up front with a clear rule, so atoms aren't silently left untested.

Also: fixture-compare still disproves every candidate when a scenario won't load (`:fixture_load_failed`). That fails safe for v1, but it rejects correct rewrites; once scenarios load, it stops mattering. And add a guard-level spec that a `:query`-step `ArenaRunner::Error` isn't swallowed by `VacuityGuard.loaded_exercised_atoms` (today, removing the step check stays green).

- **Depends on:** 20260926-60.
- **Came from:** User direction, 2026-09-27.
- **Design:** rewrite-test.
- **Status:** todo

### 20260927-19. Set-aside loose ends.

These are minor findings from the review of 20260927-11:
- There's no cap on set-asides. The worst realistic case is about 2 extra real builds per low-cardinality table, per search (about 18 for a 3-table join with 2 rewrites). Add a per-search cap, or limit set-asides to the moved key-only variant.
- There are two low-cardinality thresholds: the generator's hardcoded 50 (`TableCandidates::LOW_CARDINALITY`) and classify's configurable one used by `UnusedSetAside`. Unify them.

- **Depends on:** 20260927-11.
- **Came from:** Review of 20260927-11.
- **Design:** index-from-query, index-test, index-build.
- **Status:** todo

### 20260927-20. Regenerate the prompt pack: JSON-only instruction and a subtly wrong fake rewrite. Done, see BACKLOG-COMPLETE.md.


### 20260927-21. LLM reply parsing: pick the right object, and check the schema. Done, see BACKLOG-COMPLETE.md.

### 20260927-22. Reply parsing loose ends.

These are minor findings from the review of 20260927-21:
- `embedded_objects` builds every `{` start, then retries `JSON.parse` at each later `}`. That scan is worse than quadratic: 16 KB of brace-heavy prose takes 13s, and a 28 KB fenced reply takes 1.1s. Scan the starts lazily, stop at the first match, and cap the number of starts.
- A reply cut off at max_tokens now reports "didn't match the schema" instead of "wasn't valid JSON".
- In `longest_object`, the `is_a?(Hash)` check is dead code.
- No test covers a required key that has no type (the `ReplyShape` `key?` mutation survives).

- **Depends on:** 20260927-21.
- **Came from:** Review of 20260927-21.
- **Design:** LLM client.
- **Status:** todo

### 20260927-23. Driver calls run teardown (20260922-65, part four). Done, see BACKLOG-COMPLETE.md.

### 20260927-24. Corpus replay loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260927-25. Teardown loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260927-26. Chat-friendly versions of multi-turn prompt-pack prompts. Done, see BACKLOG-COMPLETE.md.

### 20260927-27. Replay wrong-rewrite spec gaps.

These are minor findings from the review of 20260927-24:
- The per-query spec "finds the wrong rewrite whenever the llm-rewrites reply holds the wrong condition" runs no expectation for queries whose reply lacks the condition.
- `PipelineReplay.wrong` matching the whole rewrite hash (`to_s`) instead of its `"sql"` field survives mutation.
- From the review of 20260927-26: `spec/prompt_pack_chat_spec.rb` doesn't check that "You were asked:" labels the first ask and "Your reply:" labels the planted reply. Swapping them stays green.

- **Depends on:** 20260927-24.
- **Came from:** Review of 20260927-24.
- **Design:** none.
- **Status:** todo

### 20260927-28. Parser note loose ends, and the Postgres 18 upgrade.

- When pg_query ships a Postgres 18 parser, upgrade it and drop the parser note (20260923-1).
- The driver builds the `query_unparsable` note from its own pg_query, not the enclave's. The two usually match because both install from the same lockfile. If they don't, the note names the wrong grammar. The enclave could send its parser major version as a plain integer.
- `clock_anchoring.rb` "the query doesn't parse" has no note. Intake refuses such a query first, so that message can't be reached today.
- `parser_version_spec.rb` restates the formula, so it stays green when `MAJOR` is wrong. Assert the literal 17.
- The sentinel test in `relation_qualifier_spec.rb` checks only the exception message, not the egress output.

- **Depends on:** 20260923-1.
- **Came from:** Reviews of 20260923-1.
- **Design:** none.
- **Status:** todo

### 20260927-29. Deploy loose ends.

- `QUAACKS_DEV_CHECKOUT=1` turns off the driver-present guard, and it's a plain environment variable. No production path sets it, but an operator could export it on a jump server by mistake.

- **Depends on:** 20260923-2.
- **Came from:** Reviews of 20260923-2.
- **Design:** Where QUAACK runs.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260929-2. Several LLM providers in one run.

Let one run use more than one LLM provider, for two reasons. Different models propose different rewrites, indexes, and counterexamples, which is more of the chaos QUAACK wants. And spreading asks across providers stretches free tiers further, since each has its own rate and daily limits.

Each ask is stateless: it sends its whole conversation, and no provider holds a session. So asks can move between providers freely, with one exception. A multi-turn exchange must stay on one provider: llm-index-ideas' replacement round, llm-counterexamples' counterexample rounds, and the re-ask from 20260928-4. Otherwise a model is shown another model's reply as if it were its own.

Ideas to settle before building:
- **Configuration.** An `llms` list in driver.json, each entry shaped like today's `llm` block, with a name.
- **Routing policy.** Options:
  - round-robin per ask;
  - pinning steps to providers;
  - fan-out, where llm-rewrites and llm-index-ideas ask every provider and take the union, deduplicated by the usual checks;
  - failover, moving on to the next provider after `llm_rate_limited` or `llm_unavailable`, and remembering that for the rest of the run.
- **Adversarial pairing.** Have llm-counterexamples use a different model from the one that wrote the rewrite, so the model hunting for counterexamples isn't grading its own work.
- **Burndown.** Count calls per provider as well as per step (burndown), so the report shows where the calls went.
- **Cost.** Fan-out multiplies calls, so make it opt-in per step.

- **Depends on:** 20260928-4.
- **Came from:** The user, 2026-09-29.
- **Design:** Where QUAACK runs, llm-index-ideas, llm-rewrites, llm-counterexamples, burndown.
- **Status:** todo

### 20260929-20. `quaack deploy` removes old enclave versions.

Every `quaack deploy` installs the new `quaacks` and `quaack-protocol` gems next to the old ones in the jump server's user gem directory, so versions pile up. After a successful install and version check, have deploy remove every version of those two gems older than the last release. It keeps the version it just installed and the one before it, so the operator can still fall back one release.

- Remove only QUAACK's own gems (`quaacks` and `quaack-protocol`), only from the user gem directory, and only with `gem uninstall --user-install -v <version>`. Never touch shared dependencies such as pg or pg_query, and never use sudo.
- Do it only after the new version answers `quaacks --version` correctly. A failed deploy removes nothing.
- Print a line for each version removed, like the other deploy progress lines.
- Also clear the old gem files out of `~/.quaack/deploy`.
- Open question: "the last release" here means the version installed before this deploy. If the operator skipped a release, is that still right, or should deploy keep the highest version older than the new one? Settle this before building.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after the bump to 0.1.1.
- **Design:** Where QUAACK runs, "Deploying the enclave".
- **Status:** todo

### 20261001-1. `quaack run` prints the LLM error's detail. Done, see BACKLOG-COMPLETE.md.

### 20261001-2. A failed LLM call says which step it was and how big the request was. Done, see BACKLOG-COMPLETE.md.

### 20261001-3. Trim the LLM payloads to fit a 131k-token window. Done, see BACKLOG-COMPLETE.md.


### 20261001-4. Payload trimming: minor findings.

The review of 20261001-3 found three minor items:

1. The spec in `enclave/spec/index_payload_step_postgres_spec.rb` (around lines 104–107) works out its expected best candidate by copying the code it tests. Write the expected value out directly instead. The spec near line 130 already pins the behavior on its own terms.
2. `IndexPayload#best` doesn't explicitly exclude refused candidates the way `Refinement.used?` does. That's harmless while a refused result never carries a used plan, but adding `!r["refusal"]` would make it explicit.
3. When a query uses a partitioned parent, the payload drops the partitions' CREATE TABLE and index statements, even though the plans name the partitions. Decide whether to keep the DDL for partitions of the query's tables.

- **Depends on:** 20261001-3.
- **Came from:** The second review of 20261001-3, 2026-10-01.
- **Design:** llm-index-ideas.
- **Status:** todo

### 20261001-5. An LLM error reads the reason out of a JSON array body.

Gemini's OpenAI-compatible endpoint answered a 503 and QUAACK printed no reason. Its error body seems to be a JSON array, such as `[{"error": {"message": "..."}}]`, which isn't confirmed. The detail code from 20261001-1 only reads a Hash or a String. When the body is an array, take the error message from its first element the same way. If no message is there, give the whole body as JSON. `llm_auth` stays status-only.

- **Depends on:** 20261001-1.
- **Came from:** The user, 2026-10-01, a Gemini 503 with no reason shown.
- **Design:** LLM client.
- **Status:** todo

### 20261001-6. The `llm` block in driver.json takes an optional `max_retries`.

The openai and anthropic gems retry a 408, 409, 429, or 5xx twice by default, with backoff. That's too few to ride out an overloaded provider during a long run. Add an optional `max_retries` (a non-negative integer) to the `llm` block in `~/.quaack/driver.json`, and pass it to both adapters. Without the key, keep today's default. A value that isn't a non-negative integer is a usage error naming the key, the same way other bad keys in the block are handled.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, after Gemini returned 503s.
- **Design:** LLM client, driver.json.
- **Status:** todo

### 20261001-7. Send stats only for the columns the query references.

The llm-index-ideas payload's `stats` covers every column of each table the query uses. On wide tables that came to 52k characters for one query. Send stats only for the columns the query references anywhere (select list, WHERE, JOIN, GROUP BY, ORDER BY), found with pg_query from the qualified query. Keep the stored statistics whole. Update DESIGN.md (llm-index-ideas) to match. Settle against DESIGN.md first whether llm-rewrites or any other LLM step sends stats too.

- **Depends on:** 20261001-3.
- **Came from:** The user, 2026-10-01.
- **Design:** classify, llm-index-ideas.
- **Status:** todo

### 20261001-8. `quaack run` shows its progress. Done, see BACKLOG-COMPLETE.md.

### 20261001-9. The full schema dump always includes the `dba` schema. Done, see BACKLOG-COMPLETE.md.

### 20261001-10. The full schema dump finds the schemas its objects reference, and takes overrides.

Replaces the hard-coded `dba` of 20261001-9. Objects in the dumped namespaces, such as functions, can reference schemas that weren't dumped, and then arena won't load. Find those schemas and add them to the dump, for example by parsing the dump with pg_query and collecting the schemas named in function bodies, defaults, types, and the like, then dumping again until nothing new turns up. Also let the operator name extra schemas to include, for example a list in the `quaacks` config. Settle the details with the user before building: which references count, whether a dependency query against the catalog (`pg_depend`) beats parsing, and where the override lives.

Also add an arena spec that loads a dump whose function references `dba` objects, end to end. That was the original `arena_dump_load_failed` symptom, and the review of 20261001-9 found no test covering it.

Handle objects the operator can't read. Including the `dba` schema made pg_dump fail with `pg_dump_failed`, because the operator's role had no read access to two of its tables. pg_dump locks every table it dumps, so one unreadable table fails the whole dump. Dump only the objects the dumped namespaces actually depend on, not whole extra schemas, and then decide what to do about a needed object that still can't be read. For example, check privileges first with `has_table_privilege` and refuse with a rule that names the problem (`dump_object_unreadable`) and counts the unreadable tables, rather than letting pg_dump fail with no reason. Settle this with the user too.

- **Depends on:** 20261001-9.
- **Came from:** The user, 2026-10-01.
- **Design:** schema-dump, arena-setup.
- **Status:** todo

### 20261001-11. Progress output: minor findings.

The review of 20261001-8 found two minor items:

1. Nothing tests the skip line that operator-rewrites prints on a resumed run with `--rewrites`. If that line broke, every later `[n/18]` number would be off by one, and no spec would catch it. Nothing tests the rewrite-correctness skip note for each rewrite either. Add a cli_run progress spec that resumes with `rewrites_generated` and `operator_rewrites_checked` set and passes `--rewrites`. It should assert `[6/18] operator-rewrites: already done, skipping`, and cover the rewrite-correctness note too.
2. In `Progress#step`, if the first `say` raises, such as EPIPE on stderr, `start` is still nil. The rescue's `since(nil)` then raises a TypeError that hides the real error. Set `start` before the first `say`.

- **Depends on:** 20261001-8.
- **Came from:** The review of 20261001-8, 2026-10-01.
- **Design:** The `quaack run` command.
- **Status:** todo

### 20261001-12. `quaack run`'s progress lines say in plain English what each step does, and 12a shows each index it builds. Done, see BACKLOG-COMPLETE.md.


### 20261001-13. Streamed progress: minor findings.

The review of 20261001-12 found two minor items:

1. Progress lines count toward the transport's output cap. An index-build run that builds a very large number of indexes could hit `output_too_large` from the progress lines alone. That fails safe, but consider leaving room for one line per index, or not counting progress lines toward the cap.
2. The driver's progress block runs inside the transport's read loop. If the block raises or runs slowly, it holds up reading, and that can push the run past its timeout. Consider rescuing the block's errors and logging them.

- **Depends on:** 20261001-12.
- **Came from:** The review of 20261001-12, 2026-10-01.
- **Design:** The transport.
- **Status:** todo

### 20261002-12. A `copilot_cli` LLM provider: a local `copilot` command. Done, see BACKLOG-COMPLETE.md.

### 20261003-1. `copilot_cli`: pin the drain after the child exits.

The third review of 20261002-12 found one surviving mutation. Returning before the adapter drains stdout and stderr after the child's exit status arrives still passes every spec. It also passed an ad hoc check with 120KB on each pipe, so it's no known bug. But nothing pins the ordering, and a reply still in the pipe when the child exits could be cut short. Add a spec where the fake writes a large reply (at least several pipe buffers) and exits at once, and assert the whole reply arrives. Confirm the mutation goes red.

- **Depends on:** 20261002-12.
- **Came from:** The third review of 20261002-12, 2026-10-03.
- **Design:** LLM client.
- **Status:** todo

### 20261003-2. Take the recorded replay runs out of the per-commit check. Done, see BACKLOG-COMPLETE.md.

### 20261003-6. `implied_predicate_removal`: refuse casts and volatile duplicates, reach subqueries, close test gaps. Done, see BACKLOG-COMPLETE.md.

### 20261003-7. Intake unreadable causes: minor findings.

Minor findings from the first review of 20260929-5:

- `start.rb:72`: changing `start_with?("#{home_path}/")` to `start_with?(home_path.to_s)` stays green. Add a test where home is `/Users/bench` and the path is `/Users/benchX/q.sql`.
- `operator_file.rb:54`: removing `ENOTDIR` (a parent that's a regular file) stays green. That case would then be `not_regular_file` instead of `missing`. Pin it.
- `error_filter.rb:11`: the comment still says "for two rules" and has a stray indent. Restore the `FUNCTION` comment that was deleted from `reply.rb:55`.
- The driver repeats the list of four reasons in `reply.rb` and `enclave_error.rb`. Share one constant from the protocol gem.
- From the second review:
  - `start.rb:72`: removing `path == home_path` or either `cleanpath` call stays green. Test `--query /Users/bench` and `/Users/bench/../x.sql`.
  - `operator_file.rb` `reason`: `EIO`, `ENAMETOOLONG`, and `IOError` all become `not_regular_file`, which is misleading. Give them their own reason, or a generic one.
  - No driver spec checks that `--query '~/q.sql'` reaches the remote `quaacks` as a literal `~/q.sql`.
  - `error_filter.rb:153`: the `instance_of?(String)` check is an equivalent mutant. Keep it with a comment, or drop it.

- **Depends on:** 20260929-5.
- **Came from:** The first review of 20260929-5, 2026-10-03.
- **Design:** input.
- **Status:** todo

### 20261003-8. `rake full`: harden the stamp and close test gaps. Done, see BACKLOG-COMPLETE.md.

### 20261003-9. `quaack deploy` diagnosis: minor findings, round two. Done, see BACKLOG-COMPLETE.md.

### 20261003-10. Operator-cancel test: don't blame pg_sleep for other failures. Done, see BACKLOG-COMPLETE.md.

### 20261003-3. Report payload: minor findings.

The build and review of 20261001-17 found these:

- **`excluded` goes out as stored.** The report message's top-level `excluded` map sends selection's reason strings straight from the selection entry. Send them through a closed list, as `RewriteFate` does.
- **Selection calls every result-comparison discard `result_mismatch`,** a timeout included. The rewrite's fate is right, but the per-label `excluded` reason still says `result_mismatch` for a result-comparison timeout.
- **`RewriteFate::FAILURES` is a hand copy** and misses `transaction_closed`, which `ArenaFixture::Error::RULES` has. A rewrite-test or counterexamples failure with that rule goes out with a nil rule. Build the list from `RULES.keys` plus `unsupported_order`.
- **Two branches no test needs.** `NegativeResult`'s `once` sends an index declined for two different reasons once for each, and grouping by the index alone stays green. `RewriteFate`'s `production` handles selection saying `result_mismatch` when result-comparison's entry has no failing verdict, which `Selection` can't produce, and dropping that stays green. Test each or drop it.
- **negative-result still repeats other spellings of one predicate:** `amount > 10` and `amount > '10'::numeric`; `status IN ('a', 'b')` and `status = ANY (ARRAY['a'::text, 'b'::text])`; the varchar form `(status)::text = ANY ((ARRAY[...])::text[])`.
- **Rewrite numbering gaps.** `CandidateRuns.candidates` and `IndexBuild.searches` stop at the first gap in rewrite numbers, while the report lists rewrites across gaps. A rewrite after a gap would never be measured and would read `unfinished`. Find out whether a real run can leave a gap, and make the two agree.
- **`NegativeResult.disproved` is a shim** kept only for `RuleBugs`. 20261002-5 moves `RuleBugs` onto an allowlist; have it use `RewriteFate` and `ResultComparator::MISMATCHES`, then delete the shim and `RuleBugs`' own copy of `MISMATCHES`.
- **`e2e/run.rb`'s `why_none`** now tallies rewrite fates, and nobody has run it since.
- **`spec/pipeline_replay_spec.rb` takes about 24 minutes** on its own. See whether it can share setup or run less.

- **Depends on:** 20261001-17.
- **Came from:** The build and review of 20261001-17, 2026-10-03.
- **Design:** report, negative-result.
- **Status:** todo

### 20261003-4. Readable report: minor findings.

The build and both reviews of 20261001-18 found these:

- **Run the full check.** 20261001-18 landed without the enclave suite or the Docker-backed root specs. Run `bundle exec rake` on `main` and fix what's red, starting with the three assertions in `spec/pipeline_replay_spec.rb` that were reworded and never executed.
- **Test gaps where a wrong change stays green** (the code is right):
  - The LLM row's "Already existed" count: the fixture has one `covered_by_existing` and one `duplicate`, so swapping them passes. Use different counts.
  - The kB to MB and MB to GB boundaries, and `Format.apart`'s rounding (it replaced `Format.fewer` in 20261004-65).
  - The "It built and measured" paragraph being left out when there's a winner.
  - `not_better` when the original timed out, `worse_on`'s timed-out branch, and a ranked label that also timed out.
  - `index_rows` taking only the `original` search; `share` for a selectivity of 0; `node` preferring actual rows.
  - The outcome column for five of the fates under "Stopped for another reason"; only `rewrite_test_failed`, `footprint_tie`, and `unfinished` are pinned.
  - An index whose label result-comparison dropped: counting `result_mismatch` as not better stays green (`accountability.rb:84`).
  - The escape on a fate's `round` (`template.html.erb:46`): the sentinel payload's fate doesn't print one. Add a `counterexamples_disproved` rewrite.
- **"Planner ignored" counts indexes HypoPG refused,** which the planner was never asked about. Reword it or count them apart.
- **The "refused on arrival" note leaves out a reason.** For rule rewrites, rewrite-rules' `failed_checks` also covers an assumption-check assumption failure and clock anchoring. The README has the same gap.
- **An index on a quoted table name with a space** reads "with a new index on CREATE INDEX ON ...", since `Candidates::DDL` wants `\S+` for the table.
- **`Format.apart` may raise `FloatDomainError`** (this note was written about `Format.fewer`, which 20261004-65 replaced; check whether it still applies) if the original read 0 blocks on the slow values.
- **The README promises "a warning in the report"** for an operator rewrite the LLM doubts (near line 489). The payload carries no operator-rewrites warnings, so no report has ever shown one. Send them, or change the README.
- **LLM call counts are the driver's in-memory counts,** so a resumed run shows only the calls made since it resumed.
- **Confirm with the user** the two choices the builder made: the seventh rewrites column, and showing rewrite-rules rule names.

- **Depends on:** 20261001-18.
- **Came from:** The build and both reviews of 20261001-18, 2026-10-03.
- **Design:** report, negative-result, burndown.
- **Status:** todo

### 20261003-5. Report payload: what the index accountability table still lacks.

20261001-18 stayed in the driver (the user, 2026-10-03), so these cells of the report say "not recorded", and 20261001-19 and -20 won't fill them:

- **Built and measured, not better, and ranked, per source.** `indexes` in the report message carries no source. The store has it (`IndexCandidate` sources). Send it through a closed list of QUAACK's constants.
- **Already existed and planner ignored, for the two generators.** The index-dedupe and index-test drops aren't recorded by source.
- **Already existed and planner ignored, in a winning report.** `negative` goes out only when nothing is ranked. Send the declined and existing lists every time.
- **The plan with the new indexes.** The payload has a plan only for rewrites, and that plan is the rewrite with no new indexes, even when the winning label ran with some. Send the winning label's plan, for an index-only winner too.

Then have the report render them. Trust boundary: sources are constants, DDL goes through CandidateDdlRedaction, and a plan node sends only its type, relation, index name, and row counts.

- **Depends on:** 20261001-18, -20.
- **Came from:** The build of 20261001-18, 2026-10-03.
- **Design:** report, negative-result.
- **Status:** todo

### 20261003-11. `transitive_predicate_copy`: close test gaps, accept typmods, reach more columns.

Findings from the build and review of 20261002-7:

- **An untested soundness guard.** Equalities come only from the WHERE and inner-join ONs, which is right, but no test pins it. A mutation that also took equalities from outer-join ONs stayed green. Add `FROM posts p JOIN users u ON u.id = p.id LEFT JOIN accounts a ON p.account_id = u.account_id WHERE u.account_id IN (1,2)` and expect no rewrite.
- **`Catalog#default_btree?`'s `families.size == 1`** (catalog.rb ~146) survives being changed to `>= 1`. Test it, or accept it as untested.
- **Typmods block common Rails rewrites.** `Catalog::Info.type` comes from `format_type`, so `varchar(255) = varchar` and `numeric(10,2) = numeric(12,2)` are refused. Compare base types (`atttypid`) instead.
- **Enum, domain and array columns are refused,** since they have no default btree family of their own. Resolve the base type or the generic family (`anyenum`, `anyarray`) if it's safe.
- **Inner joins nested on an outer join's nullable side get no copies,** though copying within that nested inner join would be sound.

- **Depends on:** 20261002-7.
- **Came from:** The build and review of 20261002-7, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261003-12. `rake full`: fail fast on an unreadable version, and fix a comment.

Minor findings from the review of 20261003-8:

- **The nil-version check runs last.** It sits in `write_full_replay_stamp` (Rakefile ~33), so an unreadable version file is caught only after the whole 38-minute run. Call `gem_versions` at the start of `full` to fail fast.
- **`spec/full_replay_selection_spec.rb` overstates its coverage.** Its comment says it covers the run "as `rake full` runs it", but it swaps in its own spec task. Only the new `spec/rakefile_spec.rb` test checks that the variable reaches the child suites. Fix the comment.
- **Suite time still left:** `candidate_runs_step_postgres_spec` and the baseline, schema-dump and step specs spend their time in real Postgres. Trimming them wasn't cheap or clearly safe in 20261003-8. Look again only if the per-commit check gets slow.

- **Depends on:** 20261003-8.
- **Came from:** The review of 20261003-8, 2026-10-03.
- **Design:** none (development tooling).
- **Status:** todo

### 20261003-13. `quaack deploy` diagnosis: minor findings, round three.

Minor findings from the review of 20261003-9:

- **The ruby half of the `PLAIN_PATH` filter is untested** (`deploy_diagnosis.rb:126`, `other_gem`). Checking only the gem path keeps all specs green. Add a test with ESC in the ruby path, and expect the general sentence.
- **The advice can leave quaacks uninstalled** (`deploy_diagnosis.rb:105-107`). If the first `ruby` on PATH is 3.4 but the first `gem` belongs to an older Ruby, putting 3.4's bin first doesn't install quaacks for 3.4. Add "then run `quaack deploy` again". The older `other_ruby` message has the same gap.

- **Depends on:** 20261003-9.
- **Came from:** The review of 20261003-9, 2026-10-03.
- **Design:** Deploy.
- **Status:** todo

### 20261003-14. `cte_hoist_dedupe`: build-time loose ends.

Out-of-scope findings from the build of 20261002-8:

- **Untyped body placeholders are treated as text.** If Postgres can't infer a placeholder's type in a CTE body, `self_contained?` prepares it as text. Some bodies may then be refused, or matched, for the wrong reason. Check whether this costs real rewrites.
- **Unqualified table names resolve with the catalog connection's `search_path`.** If that differs from the app's, the rule could judge a body against the wrong table. Pin the search_path, or refuse unqualified names when it's ambiguous.
- **Some older refusal tests in the rule spec have no positive control.** Mutation testing shows they aren't vacuous, but a positive twin for each would make that obvious.

- **Depends on:** 20261002-8.
- **Came from:** The build of 20261002-8, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261003-15. `quaack run`: say what each step did when it finishes. Done, see BACKLOG-COMPLETE.md.

### 20261003-16. `quaack run`: a live clock instead of "Still working" lines. Done, see BACKLOG-COMPLETE.md.

### 20261003-17. Step 9: break foreign-key cycles through nullable columns. Done, see BACKLOG-COMPLETE.md.

### 20261003-18. A scenario refusal shouldn't end the run. Done, see BACKLOG-COMPLETE.md.

### 20261003-19. Name the tables in an `fk_cycle` refusal. Done, see BACKLOG-COMPLETE.md.

### 20261003-20. Give each rewrite a whimsical name. Done, see BACKLOG-COMPLETE.md.

### 20261003-21. Give the design's steps descriptive names, and number them in order. Done, see BACKLOG-COMPLETE.md.

### 20261003-23. Step 9: break a cycle when the query joins on its nullable edge. Done, see BACKLOG-COMPLETE.md.

### 20261003-24. ParentRows can leak a value in a Postgres error. Done, see BACKLOG-COMPLETE.md.

### 20261003-25. FK-cycle breaking: loose ends.

Minor findings from the build and review of 20261003-17:

- **One code path has no test.** No test has a nullable foreign key from a table in a cycle to a table outside it. If "this edge is in a cycle" is changed to "this table is in any cycle", every test stays green (`topology.rb:73`). Add that case.
- **A DEFAULT in a cut column stays DEFAULT.** If the default references a row that isn't loaded yet, the load fails. Load NULL there instead, or say in DESIGN.md that this case is unsupported.
- **Atoms on subquery or CTE columns aren't counted as reading a column.** They have no table. vacuity-guard keeps this safe, but check whether it ever refuses a query it shouldn't.
- **Partitioned tables with foreign keys may not load through the counterexample path.** The builder's attempt failed with `fixture_load_failed`. Reproduce it, and fix it or list it as unsupported.

- **Depends on:** 20261003-17.
- **Came from:** The build and review of 20261003-17, 2026-10-03.
- **Design:** rewrite-test, llm-counterexamples.
- **Status:** todo

### 20261003-26. `union_outer_filter_removal`: widenings, and duplicate candidates.

From the build of 20261002-9:

- **Widen the rule where it's sound.** It now refuses:
  - arms whose output columns come from a CTE or subquery, since the catalog gives no types for them;
  - arms whose column types differ harmlessly, such as `int` and `bigint`;
  - unqualified columns, column aliases, and correlated subqueries in conjuncts.
  
  Widen each only with a soundness argument and a real-Postgres test.
- **The same rewrite can come out twice.** The rule can fire both before and after `cte_hoist_dedupe`, so the candidate list may hold the same SQL reached by different rule orders. Drop candidates whose SQL matches one already listed.

- **Depends on:** 20261002-9.
- **Came from:** The build of 20261002-9, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261003-27. Step 9: `unsupported_type` should say which type, and cover more types. Done, see BACKLOG-COMPLETE.md.

### 20261003-22. `quaack setup`: loose ends.

Minor findings from the build and review of 20260928-1:

- **No run-server flags and no `run_server_command` fails as `usage`.** `quaacks run-server` refuses with `usage` (`run_server.rb:52`), so the operator sees `quaack setup failed: usage` and can't tell why. Under `quaack run` without `--keep`, the run, intake included, is then torn down. Give it its own rule, such as `run_server_unspecified`, add it to README's "Common rules" table, and say in README run-server that the flags or the config are required.
- **Flags given after run-server has passed are silently ignored.** If the database given was wrong but passed the check, the only fix is a new run. Warn when flags are given and run-server is skipped.
- **A setup failure under `quaack run` tears the run down, but under `quaack setup` it's kept.** Pick one behavior, probably keep, since nothing expensive has run yet and the operator may just need different flags.
- **The driver's unit specs don't cover skipping a late step.** Only `spec/setup_postgres_spec.rb` catches a broken skip of `racetrack-setup`. Add a unit case.

- **Depends on:** 20260928-1.
- **Came from:** The build and review of 20260928-1, 2026-10-03.
- **Design:** inventory through racetrack-setup, the steps `quaack setup` runs.
- **Status:** todo

### 20261003-28. `shared_scan_cte`: widenings.

Minor follow-ups from building 20261002-6. Each one widens what the rule covers; none is a correctness bug.

- **Copies inside subqueries or CTE bodies aren't shared.** Only the top-level `FROM` is searched.
- **One nullable copy refuses the whole group.** When another two or more copies are on inner joins, they could still share a CTE.
- **A GROUP BY that relies on the primary key is refused.** Postgres can't prepare the rewrite, since a CTE has no primary key. The rule could add the select list's columns to the GROUP BY.
- **`places()` descends into aliased joins.** Only the refusal of unnamed FROM items stops it. Make it stop there by itself, so later widenings can't trip on it.
- **`ONLY` tables aren't shared.**

- **Depends on:** 20261002-6.
- **Came from:** The build of 20261002-6, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261003-29. `existence_in_flip`: a captured whole-row reference, and widenings. Done, see BACKLOG-COMPLETE.md.

### 20261003-30. Finish 20261003-23: a skipped group's cut-column key class. Done, see BACKLOG-COMPLETE.md.

### 20261003-31. Step 9: two false passes on ordinary joins. Done, see BACKLOG-COMPLETE.md.

### 20261003-32. rewrite-test: loads that fail on `IS NULL` and skipped groups.

These were found in the second review of 20261003-23, and they fail safe (the load fails, so the rewrite is refused):

- **`IS NULL` on a nullable FK column fails the load.** The NULL goes into the parent primary key's class. Seen on an acyclic schema.
- **A group that skips leaves orphaned copies.** This is 20261003-30's mechanism in an acyclic schema: `courses JOIN accounts LEFT JOIN templates t … WHERE t.id IS NULL`. 20261003-30 may fix it in general. If so, add a test here and close this task.
- **An anti-join on a cut edge itself** fails the load for every candidate. Recheck it after 20261003-30.

- **Depends on:** 20261003-30.
- **Came from:** The second review of 20261003-23, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** todo

### 20261003-33. Step 9 values: loose ends from 20261003-27. Done, see BACKLOG-COMPLETE.md.

### 20261003-34. Step 9 values: loose ends from 20261003-33. Done, see BACKLOG-COMPLETE.md.

### 20261003-35. `distinct_join_to_exists`: loose ends from 20261002-16.

These are minor findings from building and reviewing 20261002-16:

- **`catalog/calls.rb` matches a function by name only, across schemas.** A user function in another schema with the same name as a known-safe one is treated as safe. Match on the schema too, or refuse when the name is ambiguous.
- **A bare key column in ORDER BY under LIMIT is refused.** Rails often sends `ORDER BY id LIMIT n`. It's safe when the key is the outer table's unique key, so allow it.
- **The rule's description string is stale.** It no longer says what the rule matches.
- **The cache key test is weak.** Make it fail if the cache key drops an input.
- **The `x.*` check needs a test** that goes red if the check is removed.
- **A nondeterministic-collation key with a `COLLATE "C"` unique index** (pre-existing). `DISTINCT` folds `Ann` and `ann` together, but the unique index lets both rows exist, so dropping `DISTINCT` changes the result. Refuse when the key's collation is nondeterministic and differs from the unique index's.

- **Depends on:** 20261002-16.
- **Came from:** The build and review of 20261002-16, 2026-10-03.
- **Design:** rewrite-rules, `distinct_join_to_exists`.
- **Status:** todo

### 20261003-36. Flaky driver spec: copilot_cli adapter grandchild-stdout test. Done, see BACKLOG-COMPLETE.md.

### 20261003-37. rewrite-test values: loose ends from 20261003-34.

These are minor findings from building and reviewing 20261003-34:

- **A base table aliased with a column list** (`reads.rb` `Tables#add` and `qualifier`). In `FROM fx.customers c(id, name, status)`, `c.status` reads `customers.lsn`, but `Reads` treats `lsn` as unread and fills it with NULL. Fix: treat an alias with a column list as reading every column of its table.
- **ParentRows' self-FK fix depends on foreign-key order** (`parent_rows.rb` `foreign_keys`). The `next if` skip looks only at `fixed`, not at `pairs`.
  - Example: `code NOT NULL UNIQUE`, a self-FK `root_code → code`, and an FK `code → regions`. When the self-FK comes first, the second FK overwrites `code`, and the load fails.
  - No test covers the other order, so the mutation `fixed.merge(pairs)` → `fixed` survives.
  - The same skip lets a later FK overwrite a NULL that an earlier nullable FK set.
- **Three-part column references resolve by their table part only** in `Reads`, ignoring the schema.

- **Depends on:** 20261003-34.
- **Came from:** The build and review of 20261003-34, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** todo

### 20261003-38. `bad_value`: loose ends from 20261003-24. Done, see BACKLOG-COMPLETE.md.

### 20261003-39. rewrite-test: more variety in self-references and repeated parents.

These are false passes found in the reviews of 20261003-31. They also happen on main. All are realistic:

- **A self-referencing FK always points at its own row.** So `comments c JOIN comments p ON p.id = c.parent_id WHERE p.user_id = 3` passes as equal to `... WHERE c.user_id = 3`. Likewise `categories p JOIN categories c ON c.parent_id = p.id` passes as equal to its EXISTS form. Comment trees, category trees and manager chains are common. A cheap fix: point the S3 copy's self-reference at the hit row, so some row's parent is a different row.
- **Two FKs into the same parent get the same free values.** In `messages(sender_id → users, recipient_id → users)`, both users always get the same `name`. So `SELECT s.name, r.name …` passes as equal to `SELECT s.name, s.name …`. Give each parent row reached through a different FK its own free values.
- **has_one crosses collide.** On a unique FK, such as `profiles.user_id UNIQUE`, the S3 cross row collides with the hit's row, and `RowSet` drops it without saying so. It fails safe, but that case loses the cross row. Pick a parent the unique FK hasn't used yet.

Each needs a wrong rewrite that's disproved and a correct twin that passes, on real Postgres.

- **Depends on:** 20261003-31.
- **Came from:** The reviews of 20261003-31, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** todo

### 20261003-40. Step 9: a dropped group leaves rows pointing at missing parents. Done, see BACKLOG-COMPLETE.md.

### 20261003-41. rewrite-test refusals and results: loose ends from 20261003-18.

These are minor findings from building and reviewing 20261003-18:

- **A crash between two stored results.** If the enclave crashes after writing `rewrite_tested_<n>` but before `rewrite_survived_<n>`, a resumed run goes on to llm-counterexamples, and `counterexample-round` fails with `counterexample_round_untested`. This predates the task, and it affects rewrites that fail rewrite-test too. Store both results together, or have resume rebuild `survived` from `tested`.
- **Scenarios are rebuilt for every rewrite.** A refusal comes from the query, not the rewrite, so every rewrite is refused the same way. Record the refusal once per run, and reuse it.
- **The rule-bug check counts `rewrite_test_failed` results that compared nothing.** This predates the task. Count only failures that compared rows.

- **Depends on:** 20261003-18.
- **Came from:** The build and review of 20261003-18, 2026-10-03.
- **Design:** rewrite-correctness.
- **Status:** todo

### 20261003-42. rewrite-test further fixtures: loose ends from 20261003-40.

These are minor findings from building and reviewing 20261003-40:

- **A self-join regression, from a refusal to an untested pass.** Take `messages m JOIN users s ON s.id = m.sender_id JOIN users r ON r.id = m.recipient_id WHERE s.email = 'a@b' AND r.email = 'c@d'`. The rewrite with the emails swapped now passes with every atom marked untested; main refused it. DESIGN's self-join limit covers it, but it should be disproved.
- **Two FKs into one table, with a non-unique filter column** (also on main). The rewrite that filters on `recipient_id` instead of `sender_id` passes with no untested atoms, because the S3 cross users all share the hit's email. This overlaps 20261003-39's "two FKs into the same parent".
- **The untested-atom check (vacuity-guard) looks only at S1's first fixture.** An S1 near miss that moved to a further fixture is marked untested, which is cautious. Have it look at further fixtures too.
- **Further fixtures copy the parents but not the hit's sibling rows** that create fan-out. Also, no step-9-level test needs `parents_of` to recurse; only a unit test guards that.
- **The picker can repeat candidates on a retry,** and a retry shifts every pooled column, not just the one that collided.
- **S6 has less variety under a single-value unique filter.**
- **Further fixtures add runtime.** Measure it on a realistic query.

- **Depends on:** 20261003-40.
- **Came from:** The build and reviews of 20261003-40, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** todo

### 20261003-43. `fk_cycle` table names: loose ends from 20261003-19.

These are minor findings from building and reviewing 20261003-19:

- **Quoted names are dropped.** The driver's name-shape check drops a cycle that has mixed-case or quoted table names, so the report falls back to the bare refusal. Allow any name that came from `schema_subset`, quoted the way the catalog quotes it.
- **A dot inside a name can match the wrong table.** `CycleTables` matches by joining `schema.table` with a dot. The output is still a `schema_subset` string, so this isn't a leak. Match on the schema and the table separately.
- **No end-to-end test.** Nothing runs a whole pipeline on an `fk_cycle` schema and checks the report sentence.
- **counterexamples' re-raise of a cycle is nearly unreachable.** Prove it can happen, or simplify it.

- **Depends on:** 20261003-19.
- **Came from:** The build and reviews of 20261003-19, 2026-10-03.
- **Design:** rewrite-test, report.
- **Status:** todo

### 20261003-44. `existence_in_flip`: loose ends from 20261003-29.

These are findings from building and reviewing 20261003-29:

- **A wrong result with a constant under COLLATE** (`selection.rb:35`). The bare-constant refusal for y only looks at a bare placeholder, so `users.code IN (SELECT 'a ' COLLATE "C" FROM groups)` on a `char(3)` column still flips. The original returns no rows and the rewrite returns one. Refuse a placeholder under COLLATE, or under any wrapper that keeps it a plain constant.
- **Siblings may have the capture bug.** `cte_hoist_dedupe`, `shared_scan_cte` and `union_outer_filter_removal` check a hoisted body by preparing it on its own, so a bare name that used to read an outer column might prepare as a whole-row reference. Write a reproducer for each, and fix any that capture.
- **Skipped widenings:** the flip inside an EXISTS body, and `x = ANY (SELECT ...)`.
- **ORDER BY keys** from CTEs, subqueries or tables that aren't plain are refused. Widen this if real queries need it.
- **The scope check** ignores the names of unaliased function calls in FROM.
- **Errors (E):** a y expression that can raise, such as `1/(x-1)`, may raise on rows the original's plan never evaluated. Consider refusing a y that can raise.
- **Originals that already error** still get rewrites: `ORDER BY 2` with one output column, and `y COLLATE "C"` against a nondeterministic collation. Refuse them, or leave them be.
- **Test gaps:** the `ival` guard on constant ORDER BY keys (`ordering.rb:31`), and the `sole_table` path when S is a single CTE or a table that isn't plain (`selection.rb:46`).

- **Depends on:** 20261003-29.
- **Came from:** The build and review of 20261003-29, 2026-10-03.
- **Design:** rewrite-rules, `existence_in_flip`.
- **Status:** todo

### 20261004-1. `quaack run` step summaries: counts and rule names from the enclave.

20261003-15 gives each finished step a summary, but some steps can only say what they did, not how much. The enclave sends the driver nothing but `done` for index-search, index-rank, arena-setup, baseline, index-baseline, candidate-runs, minimax, result-comparison and selection. And rewrite-rules doesn't say which rules fired. So the lines read "Searched for indexes", not "Found 12 possible index definitions mechanically", and rewrite-rules gives counts only.

The rule:

- Add an allowlisted counts message, sent by each of those steps when it finishes. It carries only small integers with fixed key names, such as `{"type":"step_counts","found":12}`. The protocol whitelist checks every key and that every value is a non-negative integer.
- rewrite-rules reports which rules fired, by name. The names must come from a constant list shared through the protocol gem, matching the enclave's RULES. The whitelist and the driver both refuse any name not on that list.
- The driver's summaries use these counts and names.
- Sentinel tests: a value planted in the data never reaches the counts or the names. A forged message carrying a string where a count belongs is refused.

- **Depends on:** 20261003-15.
- **Came from:** The build of 20261003-15. The user asked for it, 2026-10-04.
- **Design:** Progress lines for `quaack run`, the protocol whitelist.
- **Status:** todo

### 20261004-2. Step 9 re-probes CHECK constraints thousands of times. Done, see BACKLOG-COMPLETE.md.

### 20261004-3. Tighten 20261003-38's SQLSTATE filtering.

The review of 20261003-38 found four minor issues:
- Class 42 includes 42501, a permission error. It isn't caused by the value, so it probably shouldn't count as `bad_value`.
- A value can cause a P0001 (raised by a trigger or function) or 54000 (program limit) error. These now fail the whole step as `internal_error`, when they should count as `bad_value`.
- The re-raised PG::Error still carries the value in its message. Only ErrorFilter keeps it from leaving the enclave. Wrap it with `cause: nil` and a message that carries only the sqlstate.
- The timeout and termination tests check weakly that the value is absent. Make them use a sentinel value and assert that it never appears in the output.

- **Depends on:** 20261003-38.
- **Came from:** The review of 20261003-38.
- **Design:** rewrite-test, ErrorFilter.
- **Status:** todo

### 20261004-4. The Picker breaks CHECK constraints when no value fits both the atom and the CHECK.

When no value in the pool satisfies both the atom and the column's CHECKs, the Picker falls back to the first value in the pool, even if that value breaks a CHECK. On Canvas-like schemas:
- `workflow_state <> 'deleted'` picks `'DELETED'`, which isn't in the CHECK's IN list.
- `role_state LIKE 'c%'` picks `'c%'`.

S1 then fails to load with `fixture_load_failed` (23514), so every candidate is disproved. This was there before 20261004-2. It will likely hit the next Canvas run.

The fix: add the CHECK's own values that satisfy the atom to the Picker's candidates. Test on real Postgres with a CHECK IN list and both atoms above.

- **Depends on:** 20261004-2.
- **Came from:** The build of 20261004-2.
- **Design:** rewrite-test.
- **Status:** todo

### 20261004-5. Build the original query's scenarios once, not once per rewrite.

`steps/counterexamples.rb` calls `ScenarioTests.run` once per candidate. Each call builds a new `Builder`, which rebuilds the same scenarios for the original query and loses its probe caches. Build them once per run and share them across candidates, so the outcomes stay the same.

- **Depends on:** 20261004-2.
- **Came from:** The build of 20261004-2.
- **Design:** rewrite-test.
- **Status:** todo

### 20261004-6. Pin the type part of rewrite-test's probe cache key.

`ValuePools::Probe#key` is `[sql, oid, format_type]` (`value_pools.rb:200`). If it drops the type, entries are shared wrongly across types and fixtures change, yet every committed spec still passes. Add a spec where the same CHECK sits on columns of different types, for example `integer` and `numeric`, or `varchar(8)` and `varchar(255)`. Assert each fixture's value, and confirm the spec goes red when the key drops `oid` and the type.

- **Depends on:** 20261004-2.
- **Came from:** The review of 20261004-2.
- **Design:** rewrite-test.
- **Status:** todo

### 20261004-7. Harden the live clock's timer thread. Done, see BACKLOG-COMPLETE.md.

### 20261004-8. rewrite-test gaps found by the FK-cycle review.

The review of 20261003-23 and -30 found these minor gaps on the Canvas `accounts` ↔ `courses` schema:
- `IS [NOT] NULL` on the cut column of an FK cycle fails to load with `fixture_load_failed` for every candidate, including the correct ones. It fails safe, but no rewrite of such a query can pass. Check whether 20261003-32 covers this first.
- `Topology#roots` uses `load_parents`, and no spec pins that. Switching it back to `parents` stays green.
- The S3 cross row for a cut FK (`crossings` in `topology.rb`) has no spec that fails without it. Since copies kept their parent, a copy already supplies the same row. Add a spec only the cross row can satisfy, or drop the cross row.
- These wrong rewrites pass on acyclic schemas too, so they're general rewrite-test variety gaps:
  - "own template" rewritten as "has template and has courses";
  - a `<>` foreign template;
  - its mirror, "has template and own courses" rewritten as "own template";
  - a dropped plain ascending `ORDER BY course_template_id`;
  - a dropped `ORDER BY t.name`.

  No scenario has an account that has courses plus a template from another account.

- **Depends on:** 20261003-23, 20261003-30.
- **Came from:** The review of 20261003-23 and -30.
- **Design:** rewrite-test.
- **Status:** todo

### 20261004-9. Report `polymorphic_key_copy` disproofs in rewrite-test and counterexamples as rule bugs.

`rule_bugs.rb:58` still skips every rewrite-test or counterexamples disproof of a rewrite that rests on `denormalized_equal`. That made sense before 20261002-15's fix round, when fixtures didn't keep the copy. Now they do, so a wrong rule, such as one copying the wrong constant, gets disproved but isn't reported as a QUAACK bug. Remove the exemption, with a test showing that a broken rule's disproof shows up in the rule bugs.

Also, a twin that drops the type filter is caught only if counterexamples' LLM writes a row of another class with the copy set. Consider making rewrite-test's fixtures add such a row themselves.

- **Depends on:** 20261002-15.
- **Came from:** The second review of 20261002-15.
- **Design:** rewrite-test, counterexamples and report.
- **Status:** todo

### 20261004-10. Make the enclave call timeout configurable.

The driver kills any enclave call after `Transport::Base::DEFAULT_TIMEOUT` (3600s, `driver/lib/quaack/driver/transport/base.rb`). Nothing passes in a different value, though the comment says the driver's config does. On a real Canvas run, index-build failed after exactly 1h00m00s.

Add a driver config setting for this timeout, with a `quaack run` flag to override it, and pass it to every `Transport::Ssh.new` that runs pipeline steps. Validate it as a positive number. Say in the failure message which setting to raise when a call hits the limit, for example: "the enclave call timed out after 1h00m00s; raise `enclave_timeout_seconds`". Document it in the README.

- **Depends on:** none.
- **Came from:** The user's Canvas run, 2026-10-04.
- **Design:** Transport, config.
- **Status:** todo

### 20261004-11. Build each candidate index in its own enclave call.

index-build builds every candidate index in a single `quaacks index-build` call, so the total build time has to fit in one call's timeout. On a large table, a few indexes are enough to pass an hour. Have the driver call index-build once per index instead, so each index gets its own timeout and the run can resume after the last index built. Keep the progress output: one line per index, plus the step summary's count.

Check how a resumed run treats indexes that already exist on the racetrack. They should be skipped, not built again, and not counted as failures.

- **Depends on:** 20261004-10.
- **Came from:** The user's Canvas run, 2026-10-04.
- **Design:** index-build.
- **Status:** todo

### 20261004-12. Build index-build's indexes in table order.

index-build builds the candidate indexes on the run server in whatever order they arrive. That can build one on a large table, then one on another large table, then go back to the first, so the first table's pages have already left the cache. Group the builds by table, so every index on one table is built before moving to the next, while that table is still in cache. Within a table, keep the current order.

Test that the build order is grouped by table, and that every index still gets built and reported. If 20261004-11 has landed by then, keep its one-call-per-index structure and order those calls by table.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** index-build.
- **Status:** todo

### 20261004-13. Two live-clock edge cases. Done, see BACKLOG-COMPLETE.md.

### 20261004-14. Give each mechanical rewrite rule its own doc page, with examples, and link to it from the report.

The mechanical rules (rewrite-rules) are listed in a table in DESIGN.md. Move each one to its own page, `docs/transforms/<rule_name>.md`, named exactly as the rule appears in the enclave's `RULES` (for example `docs/transforms/implied_predicate_removal.md`). Each page has:
- what the rule does, and when it applies and refuses (from the DESIGN.md table and the rule's code comments);
- any assumption it rests on, such as `denormalized_equal`;
- at least one example: the SQL before the rule and the SQL after, written as an ordinary Rails-style query. These come from 20261001-29, which no longer has them.

DESIGN.md's table stays as a short index: one line per rule, linking to its page.

In the final report, where a rewrite's source is a rule, link the rule's name to its page on GitHub: "Where it came from: made by QUAACK's own rewrite rule [implied_predicate_removal](https://github.com/benchub/quaack/blob/main/docs/transforms/implied_predicate_removal.md)."
- Build the URL only from a rule name on the shared constant list of rule names, never from text in the enclave's message. A name not on the list gets no link, as now.
- HTML-escape the link.

Tests:
- a spec that every rule in `RULES` has a page in `docs/transforms/`, and every page there names a rule in `RULES`, so a new rule can't land without its page;
- a report spec for the link, and one showing that a name not on the list gets no link.

Do this after 20261001-29 if it's in flight, since both touch the same DESIGN.md table.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** rewrite-rules, report.
- **Status:** todo

### 20261004-15. Step slugs: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261004-16. Rewrite names: drop word pairs that read badly. Done, see BACKLOG-COMPLETE.md.

### 20261004-17. Explain `production_connection_failed`. Done, see BACKLOG-COMPLETE.md.

### 20261004-18. `quaack start --port`: production's port. Done, see BACKLOG-COMPLETE.md.

### 20261004-19. `quaack run` on a terminal: drop lines the live clock makes redundant. Done, see BACKLOG-COMPLETE.md.

### 20261004-20. Rewrite names: ambiguous words and borderline pairs. Done, see BACKLOG-COMPLETE.md.

### 20261004-21. Make `incomplete` failures diagnosable. Done, see BACKLOG-COMPLETE.md.

### 20261004-22. Port check: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261004-23. rewrite-test spends ~20 minutes of Ruby CPU per rewrite. Done, see BACKLOG-COMPLETE.md.

### 20261004-24. Flaky ProductionComparison timeout spec under load. Done, see BACKLOG-COMPLETE.md.

### 20261004-25. Progress lines: summaries that only repeat the step, and asks after notes. Done, see BACKLOG-COMPLETE.md.

### 20261004-26. ssh_failed and incomplete: resume advice after teardown, and the ControlMaster note. Done, see BACKLOG-COMPLETE.md.

### 20261004-27. rewrite-test CPU: confirm on the user's schema, and the open items from 20261004-23.

20261004-23 cut rewrite-test's CPU on a 19-table fixture from about 25 s to about 3 s. It did that by memoizing `Topology#members` (now `Slots`), the result-comparison Shape, each build's rows, and shared expression-index keys. Still open:

1. **Confirm on the user's schema.** Ask the user to rerun with `QUAACKS_PROFILE=<path>` on 0.1.5 and share the profile. That's 20261004-23's step 4.
2. **RowSet's linear scans** are unchanged: `include?`, `parent`'s `find`, `clash?` and `parents_of`. The task suggested them, but the profile on the fixture didn't show them. Fix them if the user's profile does, test first.
3. **Run-store reuse** of the original query's scenarios across `quaacks` processes isn't done. Do it only if the profile calls for it.
4. **Untested evaluate-key parts.** Dropping `index` or `row.table` from `RowSet`'s evaluate key leaves every spec green. Add a test with two expression unique indexes over equal-valued columns, e.g. `lower(email)` and `lower(username)` both filled with `k5`.
5. **Profile file mode.** When the `QUAACKS_PROFILE` file already exists, it keeps its old mode, but README and DESIGN.md promise 0600. Set the mode explicitly.
6. **Timing margin.** Reverting only the Shape memo gives 12.4 s against the 12 s bound. The memo's own count test covers it, but consider a tighter bound or a larger gap.
7. **Builder findings to check:**
   - A `character varying NOT NULL CHECK (col IN (...))` column refuses with `unsatisfiable_check`.
   - `priority >= 3` under `CHECK (priority BETWEEN 1 AND 5)` also refuses with `unsatisfiable_check`.
   - An invoices query (`GROUP BY i.number ORDER BY i.number LIMIT 10`) fails when compared with itself, on main too.
   Split these into their own tasks if they're real.

- **Depends on:** 20261004-23.
- **Came from:** The review of 20261004-23, and its builder.
- **Design:** rewrite-test, Where QUAACK runs.
- **Decided by the user (2026-10-06):** the user will provide a profile later. Do items 4-7 now, and leave items 1-3 open in a follow-up task.
- **Status:** todo (item 1 needs the user)

### 20261004-28. Timeout checks on the enclave's clock: RunDiscipline and ArenaRunner. Done, see BACKLOG-COMPLETE.md.

### 20261004-29. Docs and wording after ssh_failed skips teardown. Done, see BACKLOG-COMPLETE.md.

### 20261004-30. Flaky run-server-check spec: a young client listed before an old one. Done, see BACKLOG-COMPLETE.md.

### 20261004-31. A run that finished but couldn't tear down: show the report, and tidy the advice. Done, see BACKLOG-COMPLETE.md.


### 20261004-32. Teardown-failure docs and the path-without-done case. Done, see BACKLOG-COMPLETE.md.

### 20261004-33. Tidy the oldest-client-first spec helper. Done, see BACKLOG-COMPLETE.md.

### 20261004-34. ServerClock follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20261004-35. Order-dependent Deparse cache spec. Done, see BACKLOG-COMPLETE.md.

### 20261004-36. ArenaRunner: no statements after a cancel's rollback. Done, see BACKLOG-COMPLETE.md.

### 20261004-37. Connection-failure notes: follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20261004-38. Invalid UTF-8 in driver arguments crashes with a backtrace. Done, see BACKLOG-COMPLETE.md.

### 20261004-39. ArenaRunner pipeline: a timeout before the Sync leaves the connection stuck. Done, see BACKLOG-COMPLETE.md.

### 20261004-40. Connection note: port wording. Done, see BACKLOG-COMPLETE.md.

### 20261004-41. ArenaRunner post-cancel guard: follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20261004-42. Shape cache: tidy the specs. Done, see BACKLOG-COMPLETE.md.

### 20261004-43. ArenaRunner: ROLLBACK and a pending cancel under a short timeout. Done, see BACKLOG-COMPLETE.md.

### 20261004-44. README: the connection note when no server is recorded. Done, see BACKLOG-COMPLETE.md.

### 20261004-45. Flaky transport spec: a run that outlasts its timeout. Done, see BACKLOG-COMPLETE.md.

### 20261004-46. Shape: drop the dead copy in `initialize`. Done, see BACKLOG-COMPLETE.md.

### 20261004-47. Driver UTF-8 argument check: follow-ups. Done, see BACKLOG-COMPLETE.md.

### 20261004-48. README: polish the connection-note wording. Done, see BACKLOG-COMPLETE.md.

### 20261004-49. ArenaRunner transaction-status check: untested branches. Done, see BACKLOG-COMPLETE.md.

### 20261004-50. Report: collapse the query list and the "Measured, and not ranked" section. Done, see BACKLOG-COMPLETE.md.

### 20261004-51. Report: explain the untested-conditions note under a rewrite, and render its conditions readably. Done, see BACKLOG-COMPLETE.md.

### 20261004-52. Report: show the original query in the ranking table, and numbers instead of "better"/"no worse". Done, see BACKLOG-COMPLETE.md.

### 20261004-53. Report: style inline SQL so it stands out from the prose. Done, see BACKLOG-COMPLETE.md.

### 20261004-54. Report: show "Why the winner reads fewer blocks" plans as a tree table. Done, see BACKLOG-COMPLETE.md.

### 20261004-55. Report: draw the burndown as an SVG funnel. Done, see BACKLOG-COMPLETE.md.

### 20261004-56. Pid-file races in two more timeout specs, and the group check's start-up gap. Done, see BACKLOG-COMPLETE.md.

### 20261004-57. Rename artifacts left in comments, and a dangling colon in DESIGN.md. Done, see BACKLOG-COMPLETE.md.

### 20261004-58. ArenaRunner per-statement timeout: untested guards, and a nonzero session default. Done, see BACKLOG-COMPLETE.md.

### 20261004-59. Collapsed report sections: hidden warnings and links into closed sections.

These are review minors from 20261004-50.

- **Warnings hidden in a closed section.** A rewrite's summary line gives no hint of two warnings inside its section: that it relies on something the data holds today but the schema doesn't enforce, and the list of conditions the test data never exercised. The README tells readers to read those rewrites extra carefully. Add a short flag to the summary line, such as "⚠ relies on data" or "untested conditions". Coordinate with 20261004-51, which rewords the untested-conditions note.
- **Links lead into closed sections.** "Its SQL is under rewrite X, above" and "See rewrite X under the queries" link to the `<article>` around a closed `<details>`, so the target stays collapsed. Point the link at the `<details>` and open it on `:target` without JavaScript (for example, give the `<details>` the id). Otherwise, reword the links to say "expand rewrite X".
- **The not-ranked table's note is incomplete.** It says "Who proposed it" reads "not recorded" for your query with new indexes. The cell also reads that way for a rewrite whose source is unknown or that's missing from the payload. Make the note cover those cases.

- **Depends on:** 20261004-50.
- **Came from:** The review of 20261004-50, 2026-10-05.
- **Design:** report.
- **Status:** todo

### 20261004-60. Teardown failure: edge cases from 20261004-32. Done, see BACKLOG-COMPLETE.md.

### 20261004-61. Untested conditions: loose ends from 20261004-51.

From the build and review of 20261004-51:

1. **Singular wording.** When one condition is covered and the list folds, the summary reads "The 1 conditions".
2. **Runs recorded before `covered` existed.** A run whose rounds were recorded before 20261004-51 and then reported says "No later test checked them", even though rounds ran. Say "not recorded" instead when rounds exist but carry no `covered`.
3. **Sentinel test.** No committed test sends planted WHERE literals, such as a text and a number, through rewrite-test and a counterexample round to a non-empty `covered` and the report payload, then asserts the sentinels never appear. The review's probe showed no leak. Lock that in with a spec, plus a planted-sentinel control.
4. **`$n` numbering.** The conditions' `$n` placeholders come from a stand-in redaction inside `PredicateAtoms`, so they may not match the `$n` in the query text the report shows (`$69`, `$70` in the user's run). Number them the same way the shown query does, or render them without numbers.

- **Depends on:** 20261004-51.
- **Came from:** The build and review of 20261004-51, 2026-10-05.
- **Design:** report, vacuity-guard.
- **Status:** todo

### 20261004-62. A closed stderr pipe ends `quaack run` with EPIPE. Done, see BACKLOG-COMPLETE.md.

### 20261004-63. `production_connection_failed` for a run without a recorded port: check the port source it names. Done, see BACKLOG-COMPLETE.md.

### 20261004-64. Arena timeout: minors from 20261004-58. Done, see BACKLOG-COMPLETE.md.

### 20261004-65. Ranking baseline: minors from 20261004-52. Done, see BACKLOG-COMPLETE.md.

### 20261004-66. Teardown: minors from 20261004-60. Done, see BACKLOG-COMPLETE.md.

### 20261004-67. ServerClock: minors from 20261004-34. Done, see BACKLOG-COMPLETE.md.

### 20261004-68. Inline SQL: minors from 20261004-53.

The review of 20261004-53 found:
1. `Report.named` names rewrites from the raw run ID, but `View` uses the scrubbed one for `Words.rewrite` and `Words.search`. A run ID containing `\u0001` or `\u0002` would get mismatched rewrite names. Real run IDs are generated, so either use one source for both or refuse such a run ID.
2. An index method other than btree, such as "(gin)", sits outside the SQL span. Decide whether it belongs inside.

- **Depends on:** 20261004-53.
- **Came from:** The review of 20261004-53, 2026-10-05.
- **Design:** report.
- **Status:** todo

### 20261004-69. Rewrite burndown: minors from 20261001-19. Done, see BACKLOG-COMPLETE.md.

### 20261004-70. Arena ROLLBACK after an abort runs under the session's timeout. Done, see BACKLOG-COMPLETE.md.

### 20261004-71. ServerClock: comments and wording from 20261004-67. Done, see BACKLOG-COMPLETE.md.

### 20261004-72. Plan tree table: minors from 20261004-54. Done, see BACKLOG-COMPLETE.md.

### 20261004-73. Teardown: recheck the run directory after `destroy_command`. Done, see BACKLOG-COMPLETE.md.

### 20261004-74. Flaky `schema_dump_postgres_spec.rb:204`: pg_dump's `\restrict` token. Done, see BACKLOG-COMPLETE.md.


### 20261004-75. Tighten the wording left over from 20261004-70. Done, see BACKLOG-COMPLETE.md.

### 20261004-76. index-test tests a rewrite's LLM index ideas against the original query. Done, see BACKLOG-COMPLETE.md.

### 20261004-77. Index burndown loose ends from 20261001-20. Done, see BACKLOG-COMPLETE.md.

### 20261004-78. Burndown funnel loose ends from 20261004-55. Done, see BACKLOG-COMPLETE.md.


### 20261004-79. Funnel partial-band tests, from 20261004-78.

- **Status:** todo
- **Depends on:** 20261004-78 (done)
- **Came from:** the review of 20261004-78.
- **Design:** report.

These parts of `driver/lib/quaack/driver/report/funnel.rb` have no test that goes red when they break:
1. The grey paint of unknown and partial bands (`UNCOUNTED`). Painting a partial band solid blue, which reads as a made-up "went on" count, stays green.
2. The partial band's solid top line is centred at `left = (WIDTH - known) / 2`. Changing it to `(WIDTH - width) / 2` stays green, which moves the line off-centre when "came in" is narrower than `UNKNOWN`.
3. The hatch on a partial band spans the band's full width. Hatching only `known` wide stays green.
5. From the review of 20261004-69: passing `stage` to a partial band's label (`funnel.rb` ~118) is untested; replacing it with `nil` stays green.
4. While here: the table's "Went on" cell for a stage with "came in" but no "went on" is an empty `<td>`, not "not recorded".

### 20261004-80. Indexes table: which source proposed each built index. Done, see BACKLOG-COMPLETE.md.

### 20261004-81. Index refusal rules: keep the list from going stale.

- **Status:** todo
- **Depends on:** 20261004-77 (done)
- **Came from:** the review of 20261004-77.
- **Design:** report, llm-index-ideas.

1. `IndexDdlCheck::RULES` is kept by hand. A new refusal added to `IndexDdlCheck`, `SupportedSql`, `VolatilityCheck` or `Deparse` without updating `RULES` and the samples in `enclave/spec/index_ddl_check_spec.rb` fails nothing, so the cross-gem words spec misses it. Find a way for a new rule to fail a test, such as a spec that scans those files for the rules they raise and compares them with `RULES`.
2. "Planner ignored" in the Indexes table doesn't count index-rank's re-test drops (`never_used`, `hypopg_refused`). That matches the LLM row and DESIGN.md, so it's a choice of definition. Consider saying so in the table's note.

### 20261004-82. Plan tree table: a blocks column. Done, see BACKLOG-COMPLETE.md.

### 20261004-83. Report plans: the flat-layout fallback is unreachable.

From the review of 20261004-72. Reports reach `Report.write` only through `Reply.parse`, which now refuses any plan node without an Integer depth of zero or more. So `report/plans.rb`'s flat layout (`tree?` false, ~lines 8-11 and 40-43) can't happen in a real run, and only the direct-render specs (`report_spec.rb` ~875, 886) exercise it. DESIGN.md (~1186) says both that the driver refuses a report whose nodes lack a depth and that such a plan "is laid out flat". Remove the fallback and its specs, or keep it and say why, and make DESIGN.md say one thing.

While here (second review of 20261004-72): no test plants a Hash in place of a report's `rewrites`, so mutating `rewrites.is_a?(Array)` to `respond_to?(:all?)` survives in both `enclave/.../egress.rb` and `driver/.../reply.rb`. Add one.

- **Depends on:** 20261004-72.
- **Came from:** The review of 20261004-72.
- **Design:** The report's plan tables.
- **Status:** todo

### 20261004-84. Progress: the LLM wait's clock sits on a note's line. Done, see BACKLOG-COMPLETE.md.

### 20261004-85. Closed output pipes: minors from 20261004-62.

1. `QuietStream` only guards `print`. Every write to it uses `print` today, but a later `puts`, `write`, `<<` or `printf` would skip the guard silently. Guard the other write methods, or pin with a spec that they're unused.
2. `quaack setup` changed without docs or tests: `Progress` wraps every stream, so with stderr closed setup now runs its steps silently instead of dying at its first progress line, yet its own `quaack setup failed:` message is unwrapped and still raises `Errno::EPIPE` (exit 1). Decide setup's rule to match `quaack run`, test it with a real `IO.pipe`, and say so in DESIGN.md.
3. With `quaack run … 2>&1 | head`, stdout closes too: the run tears down and writes the report, then printing the report's path raises `Errno::EPIPE` out of `cli.run`. DESIGN.md says so. Decide whether that should exit cleanly with the run's real exit code.

- **Depends on:** 20261004-62.
- **Came from:** The review of 20261004-62 and its builder.
- **Design:** Progress lines for `quaack run`.
- **Status:** todo

### 20261004-86. Plan tree table: measured plans, with blocks, for rewrites.

From 20261004-82's builder and review. Only the original plan carries per-node block counts, because it comes from the operator's `EXPLAIN (ANALYZE, BUFFERS)`. A rewrite's plan in the report is a hypothetical `EXPLAIN`, so in "Why the winner reads fewer blocks" the winner's blocks column is all "not recorded" and the report doesn't say why. Record a measured plan (ANALYZE, BUFFERS) for each ranked candidate from its measurement runs (today these keep plans only when a run is unstable), and send it in the payload within the same `PlanNodes` boundary. Until then, the report should say in words why the winner's column is empty.

- **Depends on:** 20261004-82.
- **Came from:** The builder and review of 20261004-82.
- **Design:** report, measure, egress.
- **Status:** todo

### 20261004-87. Plan tree blocks column: minors from 20261004-82.

1. A step with only one counter shows it as its total (hit missing, read 9 shows "9"). Postgres always writes both, so it's unlikely; show "not recorded" instead, or say why not. The spec pins today's behavior.
2. Postgres counts an InitPlan's blocks in the step that runs it, not the step it hangs from, so they can appear twice in the table. The header ("with the steps under it") and DESIGN.md are true but incomplete; say so.
3. The header doesn't say block counts are totals over all loops, while "actual rows" are per loop. A step run many times can show 1 row next to thousands of blocks. Say so in the header or a note.

- **Depends on:** 20261004-82.
- **Came from:** The review of 20261004-82.
- **Design:** report.
- **Status:** todo

### 20261004-88. ambiguous_user_schema: minors and the operator's own schema. Done, see BACKLOG-COMPLETE.md.

### 20261004-89. Index sources: a test gap and the remaining "not recorded" cells.

From the builder and review of 20261004-80.
1. Removing `!ran.empty? &&` in `IndexSources.not_better` keeps every spec green, yet 5 of 16 recorded replays have a built index no label ran with; without that guard it would count as "not better" by source but not in "All sources together". Add a label-less built index to the producer spec's fixture.
2. In the "Measured, and not ranked" table, "Who proposed it" still says "not recorded" for index candidates.
3. For the generators, "Already existed" and "Planner ignored" still say "not recorded".

- **Depends on:** 20261004-80.
- **Came from:** The builder and review of 20261004-80.
- **Design:** report, burndown.
- **Status:** todo

### 20261004-90. Classify: low-cardinality json, jsonb and array columns send their MCV values. Done, see BACKLOG-COMPLETE.md.

### 20261004-91. Structured columns: test gaps, and other structured types. Done, see BACKLOG-COMPLETE.md.

### 20261004-92. Literal-set values: test gaps, and comparisons by name only elsewhere.

From the review of 20260924-10.
1. Changing `it&.dup&.freeze` to `it` in the literal-set copy stays green: no spec edits a string in place. Add one.
2. Making the value comparison ignore order (`transform_values(&:sort)`) stays green, yet values are positional. Add a test with the same values in another order.
3. Other steps compare measurements from separate processes by literal-set name only: Refinement / index-feedback (stored mechanical results against LLM results) and minimax (`baseline` against `index_baseline`). Their values can differ only if `statistics` or `literals` is rerun partway through a run. Check the values there too (a stored digest would do), or refuse to rerun `literals` once later steps have used it.

- **Depends on:** 20260924-10.
- **Came from:** The review of 20260924-10.
- **Design:** index-rank, index-feedback, minimax.
- **Status:** todo

### 20261004-93. Result comparison: the candidate's own ties inside a LIMIT/OFFSET window. Done, see BACKLOG-COMPLETE.md.

### 20261004-94. Result comparison: loose ends of the edge check.

From the reviews of 20260924-7.
1. **Regression:** `LIMIT 9223372036854775807 OFFSET n` (or the same value bound as `$1`) now fails with `bigint out of range` in the edge query. ProductionComparison raises, which crashes the result-comparison step, and fixture-compare raises `ArenaRunner::Error`. Main passed both. Clamp the sum, or skip the edge check on overflow.
2. With `OFFSET NULL`, the edge query becomes `LIMIT n + NULL`, which has no limit. Treat a NULL offset as 0.
3. Full runs are bounded only by the timeout, not by memory. Four runs over a big table can hold tens of millions of hashes. Add a row cap that refuses with `unsupported_order`.
4. `through_offset!` has no nil guard. pg_query's deparser segfaults on a TypeCast with a nil arg. No realistic query reaches it today. Raise a clear error instead.
5. The `all_columns?` guard in production comparison is dead code. Remove it, or test it.
6. A stricter candidate, such as `ORDER BY grp DESC NULLS LAST, id LIMIT 3`, fails `value` when no tie is cut, though it would pass when one is. Make the two paths agree.

- **Depends on:** 20260924-7.
- **Came from:** The first and second reviews of 20260924-7.
- **Design:** fixture-compare, result comparison.
- **Status:** todo

### 20261004-95. Insert check: clock words, loose ends. Done, see BACKLOG-COMPLETE.md.

### 20261006-1. Waiting-for-the-LLM line: minors from 20261004-84.

From the review of 20261004-84.
1. `driver/spec/pipeline_progress_spec.rb` (~432): the new `it` has no blank line before it.
2. `progress.rb` (~107-110): the `sub_step` comment still says a repeated note "is left out on a terminal"; it can now print as a wait line.
3. Removing `note &&` in `Progress#shown` stays green. Harmless today, since no step note repeats its step's line, but nothing pins it. Add a test or drop the guard.

- **Depends on:** 20261004-84.
- **Came from:** The review of 20261004-84.
- **Design:** Progress lines for `quaack run`.
- **Status:** todo

### 20261006-2. Structured columns: minors from 20261004-91.

From the builder and review of 20261004-91.
1. The classify-level tests for xml, tsvector, range and multirange columns (`pii_classification_postgres_spec.rb` ~380-418) stay green when those types are dropped from the list, since ANALYZE gives them no positive `n_distinct`. Only `planner_statistics_postgres_spec.rb` (~131) catches it. Rename the tests to say what they show, or make them bite.
2. `planner_statistics/catalog.rb` (~47-49) compares an `oid` with `regtype` values using a bare `=`. A planted `public.=` operator on (oid, regtype) turns json, jsonb and xml columns non-structured. Use `OPERATOR(pg_catalog.=)` or cast to `pg_catalog.oid`. Related: 20260930-13, 20260930-14.
3. The trust-boundary test's comment (`pii_classification_postgres_spec.rb` ~222-226) doesn't mention the json sentinel in `customers.preferences`.
4. tsvector lexemes and array elements go to `most_common_elems`, which statistics doesn't read today. If it ever does, apply the same rule there.

- **Depends on:** 20261004-91.
- **Came from:** The builder and review of 20261004-91.
- **Design:** classify, statistics, trust boundary.
- **Status:** todo

### 20261006-3. Classify: bytea, geometric and other non-text types can still send MCV values.

From the builder of 20261004-91. `bytea`, geometric types (`point` and the like) and other non-text, non-structured types can still be classed low-cardinality, so their MCV values go out. A `bytea` column can hold text.

**Ask the user** which types, if any, to add to the structured (never-sent) list, or whether to flip the rule to an allowlist of types whose values may go out.

- **Depends on:** 20261004-91.
- **Came from:** The builder of 20261004-91.
- **Design:** classify, trust boundary.
- **Decided by the user (2026-10-06):** flip the rule to an allowlist: only types whose values are safe to send (such as numeric, boolean, date/time, uuid and enum types, and domains over them) may be classed low-cardinality and send values. Every other type is withheld like json.
- **Status:** todo

### 20261006-4. ambiguous_user_schema: minors from 20261004-88.

From the builder of 20261004-88.
1. `pg_temp` isn't modelled in the path walk.
2. Schemas the application role has no USAGE on aren't modelled; only the operator's USAGE is. The check can refuse a name the application could never resolve to that schema.
3. A collation's encoding isn't considered, so the refusal can be over-cautious.
4. A role schema that defines `=` refuses nearly every query. Correct, but blunt; consider naming the operator in the message so the fix is obvious.

- **Depends on:** 20261004-88.
- **Came from:** The builder of 20261004-88.
- **Design:** input, qualify.
- **Status:** todo

### 20261006-5. Bind a clock-word placeholder to the anchored value (20261004-95 item 4).

Split from 20261004-95. `bind` puts the query's real literals into `$n` before the insert check. A `clock_literal` refusal therefore tells the LLM one bit (whether a placeholder holds a clock word, like `bad_value`), and `VALUES ($1)` is refused when `$1` is `'today'`. Binding the anchored value instead avoids both. The user decided (2026-10-06) to bind the anchored value.

A first build (reverted commit 50b1c27 on `main`'s history, `counterexamples/clock_binding.rb`) failed the second review: it anchored placeholders whose word never reaches a date/time value. `INSERT INTO t (id, tags) VALUES (1, string_to_array($1, ','))` into `tags text[]` with `$1 = 'today'` loaded `{2024-01-01}` instead of `{today}`. The literal `'today'` form is also refused as `clock_literal` though no date/time is reachable (insert_clock_words.rb ~158-160, ~222-223). Restrict anchoring, and the malformed-literal fallback, to targets that can hold a date/time value. Start from the reverted commit and add regressions for both forms. Also cover a placeholder holding a clock word plus more, such as `'today 10:00'` (still refused today).

- **Depends on:** 20261004-95.
- **Came from:** 20261004-95 item 4, and its second review.
- **Design:** What goes into the enclave; insert check; clock anchoring.
- **Status:** todo

### 20261006-6. Clock words and defaults: minors from 20261004-95.

From the reviews and builder of 20261004-95.
1. Array-valued function elements bypass the nested clock check: `ARRAY[array_reverse(ARRAY['today'])]::date[]` is accepted and loads the wall-clock date (also the `::text` variant and three-dimensional constructors). Keep the array target through such functions, or refuse and list as unsupported in v1 (insert_clock_words.rb ~166-170).
2. Some clock-reading defaults stay unanchored: a domain-typed cast such as `DEFAULT ('today'::text)::public.clock_date` (domain names fail `ClockLiterals.castable?`), and array defaults like `('{today}'::text)::date[]` (clock_defaults.rb ~106-110). Handle them or list them in DESIGN.md.
3. An inventory without a recorded `TimeZone` raises `KeyError` in `RunServer.connect` (run_server.rb ~81), reported as `internal_error`. Refuse with a clear rule instead.
4. Query and candidate binding outside counterexamples still binds the raw clock word.
5. Clock anchoring doesn't anchor `current_time` or `clock_timestamp()` in queries.

- **Depends on:** 20261004-95.
- **Came from:** The reviews and builder of 20261004-95.
- **Design:** insert check; arena setup; clock anchoring.
- **Status:** todo
