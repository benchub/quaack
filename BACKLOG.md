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

## Step 1: Input.

### 20260922-13. Input intake. Done, see BACKLOG-COMPLETE.md.

### 20260922-14. Fully qualify relations. Done, see BACKLOG-COMPLETE.md.

### 20260922-15. Canonical plan form. Done, see BACKLOG-COMPLETE.md.

## Step 2: Production inventory.

### 20260922-16. Production inventory. Done, see BACKLOG-COMPLETE.md.

## Step 3: Schema, statistics, and classification.

### 20260922-17. 3a relations. Done, see BACKLOG-COMPLETE.md.

### 20260922-18. 3b schema dump and subset. Done, see BACKLOG-COMPLETE.md.

### 20260922-19. 3c statistics. Done, see BACKLOG-COMPLETE.md.

### 20260922-20. 3d volatility check. Done, see BACKLOG-COMPLETE.md.

### 20260922-21. 3e literal set. Done, see BACKLOG-COMPLETE.md.

### 20260922-22. 3f PII and low-cardinality classification. Done, see BACKLOG-COMPLETE.md.

### 20260922-23. 3g redaction. Done, see BACKLOG-COMPLETE.md.

### 20260922-24. 3h clock anchoring. Done, see BACKLOG-COMPLETE.md.

## Step 4: Run server.

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

### 20260923-21. 5a-1 loose ends.

Still open from the reviews of 20260922-30 and 20260923-20:
- **Join reduction.** 5a-1 decides nullability from syntax alone. Once a strict WHERE conjunct on a table rejects its nulls, Postgres reduces the outer join. Then it pushes down that table's `IS NULL` and the ON conjuncts `Join#keeps?` drops, but 5a-1 still skips them. HypoPG examples: `c LEFT JOIN o ... WHERE o.region = 3 AND o.note IS NULL` misses `orders(note, region)`. `c LEFT JOIN o ON o.customer_id = c.id AND c.region = 5 WHERE o.status = 1` uses `customers(region)`.
- **Tests:** nullability at depth for RIGHT and FULL joins (two mutants survive), "USING always counts" for outer joins, and the error sentinel test checking `full_message` and the cause.
- **Comment:** "a join to one still counts for the table on the other side" isn't true for an outer join to a derived table.
- **Smaller gaps:** an ORDER BY on a nullable-side table's columns becomes a wasted key; `FOR UPDATE OF o` is falsely refused; `(o).*` isn't recognized as a star; `AS o(a, b)` alias lists aren't modeled; INCLUDE covers only the select list and GROUP BY; a prefix LIKE needs `text_pattern_ops` unless the collation is C; incremental sort isn't handled.

- **Depends on:** 20260923-20.
- **Came from:** Both reviews of 20260922-30, both reviews of 20260923-20, and the 20260922-30 builder's notes.
- **Design:** 5a-1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260923-22. MCV statistics loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-23. Dedupe repeated ORDER BY columns in 5a-1. Done, see BACKLOG-COMPLETE.md.

### 20260923-24. 5a-2 loose ends.

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
- **Design:** 5a-2.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
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
- **Design:** Step 9 and 9c.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260923-31. Finish 5a-3 dedupe and filter. Done, see BACKLOG-COMPLETE.md.

### 20260923-32. Finish the governed store. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-34. Governed store loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-36. 5a-3 loose ends.

Still open from the reviews of 20260922-32 and 20260923-31:
- **Some existing indexes never count as covering.** `IndexCandidate.from_ddl` returns nil for `ON ONLY` indexes on a partitioned parent, for any `WITH (...)` index, and for `NULLS NOT DISTINCT` unique indexes. A candidate identical to one is tested as new, and 15a won't report it as a duplicate.
- `IndexSql.normalize_predicate` should re-parse its output. `'x'::mytype(lower('bob'))` is stored as `'x'::mytype()`.
- The doc comment should say array bounds on a cast (`status::text[12345]`) aren't checked, like integer typmods.
- Dead code: `left = unwrap(node.lexpr)` in `column_comparison?`, and the unreachable `A_Const` check in `plain_type?`.

- **Depends on:** 20260923-31.
- **Came from:** The reviews of 20260922-32 and 20260923-31, and the builder's notes.
- **Design:** 5a-3.
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

### 20260923-58. Enclave CLI loose ends.

Still open from the reviews of 20260922-4 and 20260923-53:
- **Needs a decision:** `JSON.parse` uses 50 to 135 times the input size on dense arrays. A 64 MB `[0,0,...]` peaked at 3.2 GB. Lower `Input::MAX_BYTES`, or cap the element count before parsing.

- **Depends on:** 20260923-53.
- **Came from:** The reviews of 20260922-4 and 20260923-53.
- **Design:** Where QUAACK runs.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-1. 5a-4 loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-2. Pin hidden_differences? for every row in a tie group. Done, see BACKLOG-COMPLETE.md.

### 20260924-3. Intake loose ends.

Still open from the reviews of 20260922-13:
- **Orphaned partial runs.** SIGKILL, an OOM kill, or SIGXFSZ during intake can leave a 0700 run directory holding production literals, and print no run ID. Tiny signal windows around `Store.create` and after `done` do the same. Add a sweeper, such as `quaacks teardown --orphans`, or have intake sweep old runs with no finished marker.
- **The query isn't checked against the plan.** A SELECT query with an UPDATE's plan is accepted. Compare the relations and statement type.

- **Depends on:** 20260922-13.
- **Came from:** Both reviews of 20260922-13.
- **Design:** Step 1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-4. Parenthesize what pg_query deparses wrong. Done, see BACKLOG-COMPLETE.md.

### 20260924-5. Rerun 9d comparisons with the fixture loaded in reverse. Done, see BACKLOG-COMPLETE.md.

### 20260924-6. Narrow the 9d fail-closed rule for top-N queries.

Any `ORDER BY ... LIMIT` whose output includes a type left out of the tiebreaker (json, jsonb, xml, citext, hstore, PostGIS, interval, numeric[], and composites of those) is refused, even when the sort key is unique. That refuses every candidate for common top-N queries over such tables, and those are prime rewrite targets. Options: rerun both queries without their LIMIT and OFFSET, and refuse only on a real hidden tie. Or add `::text` sort keys for left-out columns.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **Design:** 9d.
- **Status:** todo

### 20260924-7. 9d comparator loose ends.

**Needs a decision,** from the reviews of 20260922-47 and 20260923-54:
- A precise check for ties at a cut: the rows before the tied group must match exactly, and the rest must come from the group. That would recover top-N originals that are refused today.
- Comparing intervals by value in the comparator.

- **Depends on:** 20260922-47.
- **Came from:** The reviews of 20260922-47 and 20260923-54.
- **Design:** 9d.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-8. Burndown loose ends.

**Needs a decision,** from the second review of 20260922-61:
- Refuse misuse, such as calling `record_dedupe` twice on the same Dedupe, or passing a stale or wrong-search `since`. Consider deriving `since` from the stored burndown for each search.
- Tie `record_single_candidate_test`'s report to the Dedupe's proposals.
- 5a-4's `unrenderable` refusal is counted as `hypopg_refused`.

- **Depends on:** 20260922-61.
- **Came from:** Both reviews of 20260922-61.
- **Design:** 15b.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-9. Load-order loose ends.

**Needs a decision,** from the reviews of 20260924-5:
- A third load order, such as rotating each table's run by one. It would catch a tie pick exactly in the middle of an odd-sized group, and a rare top-N heapsort pick, which both orders agree on today.
- Self-referencing foreign keys always fail the reverse load, as `reverse_load_failed`, which discards every candidate for tree-shaped tables. Keep such tables in forward order, or reverse them level by level.

- **Depends on:** 20260924-5.
- **Came from:** Both reviews of 20260924-5.
- **Design:** 9d.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-10. 5a-7 loose ends.

**Needs a decision,** from the reviews of 20260922-35:
- `rank` checks the literal-set names against the baseline, but not the values. Checking the values means the baseline must store the values it was measured with. Store them, or keep this a documented precondition.

- **Depends on:** 20260922-35.
- **Came from:** The reviews of 20260922-35.
- **Design:** 5a-7.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

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
- **Design:** Step 2.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-25. 3g redaction loose ends.

Still open from the reviews of 20260922-23, 20260924-11, and 20260924-16:
- **Decided, not built:** a plan more than about 48 levels deep can't go out through egress. Refuse it with a clear rule, and list it as unsupported in v1.
- Placeholders of different types can collide on one plan literal. With `$1 = 101` and `$2 = B'101'`, `X'05'` matches 101. No value leaks, but `$n` and the row annotation can be wrong. Prefer the candidate whose type matches the literal's cast.
- Expressions Postgres treats as equal but that are written differently get separate placeholders. They fail closed as `prepare_failed`.
- Date and timestamp normalization for row annotations, through the racetrack.
- Masks on planner-made TRUE and FALSE inflate the masked count.
- The 42P18 retry depends on English `lc_messages`, and preparing in a failed transaction gives 3B001, not 25P02.
- PredicateAtoms should use 3g's numbering. SingleCandidateTest and ArenaRunner should adopt Binding, so types get declared through PREPARE.

- **Depends on:** 20260924-16.
- **Came from:** The reviews of 20260922-23, 20260924-11, and 20260924-16.
- **Design:** 3g.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-26. 3c statistics loose ends.

Still open from the build and reviews of 20260922-19:
- pg_stats and pg_stats_ext silently hide columns the operator can't SELECT, so a role with limited privileges gets missing statistics with no error. Detect it, and refuse or record it.
- Values and names aren't converted to UTF-8, unlike SchemaDump. A non-UTF-8 database with non-ASCII values may be refused at the store write.
- The pg_stats inherited-filter mutant is killed only by luck, since row order decides which duplicate wins.
- A column type whose array delimiter isn't a comma, such as `box`, makes PgArray raise and abort 3c. List it as unsupported in v1, or skip it.

- **Depends on:** 20260922-19.
- **Came from:** The build and reviews of 20260922-19.
- **Design:** 3c.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-27. 3f classification loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-28. 3e literal set loose ends.

Still open from the build and reviews of 20260922-21:
- Django date filters get no worst-case or typical value. psycopg2 writes `'...'::timestamptz`, `'...'::date`, and `'{..}'::bigint[]`, which 3g turns into cast placeholders, and 3e always falls back on those. Handle a cast placeholder whose cast matches the column's type.
- The boolean `t`/`f` check at `literal_set.rb:326` survives mutation. Pin it with a planted bad value, or drop it.

- **Depends on:** 20260922-21.
- **Came from:** The build and reviews of 20260922-21.
- **Design:** 3e.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-29. Run server check loose ends.

Still open from the build and reviews of 20260922-25:
- Per-tablespace `random_page_cost` and `seq_page_cost` aren't checked. Record production's tablespace spcoptions in step 2, then compare them.
- `shared_preload_libraries` that change plans, such as pg_hint_plan, aren't compared.
- PGTZ and PGDATESTYLE in the operator's environment change both sessions' TimeZone and DateStyle, so the check compares session values, not server values.
- The debug_parallel_query test goes through the recorded-value path, not the boot_val path its name suggests.

- **Depends on:** 20260922-25.
- **Came from:** The build and reviews of 20260922-25.
- **Design:** Steps 2 and 4.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260924-30. Include extensions in the 3b schema dump. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20260925-1. Index DDL check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-2. Insert check loose ends.

Still open from the first review of 20260922-12:
- **Needs a decision:** values aren't pinned to be deterministic. TimeZone-dependent timestamptz literals and `'now'` or `'today'` are accepted. Fix the arena session's TimeZone, or refuse the special date and time inputs.
- Removing the `attisdropped` clause in COLUMNS_SQL stays green. Keep it or drop it.

- **Depends on:** 20260922-12.
- **Came from:** The first review of 20260922-12.
- **Design:** What goes into the enclave.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

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

### 20260925-18. Qualify loose ends.

Still open from the first review of 20260925-8:
- **Needs a decision:** wrap `Relations.check` in `Inventory::Production.read_only` in the qualify step, without a failing test first, since no test can observe it.
- Refuse a `$user` search_path entry that matches an existing schema other than the operator's own.

- **Depends on:** 20260925-8.
- **Came from:** The first review of 20260925-8.
- **Design:** Step 1, 3a.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260925-19. Schema-dump loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-20. Statistics step: test the read failure. Done, see BACKLOG-COMPLETE.md.

### 20260925-21. Name the function in a 3d refusal. Done, see BACKLOG-COMPLETE.md.

### 20260925-22. Name the missing input when a step's store entry is absent. Done, see BACKLOG-COMPLETE.md.

### 20260925-23. Anchor step loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-24. Index-search loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-1. Driver finds the jump server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-2. Build and record the run server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-3. Generator three follow-ups.

- Record the 5a-5 burndown: LLM candidates, plus any replacements asked for dropped ones, with the 5a-3 and 5a-4 reasons (DESIGN.md step 15b table).
- `CandidateDdlRedaction` masks `col = ANY (ARRAY[...])` completely, allowed MCVs included, because `operands` handles only `AEXPR_OP` and `AEXPR_IN`. Postgres prints IN lists this way, so partial-predicate values from plan filters get lost. Allow the same per-column MCV rule there.

- **Depends on:** 20260925-4.
- **Came from:** The build and second review of 20260925-4.
- **Design:** 5a-5, 15b.
- **Landed (2026-09-26):** MCV handling for `= ANY` arrays in CandidateDdlRedaction. Still open: the 5a-5 burndown record.
- **Status:** todo

### 20260928-1. `quaack setup`: one command for steps 2 through 4.

`quaack start` runs only intake (step 1), and `quaack run` starts at step 5. Nothing in the driver runs the steps between them, so today the operator types eleven `quaacks` commands on the jump server by hand: `inventory`, `run-server`, `qualify`, `schema-dump`, `statistics`, `volatility`, `classify`, `redact`, `literals`, `anchor`, and `racetrack-setup`, in that order. `e2e/run.rb` runs the same list itself, which is why the e2e run never noticed. DESIGN.md sections 2 through 4 already say "the driver runs" each of these.

Add `quaack setup --run <ID> [--host <h> --port <p> --racetrack-db <name> --arena-db <name>]`. It runs those steps over ssh in order, passing any run-server flags through to `quaacks run-server` (which falls back to `run_server_command` for missing ones). It resumes like `quaack run`: a step whose output the store already holds is skipped, which may mean adding the setup entries to the enclave's `Status::ENTRIES`. A failure stops it and prints only the step's rule, as `start` and `run` do.

- **Depends on:** None.
- **Came from:** Writing the user-facing README (2026-09-28).
- **Design:** Steps 2 through 4, "Where QUAACK runs."
- **Status:** todo
- **Open questions:** Should `quaack run` call setup itself when the run hasn't had it, so `start` then `run` is all an operator types? Should `quaack start` take the run-server flags and do setup too?

### 20260928-2. `quaack start --captured-at`.

`quaacks intake` takes `--captured-at <time>` (DESIGN.md step 1, 3h), but `quaack start` accepts exactly `--server`, `--query`, and `--plan`, so an operator starting from the laptop can't pass it. The clock is then anchored at intake time, which is wrong for a plan captured earlier. Accept an optional `--captured-at` and pass it through.

- **Depends on:** None.
- **Came from:** Writing the user-facing README (2026-09-28).
- **Design:** Step 1, 3h.
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

- DESIGN.md step 4 says a pooler must hold no idle server backends when the check runs, but not how the operator gets there. After an earlier run, or a psql session through the pooler, PgBouncer can hold several idle backends. Every one but the one QUAACK reuses then fails `run_server_other_clients`. Say how to clear them: PgBouncer's `RECONNECT` or `KILL`, waiting out `server_idle_timeout`, or `pg_terminate_backend` on the named pids. Also put this in the README's troubleshooting.
- `TestPostgres::Server#pgbouncer_port`: if PgBouncer's startup fails partway, such as on the readiness timeout, the next call starts `pgbouncer -d` again, and probably fails with a confusing error because one is already running.

- **Depends on:** 20260929-8.
- **Came from:** Review of 20260929-8, round one.
- **Design:** Step 4.
- **Status:** todo

### 20260929-17. Test the prompt-pack template's recovery from a failed build. Done, see BACKLOG-COMPLETE.md.

### 20260929-18. The prompt pack's leak check flags LLM replies that invent a sentinel date.

A hand run of `script/prompt_pack/run.rb orm_join group_having` finished, then `check_leaks` aborted. It found the `min_quantity_since` sentinel date, `2024-02-08`, in these three committed replies:

- `spec/fixtures/llm_corpus/group_having/10a-4/reply-claude-3.md`
- `spec/fixtures/llm_corpus/group_having/10a-5/reply-gemini-3.md`
- `spec/fixtures/llm_corpus/group_having/10a-9/reply-claude-3.md`

It's a false positive. No prompt in the corpus holds that date. The models generated runs of consecutive dates, such as 2024-02-01 to 2024-02-13, that happen to cross it. Still, the script can't finish on main today. Pick a fix: move the sentinel dates somewhere a model won't wander into, such as a far-off year, or scan only the prompts, since replies can't leak what the prompts never held.

- **Depends on:** nothing open.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness and prompt pack only.
- **Status:** todo

### 20260929-19. Schema dump selects `pg_catalog` when an extension lives there. Done, see BACKLOG-COMPLETE.md.

### 20260929-21. The full schema dump misses schemas that FK parent tables live in. Done, see BACKLOG-COMPLETE.md.

### 20260929-22. The subset dump takes a query table in a system schema.

With a `pg_toast` table as a query relation, the subset's `--table` dump fails with `pg_dump_failed`. With `pg_catalog.pg_namespace`, the subset probably gets catalog DDL. `Relations.check` may let catalog tables through, since they're relkind `r`. A query on a system catalog isn't something QUAACK can tune, so refuse it cleanly, with a rule such as `system_relation`, early in 3a. List it as unsupported in v1.

- Also from the 20260929-19 review: suppose no `public` schema exists, and every query relation and extension is in a system schema. Then the full dump gets no `--schema` flags, and pg_dump dumps every schema. Refusing system relations fixes this too.

- **Depends on:** 20260929-19.
- **Came from:** The build and review of 20260929-19.
- **Design:** 3a, 3b.
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
- **Design:** 3b, 4a.
- **Status:** todo

### 20260929-27. LLM seam: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20260929-28. Arena runner cancel tests: pin the start time, and bound the wait. Done, see BACKLOG-COMPLETE.md.

### 20260929-29. An operator's cancel shouldn't count as disproving a rewrite.

In Counterexamples (`counterexamples.rb:89-91`) and StepNine (`step_nine.rb:53-54`), a candidate query that fails with `statement_canceled` is recorded as a disproof, `match` false, just like a timeout. It errs on the safe side, since it can only reject a rewrite. But a cancel from someone else says nothing about the candidate: a valid rewrite is silently lost, and the report says "disproved in step 9 ... (rule statement_canceled)". RunDiscipline raises on a cancel that isn't its timeout. The arena side should probably do the same, and end the step with an environment error instead of recording a verdict.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** Steps 9 and 10.
- **Status:** todo

### 20260929-30. Step 8 pruning doesn't test its reliance on HypoPG oid maps.

Since 20260924-1, CanonicalPlan tells hypothetical indexes apart only through the oid map SingleCandidateTest builds. Step 8's cross-session plan match (ThreeConfigurationPruning), and 5a-7's IndexRanking, depend on it. Passing an empty or nil map from SCT fails SCT's own specs, but no pruning or ranking spec. Add a pruning test that would break if the same index got a different oid in each session and the map were missing.

- **Depends on:** 20260924-1.
- **Came from:** Review of 20260924-1, round one.
- **Design:** 5a-7, step 8.
- **Status:** todo

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
- **Design:** Step 4.
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
- Operators (`=`, `<>`, `LIKE`, `= ANY`) in the check's SQL aren't qualified. Exploiting that needs a deliberately built operator in `public`, and a blunt one breaks the planner check first. List it as unsupported in v1 in DESIGN.md step 4, or qualify with `OPERATOR(pg_catalog.=)`.

- **Depends on:** 20260930-9.
- **Came from:** Review of 20260930-9, round one.
- **Design:** Step 4.
- **Status:** todo

### 20260930-14. Unqualified catalog names elsewhere in the enclave.

The 20260930-9 builder listed catalog relations and functions the enclave still reads without `pg_catalog.`, outside step 4. Each can be shadowed by the same search_path setup. Qualify them, or decide per step which are safe, such as ones on the arena, which QUAACK builds itself.

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

### 20261001-17. Report payload: send what a legible report needs.

The first report from a real query (run 20261001T210856Z-3b7041a3, nothing beat the original) showed no query at all, and its lists couldn't be read. Most of what's missing never leaves the enclave. `quaacks report-payload` sends SQL, measurements, verdicts, and index lists only for the `top` labels, so a negative result gets none. Send, as shape-class data:

- **The original query, always.** The redacted query with the clock put back, as `original_sql` gives it today for an index-only winner.
- **Every stored rewrite,** not only the ranked ones: its SQL, its source (the LLM in 6a, or the operator in step 7, from `inferred`), and one fate. The fates: step 8 found its plans the same as the original's; step 9 disproved it, with the scenario and rule; step 10 disproved it, with the round; 14c found different results on production data; it was measured and wasn't better; it was ranked.
- **A step 8 prune is not a step 9 disproof.** `rewrite-test` stores a pruned rewrite as `passed` false with rule `discarded`, and NegativeResult sends that as a step 9 disproof. The report then says "rewrite_1: disproved in step 9 by scenario  (rule discarded)" for a rewrite that was never tested for correctness. Send the step 8 fate instead.
- **Every measured label,** not only `top`: its measurements, its per-literal verdicts, and the indexes it ran with (their built names), so the report can say what `original:top:1` was and how many blocks it read against the original.
- **Existing index sizes.** For `covered_by` and `makes_redundant`, send each existing index's `size_bytes` from the planner statistics with its name.
- **No repeats in 15a's lists.** In the real run the same DDL was listed twice under one search (`user_id, cached_due_date`), a partial index appeared once with `'deleted'::text` and once with `'deleted'`, and the rewrite's search repeated nearly all of the original's lines. Send each declined or existing index once, with the searches it came up in.

Trust boundary: SQL is the redacted query or a stored rewrite's SQL, DDL goes through CandidateDdlRedaction, and the rest is counts, names from the schema, and names from QUAACK's own constants. Test with sentinel literals, and update the whitelist in the protocol gem.

Rewrites the enclave refused on arrival aren't stored, so this task sends nothing for them. 20261001-19 counts them by reason.

- **Depends on:** 20260922-62, -63.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 15, 15a.
- **Status:** todo

### 20261001-18. Report: readable HTML.

The driver's half of the same complaint. Render the report so someone who has never read DESIGN.md can follow it:

- **Queries.** Show the original query first, then every rewrite, each pretty-printed. pg_query 6.2 does this (`PgQuery.deparse(tree, opts: PgQuery::DeparseOpts.new(pretty_print: true, ...))`), and it's already a driver dependency.
- **No internal labels or rule names.** `original:top:1: not_better` becomes words: the original query with the index on `submissions (assignment_id, user_id, cached_due_date)` read so many blocks on the slow values against so many for the original, which isn't more than 5% fewer. The same goes for `footprint_tie`, `same_plans`, `never_used`, and the rest.
- **Sizes.** Use the unit that fits (kB, MB, GB) with thousands separators, right-aligned, so indexes compare at a glance. Show the existing indexes' sizes in the last two columns of the index table.
- **Who proposed what.** Say where each idea came from and what became of it, by source: the LLM's rewrites, the operator's rewrites, the two mechanical index generators, and the LLM's index proposals. **Decided (the user, 2026-10-01):** a table with one row per source and one column per outcome. One table for rewrites (proposed, refused on arrival, same plan as the original, wrong results, not better, ranked) and one for indexes (proposed, already existed, planner ignored, built and measured, not better, ranked).
- **Burndown and LLM calls in English.** "Index suggestions for the original query: 2 calls", not "LLM calls, 5a-5: 2". Stage names too.
- **A negative result's index table isn't "Proposed indexes".** Nothing is being proposed. Call it what it is: indexes QUAACK built and measured.
- **Layout.** A summary of the verdict at the top, then readable typography, tables with aligned numbers, and SQL in code blocks. Plain CSS in the file, no scripts, no animation, and nothing loaded from the network.
- Update the README's "Reading the report" to match.

- **Depends on:** 20261001-17. The accountability counts for rewrites refused on arrival, and the burndown rows, need 20261001-19 and -20.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 15, 15a, 15b.
- **Status:** todo

### 20261001-19. Record the rewrite stages in the burndown.

In a real run the rewrite burndown has one row, step 8, and it's wrong. `Burndown.record` has two production callers, both step 8: `StructuralDiscard.record` under the search `rewrites` and `rewrite-prune` under `pruning`. The report sums the two, so one rewrite that came in and was pruned reads as "In 2, Out 1". Nothing records 6a, 6b, step 7, step 9, step 10, step 11, or step 14.

- Record every stage in DESIGN.md 15b's rewrite table. 6a and step 7: the rewrites the LLM gave and the operator gave, counted separately, and those refused on arrival, by rule. 6b: unmet assumptions, and step 7's warnings. Step 9: disproved by scenario, untested atoms, 9c retries. Step 10: disproved by round. Step 14: by minimax and 14c reason.
- Make step 8 one record per rewrite that adds up across its two halves, so "in" is the rewrites that reached step 8 and "out" is those that went on.
- Record the work totals: indexes built, measurement runs, fixture loads.
- A step that's skipped on a resumed run mustn't be counted twice, and one that's rerun mustn't either.

- **Depends on:** 20260922-61, -64.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** 15b.
- **Status:** todo

### 20261001-20. Record the index stages in the burndown.

In a real run the "Index candidates for the original query" table is empty. `record_dedupe`, `record_single_candidate_test`, and `record_llm_round` exist and are tested, but no step calls them, and nothing records 5a-1, 5a-2, or 5a-7. Wire them in, for the original's search and for each rewrite's (steps 8 and 11):

- `index-search`: 5a-1 and 5a-2 (candidates per generator), 5a-3, and 5a-4 with its set-asides.
- `index-test`: 5a-5 and 5a-6, one record per round, saying whether the refinement round ran.
- `index-rank`: 5a-7, combinations tested and what didn't make the cut.

This takes over the 5a-5 burndown bullet of 20260926-3 and the `set_aside:` wiring bullet of 20260927-19. Settle 20260924-8's `since` question on the way, since `index-test` runs in a different process from `index-search`.

- **Depends on:** 20260922-61, -64.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** 15b.
- **Status:** todo

### 20261001-21. Mechanical rewrite rules. Done, see BACKLOG-COMPLETE.md.

### 20261001-22. 6c: the rule generator, and `key_in_self_join`. Done, see BACKLOG-COMPLETE.md.

### 20261001-23. 6c: run the rules from `quaack run`, and count them. Done, see BACKLOG-COMPLETE.md.

### 20261001-24. 6c rule: `or_to_union`. Done, see BACKLOG-COMPLETE.md.

### 20261001-25. 6c rule: `not_in_to_not_exists`. Done, see BACKLOG-COMPLETE.md.

### 20261001-26. 6c rule: `distinct_join_to_exists`. Done, see BACKLOG-COMPLETE.md.

### 20261001-27. 6c rule: `unused_join_removal`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** todo

### 20261001-28. Tell the LLM what the rules already made.

6a's payload carries the rule-made rewrites' SQL, and the prompt says not to repeat them, as 5a-5 does with `mechanical_results`.

- **Depends on:** 20261001-23.
- **Came from:** 20261001-21.
- **Design:** 6a, 6c.
- **Status:** todo

### 20261001-29. Renumber step 6 in running order, and give the rules table examples.

DESIGN.md says mechanical rules (6c) run before candidate generation (6a) and the assumption check (6b). Number them in the order they run: 6c becomes 6a, 6a becomes 6b, and 6b becomes 6c.

- Rename everywhere, not only in DESIGN.md: README, BACKLOG.md's open tasks, code comments, error and report text, and names that carry the number, such as the protocol's burndown stages and LLM steps (`6a`, `6b`) and the driver's `STEP`. Rename in BACKLOG-COMPLETE.md too (the user, 2026-10-01), so every file uses one numbering.
- A store written before the rename holds burndown records under the old stage names. Say what a resumed run does with them: refuse, or read them under the new names.
- Add a before and an after SQL example for each rule to the mechanical rules table.

Do this after 20261001-22 to -28 land, or between two of them, never while one is in flight: it touches the same lines.

- **Depends on:** 20261001-22.
- **Came from:** The user, 2026-10-01.
- **Design:** Step 6.
- **Status:** todo

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
- **Design:** 6b, 6c.
- **Status:** todo

### 20261002-2. Running the rules: minor findings.

Minor findings from the build and both reviews of 20261001-23:

- **False rule bugs from steps 9 and 10.** `RuleBugs.disproved_by` counts any failed `rewrite_tested_<n>` whose rule isn't `discarded`. StepNine also fails a rewrite with `unsupported_order` (a WITH TIES original, for one) and with ArenaRunner's errors: `query_failed`, `statement_timeout`, `statement_canceled`, `begin_failed`. None compared results. Use an allowlist, as 14c's `MISMATCHES` does. Step 10 can't be told apart yet: `rewrite_round_<n>` doesn't store the round's rule, and `match` is false for `query_failed` too. Store it.
- **Postgres 18 removes the one-arm self-join itself,** so `key_in_self_join`'s rewrite of `t.id IN (SELECT t2.id FROM t t2 WHERE P)` plans like the original and step 8 prunes it. DESIGN.md 6c's table says each rule is something the planner doesn't do. Say which cases still matter (the `UNION ALL` arms, and servers before 18).
- `rewrite-check` has the double-store window that 6c closed: a call that dies after storing rewrites and before its marker stores them again on rerun.
- A rule-made rewrite that fails the checks counts in 6c's `failed_checks` and in step 8's drops, so 6c's out isn't step 8's in. Settle it with 20261001-19.
- A store where 6a ran before 6c existed gets its rule rewrites numbered after 6a's. DESIGN.md 6c says "before 6a's" without the exception.
- `CounterexampleStage` asks `status` again right after `RewriteStage` did.
- Test gaps where a wrong change stays green: `rule_bugs` when nothing beat the original (`report_payload.rb:74`); "shows the 6c row first" only checks against step 9 (`report_spec.rb:188`); a rerun with two or more stored rule rewrites, or after a call that stored only some; the 6c and step 8 records going in one write; the step 9 disproof line's source label (`report.rb:171`).
- The spec helper `compared` builds 14c's entry by hand. Call `ResultComparison.entry`.
- An empty `rules` renders "made by QUAACK's rules " with nothing after it (`report.rb:113`).
- In a negative result, a rule-made rewrite that step 8 pruned now reads "(made by QUAACK's rule ...): disproved in step 9 ... (rule discarded)". 20261001-17 fixes the root cause.

- **Depends on:** 20261001-23.
- **Came from:** The build and both reviews of 20261001-23.
- **Design:** 6c, step 9, step 10, 15, 15b.
- **Status:** todo

### 20261002-15. 6c rule: `polymorphic_key_copy`, checked against the data.

- **Note:** First filed as 20261002-3. Renumbered when merging another machine's work, which had already used -3.

A hand-tuned Canvas query got much faster by repeating a predicate across a join. The original read:

```sql
FROM submissions JOIN assignments ON assignments.id = submissions.assignment_id ...
WHERE assignments.context_type = 'Course' AND assignments.context_id = 2588916 AND submissions.user_id = 2418270 ...
```

The tuned version keeps every predicate and adds `submissions.course_id = 2588916`, which lets Postgres narrow `submissions` before the join. The planner doesn't do this itself, because the query never states `submissions.course_id = assignments.context_id`.

The rule: when a query joins `s.<x>_id = a.id` and filters `a.<p>_type = '<Klass>'` and `a.<p>_id = <const>` (Rails's polymorphic convention), and `s` has a column named Rails's way for `<Klass>` (`Course` becomes `course_id`, and `Foo::Bar` becomes `foo_bar_id`), add `s.<klass>_id = <const>` and keep the original predicates. If a foreign key from that column exists, it must point at `<Klass>`'s table, and the rule doesn't fire otherwise.

The rewrite only adds a predicate, so it can drop rows but never add them. It's sound only if every joined row has `s.<klass>_id = a.<p>_id` when `a.<p>_type = '<Klass>'`. The catalog can't prove that from naming alone, so this rule is a heuristic, unlike the sound rules 6c describes. It's checked against the data instead:

- The rule states a new assumption kind, such as `denormalized_equal` (child column, parent column, type column, and type value).
- 6b checks it with one query on the real database, in the enclave: `EXISTS` a joined row where `a.<p>_type = '<Klass>'` and `s.<klass>_id IS DISTINCT FROM a.<p>_id`. Only the boolean leaves the jump server. If any such row exists, the assumption is unmet and the rewrite is dropped.
- The report marks the rewrite as resting on an empirical assumption, one the data holds today but the schema doesn't enforce, and names the columns.
- Steps 9 and 10 test it like any other rewrite. If they disprove it, the report doesn't call that a rule bug, since the assumption was empirical.

Open questions to settle before building: the cost of the `EXISTS` check on large tables (a statement timeout, and treat a timeout as unmet?), what to do when two candidate columns could match, and which Rails inflections to support (STI, namespaced classes, irregular plurals for the table check).

DESIGN.md 6c says every rule is sound by design. Update it to allow heuristic rules whose assumptions are checked against the data, and list the new assumption kind in 6b.

- **Depends on:** 20261001-22, 20261001-23.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6b, 6c, 15.
- **Note (2026-10-02, answers):** The data check runs on the racetrack with a 300000 ms statement timeout, and a timeout or error is unmet. Refuse when two columns could match. Naming: CamelCase to snake_case, `::` to `_`. If an FK exists, its target table must be the snake name plus `s` or `es`, or the rule doesn't fire. The rule never reads the type literal: it turns each candidate `<x>_id` column into its class name and asks `Literals#holds?` whether the placeholder equals it.
- **Status:** todo

### 20261002-16. `distinct_join_to_exists`: handle what Rails sends.

- **Note:** First filed as 20261002-4. Renumbered when merging another machine's work, which had already used -4.
- **Note (2026-10-02):** Set aside by the user until 20261001-26 lands. It has since landed (merged from origin/main), with `t.*` support. Its minor findings went to 20261002-4, and they overlap with this task's select-list expressions.
- **Note (2026-10-03):** Back in the rule queue, after 20261002-15 (the user).

A hand-tuned Canvas query got much faster by removing a `DISTINCT` over a join:

```sql
SELECT DISTINCT users.*, sortable_name COLLATE public."und-u-kn-true"
FROM users JOIN enrollments ON users.id = enrollments.user_id
WHERE enrollments.course_id = 341535 AND ...
ORDER BY sortable_name COLLATE public."und-u-kn-true" ASC, users.id ASC
LIMIT 20 OFFSET 0;
```

This is `distinct_join_to_exists`'s case, but the rule must handle three things 20261001-26's entry doesn't mention. Check what 20261001-26 landed, and add whichever of these it lacks:

- `t.*` in the select list. It holds the kept table's key.
- Select-list expressions that read only the kept table's columns, such as `col COLLATE ...`, a cast, or a function call. A volatile function stays refused.
- `ORDER BY`, `LIMIT`, and `OFFSET`, carried over unchanged. Their expressions read only the kept table, as `DISTINCT` already requires them to appear in the select list.

Test it with this query's shape. Also test that the rule refuses when the select list reads a column of a table it would remove.

- **Depends on:** 20261001-26.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Status:** todo

### 20261002-17. 6c rule: `implied_predicate_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261002-6. 6c rule: `shared_scan_cte`.

A hand-tuned Canvas query got much faster by reading `submissions` once instead of twice. The original joins `submissions` and `submissions AS assessor_asset`, and each copy filters on the same `course_id IN (2883, 4906, ...)`. The tuned version moves the filtered table into a `WITH ... AS MATERIALIZED` CTE and reads it twice. The scan happens once, and the CTE stops the planner from choosing its bad join order.

The hand-tuned version also moved `submissions.workflow_state <> 'deleted'` into the CTE, so it applied to `assessor_asset` as well, which the original never did. That isn't equivalent. The rule must move only the conjuncts every copy shares.

The rule: when a table is read two or more times in one `FROM` tree, and the copies' top-level `WHERE` conjuncts (or inner-join `ON` conjuncts) share one or more items that each read only that copy, build `WITH <name> AS MATERIALIZED (SELECT * FROM t WHERE <shared conjuncts>)`. Point every copy at it under its old alias, and leave each copy's other conjuncts where they were. Compare conjuncts by their deparsed form, with the copy's alias replaced by a placeholder. Refuse when:

- A copy is on the nullable side of an outer join.
- A shared conjunct calls a volatile function.
- The query already has a CTE of that name.
- A copy is in a subquery or CTE rather than the top-level `FROM`.

It needs no catalog facts, since every copy reads the same snapshot, so it states no assumptions. It isn't always faster: a join against a materialized CTE can't use the table's indexes. Steps 8 onward decide, as for any rewrite. Make sure step 8's index search and 12a treat the CTE correctly, by indexing the base table that the CTE's own scan reads.

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c, 8.
- **Note (2026-10-02, answers):** Match shared conjuncts with 20261002-17's `Literals#same?`, never by reading values.
- **Note (2026-10-03, answers):** Name the CTE `quaack_scan_of_<table>`.
- **Status:** todo

### 20261002-7. 6c rule: `transitive_predicate_copy`.

The query behind 20261002-6 has `enrollments.course_id = assessor_asset.course_id` in an inner join's `ON`, and `assessor_asset.course_id IN (2883, ...)` in `WHERE`. Together they imply `enrollments.course_id IN (2883, ...)`, so a rule can add that predicate. Postgres carries a constant equality across an equi-join (equivalence classes), but not an `IN` list, a range, `BETWEEN`, or `IS NOT NULL`, so it can't use that implied filter to narrow `enrollments` early.

The rule: for each equality `a.x = b.y` in a top-level `AND` of `WHERE` or of an inner join's `ON`, and each conjunct on `a.x` alone that's an `IN` list of constants, a comparison with a constant (`<`, `<=`, `>`, `>=`), or `BETWEEN` two constants, add the same conjunct on `b.y`, unless one is already there. Keep the original. Refuse when:

- `x` and `y` have different types, or the equality isn't the type's default btree equality.
- Either column has a nondeterministic collation.
- Either side is on the nullable side of an outer join.

It's sound with no catalog facts: any row that passes has `a.x = b.y`, so `b.y` passes whatever `a.x` passes. It states no assumptions. Apply it to a fixed point within one rule call, so chains such as `a.x = b.y = c.z` carry across in one step.

20261002-15 also copies a predicate, but its proof comes from the data. This rule's proof comes from the query, so it stays a sound rule. Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-03, answers):** Don't copy `IS NOT NULL`. Put the copy in the same place as the source conjunct: the top-level `WHERE`, or that inner join's `ON`. The copy reuses the source's placeholders, and the "already there" check uses `Literals#same?`.
- **Status:** todo

### 20261002-8. 6c rule: `cte_hoist_dedupe`.

A hand-tuned Canvas user search got much faster by hoisting a CTE. The original is a `UNION` of five arms in a subquery in `FROM`. Each arm, and the outer `WHERE`, has `users.id IN (WITH users_in_account AS MATERIALIZED (SELECT user_id FROM user_account_associations WHERE account_id = 1) SELECT user_id FROM users_in_account)`. Postgres builds each of those six identical CTEs separately. The tuned version defines it once in a top-level `WITH`, and each `IN` reads from that.

The rule: find every CTE, at any depth, whose body deparses to the same SQL as another's, and that has the same materialization option (`MATERIALIZED`, `NOT MATERIALIZED`, or none). Define one copy in the top-level `WITH`, and point every reference at it, renaming it if its name clashes there. Refuse a CTE that:

- Is correlated, reading a column from outside its own body.
- Is recursive or modifies data.
- Calls a volatile function.
- Would be hidden by a nearer CTE of the same name at some reference after hoisting.

It's sound with no catalog facts, since every copy reads the same snapshot and gives the same rows, and it states no assumptions. Hoisting a single copy changes nothing, so fire only when at least two copies merge.

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-02, answers):** Match CTE bodies with 20261002-17's `Literals#same?` for their placeholders, never by reading values.
- **Note (2026-10-03, answers):** Merge CTEs with any materialization option, as long as every copy has the same one, and keep it. Merged plain CTEs may become materialized, and steps 8 onward decide whether that helps. A hoisted CTE whose name clashes at the top level is renamed `quaack_cte_<n>`.
- **Status:** todo

### 20261002-9. 6c rule: `union_outer_filter_removal`.

The query behind 20261002-8 filters the `UNION`'s result with `WHERE users.id IN (SELECT user_id FROM users_in_account) AND users.workflow_state <> 'deleted'`, when every arm already applies both conjuncts, in its own `WHERE`, to the column it outputs. The outer copy can't drop a row, but Postgres still runs it: here, as a semi-join over the union's result.

The rule: for a query whose `FROM` is one subquery that's a `UNION` or `UNION ALL` (or such a subquery under inner joins), drop a top-level `WHERE` conjunct on that subquery's output columns when every arm has the same conjunct in its top-level `WHERE`, applied to the expression each arm outputs in those columns. Map output columns by position, expanding `t.*` from the catalog. Compare by deparsed form, with the column references replaced by placeholders. A conjunct with a subquery matches only when the subqueries deparse the same and read the same CTE (after 20261002-8, the same top-level one). Refuse when:

- A conjunct calls a volatile function.
- An arm outputs the column as an aggregate.
- An arm has the conjunct only in `HAVING`.
- The set operation is `INTERSECT` or `EXCEPT`.

It's sound with no catalog facts: every row an arm outputs passed that arm's `WHERE`, and `GROUP BY` doesn't change a grouped row's value for a column it groups by or one that depends on it. It states no assumptions.

Add it to 6c's table in DESIGN.md. List it after `cte_hoist_dedupe`, so it sees one shared CTE.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-02, answers):** Match conjuncts with 20261002-17's `Literals#same?` for their placeholders, never by reading values.
- **Status:** todo

### 20261002-10. 6c rule: `existence_in_flip`.

A hand-tuned Canvas existence check got much faster by turning it inside out. The original:

```sql
SELECT 1 AS one FROM enrollments JOIN courses ON ... JOIN assignments ON ...
WHERE enrollments.user_id = 6504 AND ...
  AND assignments.id IN (SELECT assignment_id FROM assignment_configuration_tool_lookups WHERE tool_product_code = 'turnitin-lti' AND ...)
LIMIT 1;
```

The tuned version reads `assignment_configuration_tool_lookups` with its filters, and checks the rest with `EXISTS (SELECT 1 FROM enrollments JOIN courses ... JOIN assignments ... WHERE <the original's other conjuncts> AND assignments.id = assignment_configuration_tool_lookups.assignment_id)`, still under `LIMIT 1`. Postgres could choose that plan for the semi-join itself, but with `LIMIT 1` it bets on a fast-start plan from the other side and loses.

The rule: when a query is an existence check, rewrite it so the `IN` subquery's table drives. An existence check here means:

- Every select-list item is a constant.
- It has `LIMIT 1`.
- It has no `DISTINCT`, `GROUP BY`, aggregate, window function, `HAVING`, `OFFSET`, or locking clause.

The query must also have a top-level `WHERE` conjunct `x IN (SELECT y FROM S WHERE P)` whose subquery is uncorrelated and has no `LIMIT`, `OFFSET`, aggregate, set operation, or volatile function. The rewrite is `SELECT <the same constants> FROM S WHERE P AND EXISTS (SELECT 1 FROM <the original FROM> WHERE <the original's other conjuncts> AND x = y) LIMIT 1`. Keep the original's CTEs at the top. Rename `S`'s aliases if they clash with the original's.

It's sound with no catalog facts. Both return one row exactly when some combination of rows passes every predicate with `x = y`. The `IN` and the `=` use the same operator, so NULLs behave the same. It states no assumptions. It needs `LIMIT 1`: with a higher limit, or none, the two can return different numbers of rows.

Leave these for later: the same flip inside an `EXISTS (...)` body, and `x = ANY (SELECT ...)`.

When several `IN` conjuncts qualify, emit one candidate per conjunct, within the cap of ten (the user, 2026-10-03).

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Status:** todo

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

- The fresh alias can collide with a table name or alias that no column mentions: `Tree::Names` collects only names in column references. The rewrite then fails to plan and step 8 drops it. Collect FROM names too.
- Untested lines: the fresh alias avoiding a taken name (`not_in_to_not_exists.rb:178`); `assumptions.uniq` (`:83`); `realias!` keeping column aliases (`:187`).
- A column whose type is a domain with a NOT NULL constraint doesn't count as not null, since `AssumptionCheck` reads only `pg_constraint`'s `n` and `p`. Conservative: a missed rewrite, not a wrong one.
- The rule assumes `=` gives true or false for two non-NULL values. A user-defined `=` that returns NULL breaks that. Noted in the rule's header.
- Extensions for later: row-valued NOT IN, set-operation subqueries arm by arm, NOT IN outside the top-level WHERE, `<> ALL`.

- **Depends on:** 20261001-25.
- **Came from:** The build and both reviews of 20261001-25.
- **Design:** 6b, 6c.
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
- **Design:** 6b, 6c.
- **Status:** todo

### 20261002-5. `or_to_union`: minor findings.

Minor findings from both reviews of 20261001-24:

- **A clock literal outside the OR isn't anchored.** In `WHERE c.due >= 'today' AND (o.note = 'x' OR c.archived)`, the conjunct is copied into each arm, so its `$n` appears twice. `LiteralSet::Feeds` (`literal_set.rb:186`) then marks it `:shared_placeholder`, `ClockLiterals.implicit_types` finds no type, and the rewrite reads the real clock while the original reads the anchor. Steps 9, 10 or 14c could then report a sound rewrite as a rule bug. Fix in 3h: type a placeholder when every occurrence feeds a column of the same date type.
- **Guarding arms can raise.** Split arms are all evaluated, so `i.qty = 0 OR i.total / i.qty > 10 OR o.vip` raises division by zero where the original returns rows. Never wrong rows. Refuse, or note it in DESIGN.md.
- With LIMIT and no ORDER BY, the rewrite returns a different but valid set of rows. Confirm steps 9 and 10 don't report that as a rule bug.
- Test gaps: the `@columns` cache key's schema part (`catalog.rb`); column names of 62 or 63 characters, which the `_1` suffix pushes past Postgres's limit (no rewrite results, but untested).
- DESIGN.md's row leaves out several refusals: a subquery in the select list or ORDER BY; unqualified columns, a bare `*`, or ORDER BY an output name; an unnamed cast, COALESCE or CASE over a column; NATURAL or USING joins; ONLY; column aliases.
- Extensions for later: composite keys, GROUP BY, outer joins, a bare `*`.

- **Depends on:** 20261001-24.
- **Came from:** Both reviews of 20261001-24.
- **Design:** 3h, 6c.
- **Status:** todo

## After version 1.

These tasks are worth doing, but they don't block version 1. Pick them up after the full pipeline (20260922-65) works.

### 20260923-6. Test the runtime check's environment scrubbing. Done, see BACKLOG-COMPLETE.md.

### 20260923-8. Unit-test the RepoGems helper. Done, see BACKLOG-COMPLETE.md.

### 20260923-9. Close the test gaps in the spec task guards. Done, see BACKLOG-COMPLETE.md.

### 20260923-10. Stop local RSpec options from filtering out boundary specs. Done, see BACKLOG-COMPLETE.md.

### 20260923-41. Support DML statements.

INSERT, UPDATE, DELETE, and MERGE, at the top level or inside a CTE. A slow production query can be DML, but steps 9 and 14 compare result rows, so this needs a design for comparing effects rather than rows. RelationQualifier's DML-target handling was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-42. Support SELECT INTO and locking clauses.

`SELECT ... INTO` and `FOR UPDATE`, `FOR SHARE`, and similar. Job-queue queries often use `FOR UPDATE SKIP LOCKED`. DESIGN.md refuses locking clauses in rewrite candidates, so decide how the original and its candidates are compared. RelationQualifier's locking-clause skip was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-43. Support TABLESAMPLE.

The `system` and `bernoulli` methods are volatile, so results aren't repeatable. The TABLESAMPLE handling in FunctionCalls and PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-44. Support richer functions in FROM.

`ROWS FROM(...)` over several functions, column definition lists, and non-FuncCall items in a function's place. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-45. Support JSON_TABLE and SQL/JSON.

JSON_TABLE (`JsonTable`) and the SQL/JSON constructors and functions: JSON_OBJECT, JSON_ARRAY, JSON_VALUE, JSON_QUERY, JSON_EXISTS, IS JSON, JSON(), JSON_SCALAR, JSON_SERIALIZE, and the JSON aggregates. The JSON_TABLE path swap in PredicateAtoms was last present in 6507105. The pg_query deparser segfaults on some forms, so test in child processes. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-46. Support XMLTABLE and XML functions.

XMLTABLE (`RangeTableFunc`), XmlExpr (including IS DOCUMENT and XMLROOT), and XmlSerialize. XMLROOT keyword handling in PredicateAtoms was last present in 6507105. Some XML deparse output is invalid SQL. See 20260923-30. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-47. Support CTE CYCLE and SEARCH.

The CYCLE mark redaction in PredicateAtoms, including typed marks, was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-48. Support rows outside row comparisons.

20260924-31 made plain row comparisons, such as keyset pagination `(created_at, id) < ($1, $2)`, supported in v1. `SupportedSql` still refuses a row anywhere else, as `RowExpr`: `ROW(a, b)` in the select list, `(a, b) IN ((1, 2), ...)`, `(a, b) = ANY(...)`, a row compared with a subquery, `IS DISTINCT FROM` between rows, nested rows, and one-element rows such as `ROW(a)`. Supporting them means adding them to `SupportedSql` and handling them in every walker that 20260923-33 lists.

Gaps in the supported comparisons are tracked elsewhere: pools for `=`/`<>` and expression rows in 20260926-55, and dropped keyset tie rows in 20260926-59.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-49. Support GROUPING SETS, ROLLUP, and CUBE.

GroupingSet, `GROUP BY ()`, and GROUPING(). The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-50. Support SIMILAR TO.

The SIMILAR TO reader in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-51. Support field selection.

`(t).x`, `(f(x)).y`, `(t).*`, and mixed forms. The volatility check has to see functions called through attribute notation. See 20260923-35. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-52. Support other SQL-syntax functions.

normalize, IS NORMALIZED, SYSTEM_USER, and COLLATION FOR. The normal-form keyword handling in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and step 1.
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
- A resumed run still restarts step 10 at round 1 (from 20260926-25).

- **Depends on:** 20260926-21, 20260926-25.
- **Came from:** Build of 20260926-21 and -25.
- **Design:** Step 10; CLAUDE.md Development.
- **Status:** todo

### 20260926-30. Result comparison loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-31. Minimax and operator rewrite loose ends. Done, see BACKLOG-COMPLETE.md.


### 20260926-32. Measurement test gaps.

- No real-Postgres test produces an unstable literal. Making block counts move between runs deterministically, inside a read-only transaction, was hard, so only the `summarize` unit test covers that path.

- **Depends on:** 20260926-27, 20260926-31.
- **Came from:** Their build.
- **Design:** Step 13.
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

- The StepNine dropped count isn't stored anywhere readable. Store it in `rewrite_tested_<n>` and show it in the report.
- "Whether step 10 covered them" shows only the `evidence` flag, because per-round covered shapes aren't stored.
- A plan node with no `Schema` is matched to a table by name only when exactly one subset table has that name.
- LLM call counts on a resumed run include only calls from the current process.

- **Depends on:** 20260926-34, -38.
- **Came from:** Their build and review.
- **Design:** Step 15.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-43. Payload fidelity loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-44. Expression-unique loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-45. Driver, LLM client and harness items left from 20260924-13, -14, -20.

- **Needs a decision:** lazy-loading `anthropic` would save about 0.5s per CLI start, but breaks `runtime_boundary_spec`, which expects every driver file to load the gem. Change that spec to build a client first, or keep the eager load.
- **Pump/Child rework:** cover a child that closes stdout and then reads stdin, and a grandchild that holds stdout open.
- **Per-example timeout for driver specs,** tuned so it doesn't cause flakes.
- **JSON harness column:** add a JSON column to the harness schema.

- **Depends on:** 20260924-13, -14, -20.
- **Came from:** The build of those tasks.
- **Design:** Where QUAACK runs, LLM client.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

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
- **Design:** 3b, 3h, step 1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-50. FROM functions: non-FuncCall items crash. Done, see BACKLOG-COMPLETE.md.

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty. Done, see BACKLOG-COMPLETE.md.

### 20260926-52. Anchor the clock in rewrite candidates too. Done, see BACKLOG-COMPLETE.md.


### 20260926-53. Candidate clock anchoring loose ends.

- `RewriteEntry.run_sql` falls back to `"sql"` for entries without `anchored_sql`. Only hand-written spec fixtures and stores from before the change hit it. Consider requiring `anchored_sql` and updating the fixtures (about 30 writes).

- **Depends on:** 20260926-52.
- **Came from:** 20260926-52 build and review.
- **Design:** 3h.
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
- **Design:** Step 9.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

### 20260926-56. Items left from 20260923-27, -28, -35, -38.

- **Needs a decision:** functions, types, operators, and names inside string literals aren't qualified. Rewrite them, or refuse them?
- **Shared parse helper:** merge PlanExpression's parse helper with CanonicalPlan's parse step. Refactor only, but it changes a shared signature.
- **ArgumentError rules:** give rules to the ArgumentErrors raised in PredicateAtoms and IndexCandidate. For IndexCandidate, decide whether to change the error class callers rescue.
- **Operator messages:** a driver-side table mapping rules to text for operators. The texts need deciding.

- **Depends on:** 20260923-27, -28, -35, -38.
- **Came from:** Their build and reviews.
- **Design:** 3a, 3d, step 1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
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
- `VOLATILE_FUNCTIONS` in `value?` is a fixed name list matched on the last name only. It misses user-defined volatile functions and wrongly flags a user function with a built-in's name. It's a backstop behind step 3d.

- **Depends on:** 20260927-13, -15.
- **Came from:** Review of 20260927-13 to -16.
- **Design:** 5a-1.
- **Status:** todo

### 20260927-18. Make step 9 scenarios load instead of skipping them.

20260926-60 skips a step 9 scenario whose fixture won't load and marks its atoms untested. That's acceptable for now, but a scenario that won't load means those atoms go untested. Find out why such scenarios fail (constraints or triggers the scenario builder doesn't model: exclusion constraints, triggers on the arena tables, complex CHECKs, and so on), and make the builder produce rows that load. Or refuse the query up front with a clear rule, so atoms aren't silently left untested.

Also: 9d still disproves every candidate when a scenario won't load (`:fixture_load_failed`). That fails safe for v1, but it rejects correct rewrites; once scenarios load, it stops mattering. And add a guard-level spec that a `:query`-step `ArenaRunner::Error` isn't swallowed by `VacuityGuard.loaded_exercised_atoms` (today, removing the step check stays green).

- **Depends on:** 20260926-60.
- **Came from:** User direction, 2026-09-27.
- **Design:** Step 9.
- **Status:** todo

### 20260927-19. Set-aside loose ends.

These are minor findings from the review of 20260927-11:
- There's no cap on set-asides. The worst realistic case is about 2 extra real builds per low-cardinality table, per search (about 18 for a 3-table join with 2 rewrites). Add a per-search cap, or limit set-asides to the moved key-only variant.
- `Burndown.record_single_candidate_test(set_aside:)` has no production caller, so set-aside counts don't show up in real runs. Wire it in.
- There are two low-cardinality thresholds: the generator's hardcoded 50 (`TableCandidates::LOW_CARDINALITY`) and 3f's configurable one used by `UnusedSetAside`. Unify them.

- **Depends on:** 20260927-11.
- **Came from:** Review of 20260927-11.
- **Design:** 5a-1, 5a-4, 12a.
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
- The per-query spec "finds the wrong rewrite whenever the 6a reply holds the wrong condition" runs no expectation for queries whose reply lacks the condition.
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

Each ask is stateless: it sends its whole conversation, and no provider holds a session. So asks can move between providers freely, with one exception. A multi-turn exchange must stay on one provider: 5a-5's replacement round, 10a's counterexample rounds, and the re-ask from 20260928-4. Otherwise a model is shown another model's reply as if it were its own.

Ideas to settle before building:
- **Configuration.** An `llms` list in driver.json, each entry shaped like today's `llm` block, with a name.
- **Routing policy.** Options:
  - round-robin per ask;
  - pinning steps to providers;
  - fan-out, where 6a and 5a-5 ask every provider and take the union, deduplicated by the usual checks;
  - failover, moving on to the next provider after `llm_rate_limited` or `llm_unavailable`, and remembering that for the rest of the run.
- **Adversarial pairing.** Have 10a use a different model from the one that wrote the rewrite, so the model hunting for counterexamples isn't grading its own work.
- **Burndown.** Count calls per provider as well as per step (15b), so the report shows where the calls went.
- **Cost.** Fan-out multiplies calls, so make it opt-in per step.

- **Depends on:** 20260928-4.
- **Came from:** The user, 2026-09-29.
- **Design:** Where QUAACK runs, 5a-5, 6a, 10a, 15b.
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
- **Design:** 5a-5.
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

The 5a-5 payload's `stats` covers every column of each table the query uses. On wide tables that came to 52k characters for one query. Send stats only for the columns the query references anywhere (select list, WHERE, JOIN, GROUP BY, ORDER BY), found with pg_query from the qualified query. Keep the stored statistics whole. Update DESIGN.md (5a-5) to match. Settle against DESIGN.md first whether 6a or any other LLM step sends stats too.

- **Depends on:** 20261001-3.
- **Came from:** The user, 2026-10-01.
- **Design:** 3f, 5a-5.
- **Status:** todo

### 20261001-8. `quaack run` shows its progress. Done, see BACKLOG-COMPLETE.md.

### 20261001-9. The full schema dump always includes the `dba` schema. Done, see BACKLOG-COMPLETE.md.

### 20261001-10. The full schema dump finds the schemas its objects reference, and takes overrides.

Replaces the hard-coded `dba` of 20261001-9. Objects in the dumped namespaces, such as functions, can reference schemas that weren't dumped, and then arena won't load. Find those schemas and add them to the dump, for example by parsing the dump with pg_query and collecting the schemas named in function bodies, defaults, types, and the like, then dumping again until nothing new turns up. Also let the operator name extra schemas to include, for example a list in the `quaacks` config. Settle the details with the user before building: which references count, whether a dependency query against the catalog (`pg_depend`) beats parsing, and where the override lives.

Also add an arena spec that loads a dump whose function references `dba` objects, end to end. That was the original `arena_dump_load_failed` symptom, and the review of 20261001-9 found no test covering it.

Handle objects the operator can't read. Including the `dba` schema made pg_dump fail with `pg_dump_failed`, because the operator's role had no read access to two of its tables. pg_dump locks every table it dumps, so one unreadable table fails the whole dump. Dump only the objects the dumped namespaces actually depend on, not whole extra schemas, and then decide what to do about a needed object that still can't be read. For example, check privileges first with `has_table_privilege` and refuse with a rule that names the problem (`dump_object_unreadable`) and counts the unreadable tables, rather than letting pg_dump fail with no reason. Settle this with the user too.

- **Depends on:** 20261001-9.
- **Came from:** The user, 2026-10-01.
- **Design:** 3b, 4b.
- **Status:** todo

### 20261001-11. Progress output: minor findings.

The review of 20261001-8 found two minor items:

1. Nothing tests the skip line that step 7 prints on a resumed run with `--rewrites`. If that line broke, every later `[n/18]` number would be off by one, and no spec would catch it. Nothing tests the steps 9-10 skip note for each rewrite either. Add a cli_run progress spec that resumes with `rewrites_generated` and `operator_rewrites_checked` set and passes `--rewrites`. It should assert `[6/18] step 7: already done, skipping`, and cover the steps 9-10 note too.
2. In `Progress#step`, if the first `say` raises, such as EPIPE on stderr, `start` is still nil. The rescue's `since(nil)` then raises a TypeError that hides the real error. Set `start` before the first `say`.

- **Depends on:** 20261001-8.
- **Came from:** The review of 20261001-8, 2026-10-01.
- **Design:** The `quaack run` command.
- **Status:** todo

### 20261001-12. `quaack run`'s progress lines say in plain English what each step does, and 12a shows each index it builds. Done, see BACKLOG-COMPLETE.md.


### 20261001-13. Streamed progress: minor findings.

The review of 20261001-12 found two minor items:

1. Progress lines count toward the transport's output cap. A 12a run that builds a very large number of indexes could hit `output_too_large` from the progress lines alone. That fails safe, but consider leaving room for one line per index, or not counting progress lines toward the cap.
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

### 20261003-3. `implied_predicate_removal`: refuse casts and volatile duplicates, reach subqueries, close test gaps.

Minor findings from the second review of 20261002-17:

- **Casts on a literal.** `columns.rb`'s `value()` strips the cast before comparing. So `grade = 2.7::int AND grade < 2.8` on a numeric column, or `created_at = '2020-01-01 10:00'::date AND created_at > '2020-01-01 05:00'`, drops a predicate the equality doesn't imply. Refuse when the literal has a cast, unless it's the column's own type.
- **Volatile exact duplicates.** `random() < 0.5 AND random() < 0.5` loses a copy, which changes the results. Never drop a duplicate that calls a volatile function.
- **Subquery WHEREs and UNION arms are never reached.** `Tree.find` stops at the first `SelectStmt`, but the task asked for each `AND` of a subquery's `WHERE`. Reach them, or say in DESIGN.md that v1 only does the top level.
- **Mutations that survive:**
  - dropping the column's `COLLATE` in `typed`;
  - dropping the shape half of `Literals#same?`. The test's title claims to cover it. Pin it or remove it.
- **Missing tests:**
  - an inner join's ON equality dropping a WHERE `<>` or range predicate;
  - a positive `NOT IN` case;
  - an ON clause that dropping empties.
- **`Literals` has no redacting `inspect`,** unlike `Binding`. Inspecting one would print the placeholder map, values included.

- **Depends on:** 20261002-17.
- **Came from:** The second review of 20261002-17, 2026-10-03.
- **Design:** 6c.
- **Status:** todo

### 20261003-4. Intake unreadable causes: minor findings.

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
- **Design:** Step 1.
- **Status:** todo

### 20261003-5. `rake full`: harden the stamp and close test gaps.

Minor findings from the first review of 20261003-2:

- **`rake spec full` writes the stamp without the full replay.** So does `rake default full`. Rake runs a task only once per invocation, so `full`'s invoke of `:spec` does nothing after `spec` has already run. Make `full` run its suites itself, or refuse when `spec` already ran.
- **The stamp spec doesn't read the real version constants.** `full_replay_stamp_spec.rb:15` parses the version files with a regex, using a copy of the Rakefile's path map. If the regex stops matching, the Rakefile stamps `null` and the spec compares nil with nil, so it passes. Compare against the loaded `Quaack::*::VERSION` constants, and refuse to stamp a nil.
- **Exporting `QUAACK_FULL_REPLAY=1` makes plain `rake` skip the stamp check** (`full_replay_stamp_spec.rb:19`).
- **No test covers RuboCop failing during `rake full`** (`Rakefile:79`). The stamp is skipped today, but nothing pins that.
- **The `reject { it == EMPTY }` in `spec/support/pipeline_replay.rb` is untested.** Without it, a query with no replies at all would run the all-empty variant instead of failing.
- **CLAUDE.md wording.** The Docker and pg_dump bullets still say "the full check", which now reads as `rake full`, though both apply to plain `rake` too.
- **Where the enclave suite's time goes.** The builder's profile: about 9½ minutes, led by `standalone_require_spec` (39s), then `candidate_runs_step_postgres_spec` (26s), then the baseline, schema-dump, and step specs. Trim these if they're worth it.

- **Depends on:** 20261003-2.
- **Came from:** The first review of 20261003-2, 2026-10-03.
- **Design:** none (development tooling).
- **Status:** todo

### 20261003-6. `quaack deploy` diagnosis: minor findings, round two.

Minor findings from the review of 20260929-6:

- **The escape filter on gem and ruby paths is untested.** `deploy_diagnosis.rb:110`'s `which_gem` filters those paths with `PLAIN_PATH`, but removing that check leaves every spec green. It's the only thing keeping a PATH entry that holds an escape sequence out of the advice. Add a test with a `gem` dir holding `$` or ESC, and expect the general sentence.
- **The `pwd -P` on the gem/ruby comparison is untested** (`deploy_probe.rb:33`). Changing it to `pwd` stays green.
- **The trailing `(?<! )` on `PLAIN_PATH` is untested,** and it seems unneeded, since `bin` always ends in `/bin`. Test it or drop it.
- **The not-installed advice may not help.** It tells the user to run `quaack deploy` again, but deploy's `gem install` may well install to the same place again. The probe already reports `gem_dir`. Use it to say where the gem went and why this Ruby doesn't see it.

- **Depends on:** 20260929-6.
- **Came from:** The review of 20260929-6, 2026-10-03.
- **Design:** Deploy.
- **Status:** todo

### 20261003-7. Operator-cancel test: don't blame pg_sleep for other failures.

Minor findings from the review of 20260930-5, in enclave/spec/arena_runner_postgres_spec.rb's `cancel_once_sleeping` (around line 245):

- **The clear message can mislabel a failure.** "The INSERT never reached pg_sleep" depends only on `canceler[:canceled]`, which the thread sets just after `pg_cancel_backend` returns.
  - If the test's call fails between the cancel and the flag being set, the message wrongly blames pg_sleep. The reviewer couldn't make this race happen.
  - If the thread dies for another reason, such as a PG error while polling, `stop` swallows that error, and the message still blames pg_sleep.
  - The original error stays attached as the cause in both cases. Surface the thread's own error, and set the flag before the cancel, or make it clear the flag can be late.
- **A dropped `stop` would go unnoticed.** The thread's own error report is off, so a later change that dropped the `stop` call would let the thread die silently when the database is dropped. Consider a comment, or a check that the thread is gone after each example.

- **Depends on:** 20260930-5.
- **Came from:** The review of 20260930-5, 2026-10-03.
- **Design:** Step 9.
- **Status:** todo
