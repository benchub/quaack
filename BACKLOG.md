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

### 20260924-1. 5a-4 loose ends.

Still open from the second review of 20260923-56:
- Changing `guarded(:cleanup_failed) { deallocate }` to another rule stays green.
- The exact-cost assertions use single-node plans only. Add one on a join.
- `CanonicalPlan` treats any `"<N>…"` index name as hypothetical, so a real index named that way is canonicalized wrong.

- **Depends on:** 20260923-56.
- **Came from:** Second review of 20260923-56.
- **Design:** 5a-4.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** todo

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

### 20260928-5. LLM provider seam loose ends.

These are minor findings from the build and review of 20260928-3:
- A set-but-empty `ANTHROPIC_API_KEY` hides other credentials. The anthropic gem treats `""` as a set key, so it skips `ANTHROPIC_AUTH_TOKEN` and profile discovery, then sends no credential header. With `ANTHROPIC_AUTH_TOKEN` also set, the run fails `llm_auth` after one counted attempt. With a valid `ant auth login` profile, it fails with "no Anthropic credentials". Refuse up front with "ANTHROPIC_API_KEY is set but empty", or pass the token or discovered credentials explicitly. Also fix the comment on `AnthropicAdapter#credentials?`, which says an empty key is sent as no header.
- `Start`'s `rescue DriverConfig::Bad` has no spec. A driver.json of `not json`, `[1]`, or `null` gives `bad_driver_config` today, but deleting the rescue keeps every spec green. Add those cases to `start_spec.rb`.
- The anthropic gem prints precedence warnings on stderr, such as "ANTHROPIC_API_KEY is set and takes precedence over ... auto-discovery", even when `api_key_env` supplied the key. They leak no values, but they mislead. Silence them or explain them.

- **Depends on:** 20260928-3.
- **Came from:** The build report and round-one review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** todo

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

### 20260929-4. Say why driver.json is bad.

`quaack start` answers `bad_driver_config` for four different problems and doesn't say which, so the user can't tell what to fix. It happened on the user's first real `quaack start`, right after adding an `llm` block. Name the file and the problem, without quoting its contents:
- not valid JSON, with the line and column from the parser, never the parser's message, since it can quote the file;
- valid JSON but not an object;
- no `jump_command`;
- `jump_command` isn't one non-blank line.

Keep the rule `bad_driver_config` in each message, so scripts still match it. `quaack run` reads the same file for its `llm` block (`DriverConfig`), so give its errors the same detail. Show a complete driver.json example, with both `jump_command` and `llm`, in README.md. 20260928-6 already covers an unreadable file (EACCES). Do it here too if it fits naturally.

- **Depends on:** 20260928-3.
- **Came from:** The user's first real `quaack start`, 2026-09-29.
- **Design:** Where QUAACK runs.
- **Status:** todo

### 20260929-5. Say why intake can't read the query or plan.

`quaack start --query ~/q/query.sql ...` failed with only `query_unreadable`. The laptop's shell had expanded `~` to the laptop's home (`/Users/...`), but `--query` and `--plan` are paths on the jump server, so the file wasn't there. Both sides should help:

- **The driver, before any ssh.** If `--query` or `--plan` is an absolute path under the laptop's own home directory (`Dir.home`), refuse with a usage error: that looks like a path on this laptop, and these are paths on the jump server, so give one relative to your home there, such as `q/query.sql`, or an absolute path there. Decide whether a literal leading `~/` (quoted, so the laptop's shell leaves it) should be expanded on the jump server. If it is, do it in `quaacks`, never with a remote shell.
- **The enclave.** `query_unreadable` and `plan_unreadable` have several causes that look the same today: missing, a symlink as the last part (refused by `NOFOLLOW`), not a regular file, and no permission. Keep the rule, and add which cause it was, such as `query_unreadable: no such file on the jump server`. Never include the path or the OS's own message, which quotes it. Check the whitelist and the egress rules for what an error line may carry.
- Update README.md's `quaack start` section and DESIGN.md step 1 to say plainly that the paths are on the jump server, relative to your home there.

- **Depends on:** none.
- **Came from:** The user's first real `quaack start`, 2026-09-29.
- **Design:** Step 1, Where QUAACK runs.
- **Status:** todo

### 20260929-6. `quaack deploy` diagnosis: close test gaps and fix wording.

The round-one review of 20260929-3 left these minor findings. The code is in `driver/lib/quaack/driver/deploy_diagnosis.rb`.

- **The shell-name filter is untested.** `SHELL_NAME` can become `/.*/`, and its guard can be dropped, with every spec still green. Without the filter, a passwd shell field holding an escape sequence goes into the advice as-is. Add a test where getent answers a shell with an escape sequence, a space, or uppercase, and assert no shell-specific advice.
- **Only the PATH side of the physical-path comparison is tested.** The probe's `pwd -P` on the bin dir can become `pwd`. Add a test where HOME is a symlink and PATH holds the physical bin dir. Without `-P`, that case wrongly advises "another quaacks comes first".
- **Parts of the decision order are untested.** Swapping unsupported-shell with missing-ruby, or other-quaacks with other-ruby, stays green. Add a fish-without-ruby example, and one with another quaacks on PATH and `installed=no`. Decide the right message for the second: today it tells the user to put a bin dir that has no quaacks on PATH.
- **The advice for other shells overclaims.** It says POSIX sh reads no startup file because `$ENV` is only for interactive shells, but ksh88 reads `$ENV` non-interactively. Soften it to "it may read none; see its manual", and keep "bash or zsh may be easier". The comment claiming sshd sets `$SHELL` from passwd is unsourced; cite a source or soften it.
- **DESIGN.md's decision order leaves out the last case.** That case is quaacks on PATH that didn't answer. Mention it there. Its message says "didn't answer" even when quaacks answered with the wrong version; word it as "didn't answer with version X".
- **The installed check is weakly tested.** The probe's `[ -x "$d/bin/quaacks" ]` can become `[ -d "$d/bin" ]` with every spec green, because the "other Ruby" example never creates the bin dir. In that example, create `bin` holding some other executable (not quaacks) and keep the "other Ruby" message expected. (From round two.)
- **Optional tests.** The `\A` anchor on `LINE` and the `run.limit.nil?` guard both survive removal. The guard is effectively redundant.
- **Also consider:**
  - a `gem` and `ruby` mismatch on the jump server (the install went into one Ruby's user dir, and the probe asks another);
  - a user gem dir with a space in its path, which falls back to the general advice today.

- **Depends on:** 20260929-3.
- **Came from:** Reviews of 20260929-3, rounds one and two.
- **Design:** Deploying the enclave.
- **Status:** todo

### 20260929-7. Say which clients `run_server_other_clients` saw. Done, see BACKLOG-COMPLETE.md.

### 20260929-8. `run_server_other_clients` may count QUAACK's own session. Done, see BACKLOG-COMPLETE.md.

### 20260929-9. The full check fails on a Mac whose pg_dump is older than 18. Done, see BACKLOG-COMPLETE.md.

### 20260929-10. The leak check sees BUNDLER_VERSION in a script's environment. Done, see BACKLOG-COMPLETE.md.

### 20260929-11. `run_server_other_clients` clients list: minor test gaps.

Minor findings from the first review of 20260929-7. Each is untested, but none is visible outside the enclave on a realistic setup.

- `RunServerCheck` returns nil rather than `[]` when every other client leaves between the count query and the list query. Changing that to `[]` survives the specs. ErrorFilter drops an empty Array, so nothing changes on the wire. Pin it, or drop the special case.
- In ErrorFilter's client shape check, dropping the key-order check survives the specs. A Hash with its keys reversed then goes out, and the driver drops it, because its key check cares about order. Add a reversed-key-order case, or make both sides agree on whether order matters.
- `ORDER BY pid` passes the specs as well as `ORDER BY backend_start, pid`. They differ only across pid wraparound.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round one.
- **Design:** Step 4.
- **Status:** todo

### 20260929-12. `clients` shape checks: round-two test gaps.

Minor findings from the second review of 20260929-7. The code is correct, and none of these can leak today, because the enclave builds the start time with a fixed-format `to_char`.

- Changing `\A` to `^` in the start-time pattern survives the specs, in both the enclave's ErrorFilter and the driver's reply parser. So does changing the driver's `\z` to `$`. Add cases with the start time after or before a newline to both suites.
- The driver never tests keeping exactly 20 clients. With the driver's limit at 19, a real 20-client error line would lose its `clients` field and the specs stay green.
- Whether the UTC test in `enclave/spec/run_server_check_postgres_spec.rb` catches a 12-hour clock (`HH12`) depends on the time of day the suite runs. Pin it to an afternoon hour.
- The enclave never tests its exact-class checks on an Array or Hash subclass, only on a String subclass. Loosening them to `respond_to?` survives. Egress's own plain-data check backs them up.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round two.
- **Design:** Trust boundary, step 4.
- **Status:** todo

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

### 20260929-15. `TestPgDump.server_major`'s regex is under-tested.

The test "reads the major version from the image's FROM line" in `spec/test_pg_dump_spec.rb` uses a fixture Dockerfile with no digits before `FROM`. So weakening the regex to `/(\d+)/` keeps it green. Put a line with a number before `FROM` in the fixture, such as `ARG PG_MAJOR=16` or a comment naming a version, and check that the test still reads the `FROM` line's major.

- **Depends on:** 20260929-9.
- **Came from:** Review of 20260929-9, round two.
- **Design:** none. Test harness only.
- **Status:** todo

### 20260929-16. PgBouncer support: minor findings.

Minor findings from the review of 20260929-8.

- DESIGN.md step 4 says a pooler must hold no idle server backends when the check runs, but not how the operator gets there. After an earlier run, or a psql session through the pooler, PgBouncer can hold several idle backends. Every one but the one QUAACK reuses then fails `run_server_other_clients`. Say how to clear them: PgBouncer's `RECONNECT` or `KILL`, waiting out `server_idle_timeout`, or `pg_terminate_backend` on the named pids. Also put this in the README's troubleshooting.
- `TestPostgres::Server#pgbouncer_port`: if PgBouncer's startup fails partway, such as on the readiness timeout, the next call starts `pgbouncer -d` again, and probably fails with a confusing error because one is already running.

- **Depends on:** 20260929-8.
- **Came from:** Review of 20260929-8, round one.
- **Design:** Step 4.
- **Status:** todo

### 20260929-17. Test the prompt-pack template's recovery from a failed build.

`PromptPack.template` in `script/prompt_pack/run.rb` builds under `pack_template_building`, renames it once the build is complete, and first drops any leftover `pack_template_building`. No test needs that. Building straight into `pack_template`, or skipping the drop, leaves the spec green. Then a data.sql or ANALYZE failure in one replay would leave a half-built template for the next replay to copy. The reviewer confirmed by hand that the real code recovers. Add a spec that plants a one-time build failure and checks that the retry produces a complete copy. Also rewrap the odd header comment at run.rb:9-10.

- **Depends on:** 20260929-13.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness only.
- **Status:** todo

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

### 20260929-23. Pin the underscore in `SchemaDump.system_schema?`.

Changing `start_with?("pg_")` to `start_with?("pg")` leaves every spec green. That version would silently drop a user schema like `pgbouncer` (common for PgBouncer's auth_query) or `pgaudit_log`, and the query's tables would be missing from the dump and arena. Add an example with such a schema holding a query table, and assert it stays in the namespaces and the DDL.

- **Depends on:** 20260929-19.
- **Came from:** Review of 20260929-19, round one.
- **Design:** 3b.
- **Status:** todo

### 20260929-24. Scrub every Bundler variable, not a named list.

Minor findings from the review of 20260929-10:

- `IsolatedInstall#isolated_env` unsets Bundler variables by name. Another `BUNDLER_*` in a developer's shell, such as a leftover `BUNDLER_ORIG_*`, still reaches the child. The leak check then fails loudly, so nothing slips through. Unset every key matching `/\ABUNDLE/` in `ENV` and `Bundler.original_env` instead.
- `Deploy::UNBUNDLED` (driver/lib/quaack/driver/deploy.rb) and deploy_spec's `clean` env don't unset `BUNDLER_VERSION`. It's harmless today, since `gem build` ignores it and ssh doesn't forward it. Add it for consistency with deploy_diagnosis_spec.

- **Depends on:** 20260929-10.
- **Came from:** Review of 20260929-10, round one.
- **Design:** none. Test harness and deploy only.
- **Status:** todo

### 20260929-25. Pin the guard on EXTRACT field lowercasing in the query redaction.

In `Redaction::Query#lowercase_field` (enclave/lib/quaack/enclave/redaction/query.rb), dropping `&& extract_field?(constant)` leaves every spec green. Every SQL-syntax EXTRACT's first argument would then be lowercased, recognized or not, so a redacted `'Years'` would be stored as `years`. Nothing leaks, since the value is redacted either way. Make the Kelvin test in redaction_query_spec use an uppercase ASCII letter, such as `'WEEK'` with the Kelvin sign, and expect the placeholder map to keep the original case.

- **Depends on:** 20260923-40.
- **Came from:** Review of 20260923-40, round one.
- **Design:** 3g.
- **Status:** todo

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

### 20260929-27. LLM seam: minor findings.

Minor findings from the review of 20260928-6:

- No spec checks that `NoNetwork.always_refuse` resets its flag after an exception inside the block. A reset only on normal exit stays green. That fails safe (the guard stays stricter), but add one example that raises inside the block, then checks that a request reaches the closed port with the opt-in set.
- `DriverConfig.read` treats an unreadable `~/.quaack` directory (mode 000) as a missing driver.json, since `File.file?` returns false. `run` then silently uses the default Anthropic settings, and `start` says `no_driver_config`. Refuse an existing but unreadable `~/.quaack` like an unreadable file. 20260929-4 touches the same code.

- **Depends on:** 20260928-6.
- **Came from:** Review of 20260928-6, round one.
- **Design:** Where QUAACK runs.
- **Status:** todo

### 20260929-28. Arena runner cancel tests: pin the start time, and bound the wait.

Minor findings from the review of 20260923-37:

- No test pins that `ArenaRunner` records a statement's start time per connection call. Recording one start for the runner's whole life leaves every spec green. StepNine reuses one runner across scenarios, so after the timeout's worth of total time, an operator's cancel would read as `statement_timeout`. Add a test with a short timeout: two `pg_sleep` calls, each under it, then a self-cancel. Expect `statement_canceled`.
- In `arena_runner_postgres_spec.rb`, the operator-cancel test's canceler thread polls for the `PgSleep` wait event with no deadline. If a regression stops the INSERT from running, `canceler.join` blocks forever and the suite hangs. Give the loop a deadline.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** Step 9.
- **Status:** todo

### 20260929-29. An operator's cancel shouldn't count as disproving a rewrite.

In Counterexamples (`counterexamples.rb:89-91`) and StepNine (`step_nine.rb:53-54`), a candidate query that fails with `statement_canceled` is recorded as a disproof, `match` false, just like a timeout. It errs on the safe side, since it can only reject a rewrite. But a cancel from someone else says nothing about the candidate: a valid rewrite is silently lost, and the report says "disproved in step 9 ... (rule statement_canceled)". RunDiscipline raises on a cancel that isn't its timeout. The arena side should probably do the same, and end the step with an environment error instead of recording a verdict.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** Steps 9 and 10.
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

### 20260927-25. Teardown loose ends.

These are minor findings from the review of 20260927-23:
- A second Ctrl-C, or any other signal, during teardown in the `ensure` replaces the run's original exception. No test covers this.
- `Teardown#call` rescues only `EnclaveError`. Today the transport wraps every failure in one, but any other exception raised during teardown after a failed run would mask the run's error. Broaden the rescue, or comment why it's safe.

- **Depends on:** 20260927-23.
- **Came from:** Review of 20260927-23.
- **Design:** Teardown.
- **Status:** todo

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
