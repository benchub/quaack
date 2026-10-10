# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

(none. Closed at 0.1.31.)

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

### 20260922-6. LLM client. Done, see BACKLOG-COMPLETE.md.

## Trust boundary.

### 20260922-12. Inbound check for step 10 inserts. Done, see BACKLOG-COMPLETE.md.

## Input.

### 20260922-15. Canonical plan form. Done, see BACKLOG-COMPLETE.md.

## Production inventory.

### 20260922-16. Production inventory. Done, see BACKLOG-COMPLETE.md.

## Schema, statistics, and classification.

### 20260922-24. 3h clock anchoring. Done, see BACKLOG-COMPLETE.md.

## Run server.

### 20260922-66. Run teardown. Done, see BACKLOG-COMPLETE.md.

## Added later.

### 20260923-1. Postgres 17 parser under Postgres 18. Done, see BACKLOG-COMPLETE.md.

### 20260923-16. Harness loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-18. Runtime checker test loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-21. index-from-query loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-24. index-from-plan loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-25. Static checker loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-30. Predicate atom loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-36. index-dedupe loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-57. Rewrite candidate check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-3. Intake loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-7. fixture-compare comparator loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-9. Load-order loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-10. index-rank loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-24. Production inventory loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-25. redact loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-28. literals loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-29. Run server check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20260929-16. PgBouncer support: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20260929-22. The subset dump takes a query table in a system schema. Done, see BACKLOG-COMPLETE.md.

### 20260930-13. Run server check shadowing: one untested qualification, and operators. Done, see BACKLOG-COMPLETE.md.

### 20260930-14. Unqualified catalog names elsewhere in the enclave. Done, see BACKLOG-COMPLETE.md.

### 20261001-19. Record the rewrite stages in the burndown. Done, see BACKLOG-COMPLETE.md.

### 20261002-1. Rule generator: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261002-2. Running the rules: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261002-15. 6c rule: `polymorphic_key_copy`, checked against the data. Done, see BACKLOG-COMPLETE.md.

### 20261002-6. 6c rule: `shared_scan_cte`. Done, see BACKLOG-COMPLETE.md.

### 20260923-41. Support DML statements.

INSERT, UPDATE, DELETE, and MERGE, at the top level or inside a CTE. A slow production query can be DML, but rewrite-test and result-comparison compare result rows, so this needs a design for comparing effects rather than rows. RelationQualifier's DML-target handling was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Decided by the user (2026-10-08):** hold; a v2 feature.
- **Status:** todo

### 20260923-42. Support SELECT INTO and locking clauses.

`SELECT ... INTO` and `FOR UPDATE`, `FOR SHARE`, and similar. Job-queue queries often use `FOR UPDATE SKIP LOCKED`. DESIGN.md refuses locking clauses in rewrite candidates, so decide how the original and its candidates are compared. RelationQualifier's locking-clause skip was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **Design:** What goes into the enclave, and input.
- **Decided by the user (2026-10-08):** hold; a v2 feature.
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

### 20260926-55. Keyset and expression-unique leftovers. Dropped, see BACKLOG-COMPLETE.md.

### 20260926-59. Keyset tie rows are dropped on realistic schemas. Done, see BACKLOG-COMPLETE.md.


### 20260927-17. Covering-check and volatility-list gaps. Done, see BACKLOG-COMPLETE.md.

### 20260927-28. Parser note loose ends, and the Postgres 18 upgrade. Done, see BACKLOG-COMPLETE.md.

### 20261001-5. An LLM error reads the reason out of a JSON array body. Done, see BACKLOG-COMPLETE.md.

### 20261001-10. The full schema dump finds the schemas its objects reference, and takes overrides. Done, see BACKLOG-COMPLETE.md.

### 20261003-7. Intake unreadable causes: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261003-3. Report payload: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261003-5. Report payload: what the index accountability table still lacks. Done, see BACKLOG-COMPLETE.md.

### 20261003-19. Name the tables in an `fk_cycle` refusal. Done, see BACKLOG-COMPLETE.md.

### 20261003-23. Step 9: break a cycle when the query joins on its nullable edge. Done, see BACKLOG-COMPLETE.md.

### 20261003-28. `shared_scan_cte`: widenings. Done, see BACKLOG-COMPLETE.md.

### 20261003-29. `existence_in_flip`: a captured whole-row reference, and widenings. Done, see BACKLOG-COMPLETE.md.

### 20261003-30. Finish 20261003-23: a skipped group's cut-column key class. Done, see BACKLOG-COMPLETE.md.

### 20261003-31. Step 9: two false passes on ordinary joins. Done, see BACKLOG-COMPLETE.md.

### 20261003-32. rewrite-test: loads that fail on `IS NULL` and skipped groups. Done, see BACKLOG-COMPLETE.md.

### 20261003-39. rewrite-test: more variety in self-references and repeated parents. Done, see BACKLOG-COMPLETE.md.

### 20261003-40. Step 9: a dropped group leaves rows pointing at missing parents. Done, see BACKLOG-COMPLETE.md.

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

### 20261003-43. `fk_cycle` table names: loose ends from 20261003-19. Done, see BACKLOG-COMPLETE.md.

### 20261003-44. `existence_in_flip`: loose ends from 20261003-29. Done, see BACKLOG-COMPLETE.md.

### 20261004-2. Step 9 re-probes CHECK constraints thousands of times. Done, see BACKLOG-COMPLETE.md.

### 20261004-3. Tighten 20261003-38's SQLSTATE filtering. Done, see BACKLOG-COMPLETE.md.

### 20261004-6. Pin the type part of rewrite-test's probe cache key. Done, see BACKLOG-COMPLETE.md.

### 20261004-8. rewrite-test gaps found by the FK-cycle review. Done, see BACKLOG-COMPLETE.md.

### 20261004-9. Report `polymorphic_key_copy` disproofs in rewrite-test and counterexamples as rule bugs. Done, see BACKLOG-COMPLETE.md.

### 20261004-23. rewrite-test spends ~20 minutes of Ruby CPU per rewrite. Done, see BACKLOG-COMPLETE.md.

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
- **Decided by the user (2026-10-08):** hold until the user sends a CPU profile.
- **Decided by the user (2026-10-09):** still holding; the user will send the profile later.
- **Status:** todo (item 1 needs the user)

### 20261004-51. Report: explain the untested-conditions note under a rewrite, and render its conditions readably. Done, see BACKLOG-COMPLETE.md.

### 20261004-77. Index burndown loose ends from 20261001-20. Done, see BACKLOG-COMPLETE.md.

### 20261004-80. Indexes table: which source proposed each built index. Done, see BACKLOG-COMPLETE.md.

### 20261004-88. ambiguous_user_schema: minors and the operator's own schema. Done, see BACKLOG-COMPLETE.md.

### 20261004-89. Index sources: a test gap and the remaining "not recorded" cells. Done, see BACKLOG-COMPLETE.md.

### 20261004-91. Structured columns: test gaps, and other structured types. Done, see BACKLOG-COMPLETE.md.

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
- **Landed so far:** items 1 to 5, 2026-10-10 (task/20261004-92; Opus review clean). 1: the edge query's LIMIT is `CASE WHEN l IS NULL THEN NULL ELSE LEAST(l, 9223372036854775807 - o) + o END` with bigint casts (verified on Postgres 18 against LIMIT/OFFSET edge cases; negative values error in the original first, so they can't match); 2: `COALESCE(o, 0)` (a NULL offset is 0); 3: a full run over `HashedRuns::FULL_RUN_ROW_CAP` (2,000,000) rows refuses as `unsupported_order` (only inside CutTies' full runs, so it costs candidates on big result sets with a cut tie, never a false match); 4: `through_offset!` raises on a missing LIMIT or OFFSET; 5: `all_columns?` removed from production comparison (dead there) and its guard moved into fixture-compare's `cut_tie`, with the first test that exercises it. On the unreleased list. Item 6 needs a decision from the user (below). Minor findings: 20261010-7.
- **Item 6, waiting on the user:** reproduced on real Postgres: original `ORDER BY grp DESC LIMIT n` against candidate `ORDER BY grp DESC NULLS LAST, id LIMIT n` passes when the LIMIT cuts a tie (n=3) and fails with `value` when it doesn't (n=4). Two ways to make the paths agree: (a) accept more: when the candidate's tiebreaker runs don't match row for row, fall back to the CutTies layout check, which already accepts these candidates when a tie is cut (correct, since the candidate's rows are a valid result of the original, but it is the risky direction: it makes the comparison accept more); (b) refuse more: refuse with `unsupported_order` when the candidate's order is stricter than the original's and the original's LIMIT doesn't cut a tie, instead of reporting `value` (honest; costs a candidate). Both the builder and the Opus reviewer lean toward accepting-or-refusing only after the user decides; the reviewer recommends (b), failing closed.
- **Status:** todo

### 20261004-95. Insert check: clock words, loose ends. Done, see BACKLOG-COMPLETE.md.

### 20261006-2. Structured columns: minors from 20261004-91. Done, see BACKLOG-COMPLETE.md.

### 20261006-3. Classify: bytea, geometric and other non-text types can still send MCV values. Done, see BACKLOG-COMPLETE.md.

### 20261006-6. Clock words and defaults: minors from 20261004-95. Done, see BACKLOG-COMPLETE.md.

### 20261006-10. Stats trimming: minor findings from 20261001-7. Done, see BACKLOG-COMPLETE.md.

### 20261006-17. Clock binding: overloaded user functions. Done, see BACKLOG-COMPLETE.md.

### 20261006-28. Stats trimming: join aliases with column lists, and a boundary test. Done, see BACKLOG-COMPLETE.md.

### 20261007-21. Qualify functions and operators that several schemas define (full version of 20260926-56's qualification). Done, see BACKLOG-COMPLETE.md.

### 20261007-38. `not_in_to_not_exists`: extensions. Done, see BACKLOG-COMPLETE.md.

### 20261007-47. `or_to_union`: extensions. Done, see BACKLOG-COMPLETE.md.

### 20261007-51. Equality: refuse a half-exact `=` too. Done, see BACKLOG-COMPLETE.md.

### 20261007-58. Equality: planted operators on domains and same-signature shadows. Done, see BACKLOG-COMPLETE.md.

### 20261007-64. Intake unreadable reasons: new causes, and one shared list. Done, see BACKLOG-COMPLETE.md.

### 20261008-4. `not_in_to_not_exists`: support `NOT IN` outside the top-level WHERE. Done, see BACKLOG-COMPLETE.md.

### 20261008-5. `not_in_to_not_exists`: support `<> ALL`. Done, see BACKLOG-COMPLETE.md.

### 20261008-7. `or_to_union`: support a query with GROUP BY. Done, see BACKLOG-COMPLETE.md.

### 20261008-8. `or_to_union`: support outer joins. Done, see BACKLOG-COMPLETE.md.

### 20261008-9. `or_to_union`: support a bare `*` in the select list. Done, see BACKLOG-COMPLETE.md.

### 20261008-18. `or_to_union` composite keys: minors from 20261008-6. Done, see BACKLOG-COMPLETE.md.

### 20261008-20. `not_in_to_not_exists` over a UNION: minors from 20261008-3. Done, see BACKLOG-COMPLETE.md.

### 20261008-21. index-from-plan: `(InitPlan 1).col1` conditions and COLLATE filters.

Split from 20260923-24, whose builder found both larger than a loose end:

1. **`(InitPlan 1).col1` conditions are dropped whole, because pg_query can't parse them.** A fix would rewrite those tokens as a parameter before parsing. It should use pg_query's scanner, so a match inside a string literal is left alone.
2. **COLLATE filters propose nothing.** A plain key would be a wasted candidate, since Postgres uses a btree for the comparison only when the index's collation matches the query's. A real fix needs two things: collation-aware key columns from the plan, and a decision on how a `COLLATE` predicate passes through index-dedupe.

- **Depends on:** 20260923-24.
- **Came from:** The builder of 20260923-24, 2026-10-08.
- **Design:** index-from-plan.
- **Landed so far:** the InitPlan half, 2026-10-10 (task/20261008-21; Opus review clean): `InitPlanOutput` rewrites each `(InitPlan n).colm` as `$1` using `PgQuery.scan` token spans (the same text inside a string literal, dollar-quoted string, comment or quoted identifier stays as it was; a reference without a column or unscannable text goes through and is refused as before), so a column equal to an InitPlan output becomes a constant equality key column and never a partial predicate. On the unreleased list. Open: the COLLATE half. A real fix needs collation-aware key columns from the plan and a decision on how a `COLLATE` predicate passes through index-dedupe (key columns are plain name strings throughout generator two); today a COLLATE filter proposes nothing, a clean safe refusal. Needs the user's call: do it, or drop it.
- **Status:** todo

### 20261008-22. Live EXPLAIN JSON parses with JSON's default nesting limit. Done, see BACKLOG-COMPLETE.md.

### 20261008-23. index-from-plan booleans and MCV coverage: minors from 20260923-24. Done, see BACKLOG-COMPLETE.md.

### 20261008-24. index-from-query: incremental sort, derived-table reduction, and whole-row reads.

The builder of 20260923-21 left these items out:

1. **Incremental sort isn't handled.** This one is large.
2. **INCLUDE beyond the select list and GROUP BY.** DESIGN.md step 5 limits INCLUDE to those two on purpose, so changing it is a design question for the user.
3. **No join reduction through derived-table columns.** In `o LEFT JOIN (subquery) s ... WHERE s.x = 1`, the strict WHERE on the subquery's column doesn't reduce the join, because subquery columns aren't tracked.
4. **Whole-row references.** `SELECT o FROM public.orders o` isn't counted as reading every column, so an INCLUDE could look covering when it isn't.

- **Depends on:** 20260923-21.
- **Came from:** The builder of 20260923-21, 2026-10-08.
- **Design:** index-from-query.
- **Landed so far:** items 3 and 4, 2026-10-10 (task/20261008-24; review clean). Item 3: a FROM subquery with an alias is a member of the join's sides, so a strict conjunct on a column qualified by that alias (a bare column or a COLLATE-wrapped one under a plain operator) counts as rejecting the subquery and reduction cascades through its ON equality (`coalesce`, `IS NULL`, `IS DISTINCT FROM`, OR with another condition, NOT and function calls don't reduce); unqualified subquery columns aren't tracked. Item 4: a whole-row reference (`SELECT o`, `to_jsonb(o)`, `o IS NOT NULL`, GROUP BY o, ORDER BY o) reads every column of that table; a bare name that is a column of a table in the query still reads as the column. On the unreleased list. Still open: item 1 (incremental sort: large, its own task) and item 2 (INCLUDE beyond the select list and GROUP BY: DESIGN.md limits INCLUDE on purpose, so it needs the user's call). Minor finding: 20261010-14.
- **Status:** todo

### 20261008-25. index-from-query join reduction and pattern keys: minors from 20260923-21. Done, see BACKLOG-COMPLETE.md.

### 20261008-26. NATURAL JOIN marker: minors from 20260923-30. Done, see BACKLOG-COMPLETE.md.

### 20261008-28. Boolean folding in index-dedupe: minors from 20260923-36. Done, see BACKLOG-COMPLETE.md.

### 20261008-29. Rewrite candidate relation check: minors from 20260923-57. Done, see BACKLOG-COMPLETE.md.

### 20261008-30. Production inventory: minors from 20260924-24, and silent packet drops. Done, see BACKLOG-COMPLETE.md.

### 20261008-31. Rewrite candidates: a regclass literal reveals that a relation exists. Done, see BACKLOG-COMPLETE.md.

### 20261008-32. Rewrite candidates: whether a function, type, collation, or operator exists is visible. Done, see BACKLOG-COMPLETE.md.

### 20261008-33. Load orders: minors from 20260924-9, and skipping a redundant rotated run. Done, see BACKLOG-COMPLETE.md.

### 20261008-34. Statistics a non-owner production role can't see: extended statistics, expression indexes, and row security. Done, see BACKLOG-COMPLETE.md.

### 20261008-36. Cast placeholders in literals: minors from 20260924-28.

The review of 20260924-28 found these minor issues:

1. **Older entries.** (Done in the 20261008-35 batch.) No test covers a statistics entry stored before `column_types` existed.
2. **DateStyle.** A picked date or timestamp value goes through its cast as text, in the DateStyle that was active when statistics read it. A replay session with another DateStyle could misread the value or fail to bind it. Pin the DateStyle, for example to ISO, wherever the statistics are read and replayed.
3. **Shadowed type names.** (Done.) A bare cast like `$1::timestamptz` matches the pg_catalog type by name only, so a type of the same name earlier on the search_path would match too. The worst case is a bind error, not a leak.

- **Depends on:** 20260924-28.
- **Came from:** The review of 20260924-28, 2026-10-08.
- **Design:** literals.
- **Status:** todo. Only item 2 (DateStyle) is left.

### 20261008-41. Candidate name lockdown: keyword operators and the failure for a pinned name. Done, see BACKLOG-COMPLETE.md.

### 20261008-44. Qualifying overloaded names: keyword forms (part 2 of 20261007-21).

Split from 20261007-21. IN, BETWEEN and NOT BETWEEN, LIKE and ILIKE, IS DISTINCT FROM, NULLIF, simple CASE, and USING and NATURAL joins have no qualified spelling. When several schemas on the path define the operator they use, rewrite each one into an equivalent explicit form that can be qualified, or refuse it cleanly, and list it as unsupported in v1. This also covers item 1 of 20261008-41 (keyword operators LIKE, IN, IS DISTINCT FROM, NULLIF resolving through the search path).

- **Depends on:** 20261007-21.
- **Came from:** The split of 20261007-21, 2026-10-08.
- **Design:** qualify.
- **Status:** todo

### 20261008-47. Scenario loading: minors from 20260927-18. Done, see BACKLOG-COMPLETE.md.

### 20261008-48. Schema dump dependency walk: minors from 20261001-10.

The review of 20261001-10 found these minor issues:

1. **Mixed-case or non-ASCII names drop every table name.** If one unreadable table's name fails the shape check (mixed case, Unicode, or a quote), the whole `tables` field is dropped. The operator then gets "can't read these tables" with no tables named. Keep the names that pass, widen the shape so quoted identifiers can be shown safely, or word the note so it doesn't promise names when none come through.
2. **The `a` (auto) dependency has no test.** A sequence owned by a column in another schema relies on it, and removing it from the walk keeps every test green. Add a spec where `A.seq OWNED BY B.t.col` and the dump loads.
3. **`--exclude-table` has no cap.** It adds one argument per unneeded relation in each added schema. A schema with thousands of tables could approach ARG_MAX. Cap it, or refuse cleanly past the limit.
4. **A misspelled extra schema gets a vague error.** A nonexistent `extra_dump_schemas` name fails as `pg_dump_failed`. Pre-check it against pg_namespace and give it a rule that tells the operator to fix the config.
5. **Children outside the dump aren't pulled in.** A partition or inheritance child in a schema outside the dump is missed, because the walk follows dependencies in one direction only.

- **Depends on:** 20261001-10.
- **Came from:** The review of 20261001-10, 2026-10-08.
- **Design:** schema-dump.
- **Status:** todo

### 20261008-50. Orphan index-build notes: advice that's moot after teardown. Done, see BACKLOG-COMPLETE.md.

### 20261008-51. `quaack start --database`: name production's database. Done, see BACKLOG-COMPLETE.md.

### 20261008-52. `--database` and system relations: follow-ups.

1. **From the review of 20261008-51:** confirm that a driver spec goes red when `database` is dropped from the `Runs#record` hash. The reviewer's run of that mutation loaded no specs. Also check whether run-server's database check uses only the bare `Protocol::DatabaseName::PATTERN` regex, without the encoding and ASCII guard that `DatabaseName` adds. If it does, use the full check.
2. **From the builder of 20260929-22:** a query that names no relation at all, such as one that only selects from `generate_series`, and has no extension outside a system schema, still gives the full dump no `--schema` flags, so pg_dump dumps every schema. Refuse that case, or pass an explicit empty schema set.

- **Depends on:** 20261008-51, 20260929-22.
- **Came from:** The review of 20261008-51 and the builder of 20260929-22, 2026-10-08.
- **Design:** input, schema-dump.
- **Status:** todo

### 20261008-53. redact: the rest of 20260924-25.

Split from 20260924-25, with that task's review findings:

1. **Equal but differently written expressions.** Postgres treats some as the same, but each gets its own placeholder, so they fail closed as `prepare_failed`.
2. **Dates in row annotations.** Normalize dates and timestamps for row annotations through the racetrack.
3. **Numbering.** PredicateAtoms should use redact's numbering.
4. **Binding.** SingleCandidateTest and ArenaRunner should adopt Binding, so their types are declared through PREPARE.
5. **Racetrack plan depth.** Racetrack plans, such as a rewrite's slow plan in index-search, aren't depth-checked. A plan deeper than 48 levels fails at egress with a generic error. Check depth there, or map egress's nesting error to `plan_too_deep`.
6. **`Cast#type`.** It returns `""` rather than `nil` when a `::` is followed by no word parts. Match the comment.

- **Depends on:** 20260924-25.
- **Came from:** The build and review of 20260924-25, 2026-10-08.
- **Design:** redact.
- **Status:** todo

### 20261008-54. system_relation and PgBouncer docs: minors from 20260929-22 and -16.

The review of 20260929-22 and -16 found these minor issues:

1. **No test pins a `pg`-prefixed app schema.** Add a schema like `pgapp` that resolves and passes, so a mutation to `start_with?("pg")` goes red.
2. **`toast_relation` is unreachable.** Every TOAST table is in `pg_toast`, so `system_relation` now catches them first. Remove the rule and its fixed note, or document them as a backstop.
3. **`KILL` leaves the database paused.** PgBouncer's `KILL` pauses new client connections to that database until `RESUME`, and the docs don't say so. Add "then `RESUME <db>`", or recommend `RECONNECT` first.
4. **`TestPostgres::PgBouncer.stop` can hang.** Its wait loop has no timeout. Bound it.
5. **The "fails partway" spec ignores a failed restart.** Its `ensure` runs `start` again without checking the result.

- **Depends on:** 20260929-22, 20260929-16.
- **Came from:** The review of 20260929-22 and -16, 2026-10-08.
- **Design:** qualify, run-server.
- **Status:** todo

### 20261008-55. Foreign cancels: minors from 20260929-29. Done, see BACKLOG-COMPLETE.md.

### 20261008-56. Rule generator: leftovers from 20261002-1.

1. **Three or more INs.** A query with three or more matching INs never gets its fully rewritten form, given depth two and the cap.
2. **Wider coverage.** Nested SELECTs and derived tables, unqualified columns, an IN in a join's ON, and `= ANY (subquery)`.
3. **The standalone spec's rule count.** `rewrite_rules_standalone_spec.rb` hard-codes 12 rules. Derive the count, or check that it's more than zero.
4. **A grandchild chain.** No test covers a legacy-inheritance chain where the table's only child has its own child.

- **Depends on:** 20261002-1.
- **Came from:** The build and review of 20261002-1, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-57. Running the rules: leftovers from 20261002-2.

1. **`failed_checks` vs plan-pruning drops.** A rule-made rewrite that fails the checks is counted in rewrite-rules' `failed_checks` and also in plan-pruning's drops. Settle this with 20261001-19's counting.
2. **A second `status` call.** `CounterexampleStage` asks `status` again right after `RewriteStage` did. Fixing it means passing the entries between the stages.
3. **Which assumptions win on a deduped rewrite.** Dedupe now covers any later call of the same source, not just a rerun. A later rewrite with the same SQL but different stated assumptions keeps the earlier entry's assumptions. Say in DESIGN.md which wins, or merge them.
4. **Duplicate constant.** `RuleBugs::MISMATCHES` duplicates `RewriteFate::MISMATCHES`. Share one.

- **Depends on:** 20261002-2.
- **Came from:** The build and review of 20261002-2, 2026-10-08.
- **Design:** rewrite-rules, report.
- **Status:** todo

### 20261008-59. Correlated-subquery read columns: minors from 20260927-17.

1. **Set-operation arms are untested.** The `larg`/`rarg` branch in `OuterRefs.select` can be replaced with `return []` and every spec stays green. Add a test with a correlated `EXISTS (SELECT … UNION SELECT …)`.
2. **Two behaviors have no spec.** No spec covers an inner alias that shadows an outer one. None checks that a unique index on `lower(email)` is accepted when `email` isn't generated.
3. **`OuterRefs.in` reaches too far.** It also walks the WITH clause and FROM subqueries, which can add extra read columns. That's conservative, but limit it to the WHERE, select-list, and other SubLinks of the query itself.

- **Depends on:** 20260927-17.
- **Came from:** The review of 20260927-17, 2026-10-08.
- **Design:** index-from-query.
- **Status:** todo

### 20261008-60. Foreign cancels on BEGIN and ROLLBACK: DESIGN.md and a Postgres test.

The review of 20261008-55 found two gaps:

1. **DESIGN.md is out of date.** Its rewrite-test section, around line 1225, still says the runner records the closing ROLLBACK being canceled. That case now ends the step.
2. **No real Postgres test for the new steps.** Only the unit spec covers `:begin`, `:rollback`, and `:transaction`. Add a Postgres-backed test, if there's a reliable way to cancel a BEGIN or ROLLBACK from a second session.

- **Depends on:** 20261008-55.
- **Came from:** The review of 20261008-55, 2026-10-08.
- **Design:** rewrite-test.
- **Landed so far:** item 1, 2026-10-08 (task/20261008-50, commit e5cf49f8). Item 2 is still open.
- **Status:** todo

### 20261008-61. Fixture-compare: a LIMIT inside a subquery or CTE isn't checked for hidden ties. Done, see BACKLOG-COMPLETE.md.

### 20261008-63. Report: calls, wait time, and tokens for each LLM model. Done, see BACKLOG-COMPLETE.md.

### 20261008-64. `or_to_union`: the expression-index test misses its guard.

From the review of 20261008-18 and -20. The "the only key's index has an expression" test stays green when `i.indexprs IS NULL` is removed from `assumption_check.rb`, because `Catalog::Keys` already drops the expression column first. Add a test on an index like `(a_id, n, lower(t))`, which reaches the `indexprs` guard.

- **Depends on:** 20261008-18.
- **Came from:** The review of 20261008-18, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-66. Exclusion keys: two untested checks from 20261008-47.

From the review of 20261008-47:

1. **The btree strategy-3 condition is untested.** Changing it to `AND true` keeps every spec green. Add a test with an exclusion over a non-equality btree operator, such as `WITH <`.
2. **The subtype namespace check is untested.** `sn.nspname = 'pg_catalog'` can be removed and every spec stays green. Add a test with a user range over a user type named like a stepped one, such as `other.int4`.

- **Depends on:** 20261008-47.
- **Came from:** The review of 20261008-47, 2026-10-08.
- **Design:** rewrite-test.
- **Status:** todo

### 20261008-67. Inner cuts: a dead guard, and the remaining picks.

1. **A dead guard (second review of 20261008-61).** The `|| select[:larg]` guard in `InnerCuts.sole_table` never fires, since a set-operation node has no `from_clause`. Remove it.
2. **Inner DISTINCT, GROUP BY, and UNION picks (builder of 20261008-61).** A bad candidate can still match through these. DESIGN.md lists this as a known gap. Decide whether they get the same treatment as inner cuts.

- **Depends on:** 20261008-61.
- **Came from:** The build and second review of 20261008-61, 2026-10-08.
- **Design:** fixture-compare.
- **Status:** todo

### 20261008-68. LLM usage parsing: minors from 20261008-63.

From the second review of 20261008-63:

1. **A malformed `*_tokens_details` still raises.** If `prompt_tokens_details` or `completion_tokens_details` isn't an object (for example `"x"`), `Usage.openai` raises a TypeError. Treat it as not reported.
2. **`count?`'s type check is untested.** Add a test with a string, float, or negative count in usage.

- **Depends on:** 20261008-63.
- **Came from:** The second review of 20261008-63, 2026-10-08.
- **Design:** report, LLM providers.
- **Status:** todo

### 20261008-72. `spec/pipeline_replay_spec.rb` takes about 24 minutes alone.

Carried from 20261003-3. It sets the per-commit check's wall time. See whether replays can share setup (one Postgres load per schema, say) or run less.

- **Depends on:** none.
- **Came from:** 20261003-3, 2026-10-08.
- **Design:** none (CLAUDE.md Development).
- **Status:** todo

### 20261009-1. Upgrade pg_query to a Postgres 18 parser, and drop the parser note.

Carried from 20260927-28. As of 2026-10-08 the lockfile has pg_query 6.2.3 and the newest release is 6.2.5, both on the Postgres 17 grammar. When a release ships a Postgres 18 parser, upgrade it, drop the parser note (20260923-1), and update `parser_version_spec.rb`'s literal 17.

- **Depends on:** a pg_query release with a Postgres 18 parser.
- **Came from:** 20260927-28.
- **Design:** none.
- **Status:** blocked

### 20261009-2. Have the enclave send its parser major for `query_unparsable`.

Carried from 20260927-28. `EnclaveError#unparsable` builds the note from the driver's own pg_query, so if the two sides' pg_query differ, the note names the wrong grammar. The fix touches all three gems: a new field in the protocol whitelist's error-line fields; `ErrorFilter` emitting it only for `query_unparsable`, as a small integer (raised in `intake/query.rb` and the qualifier's `Unparsable`); and the driver reading it. It adds a value to enclave output, so test it with sentinels. Both sides install from one lockfile, so this only matters if they drift.

- **Depends on:** 20260927-28.
- **Came from:** The build of 20260927-28, 2026-10-08.
- **Design:** none.
- **Status:** todo

### 20261009-3. Index sources: leftovers from 20261003-5.

- **`IndexSources#ignored`'s `result["refusal"] ||` clause is untested.** The fixture's refused result also has unused plans. Drop the clause or test a refused result with a used plan.
- **`existed` and `ignored` are tested only on hand-built store entries.** Add one Postgres spec that runs a real index-dedupe and index-test pass with an existing index on a 2-table query and checks the counts.

- **Depends on:** 20261003-5.
- **Came from:** The review of 20261003-5, 2026-10-09.
- **Design:** report.
- **Status:** todo

### 20261009-25. `counterexample_steps_postgres_spec.rb` fails when run alone.

Found in the build of 20261004-3. Run by itself, the spec file fails with a LeakCheck load error, but it passes under `rake`, so it depends on load order. Add the missing `require` so it runs alone.

- **Depends on:** none.
- **Came from:** The build of 20261004-3, 2026-10-09.
- **Design:** none (test infrastructure).
- **Status:** todo

### 20261009-28. Hidden-statistics caveat: its Details link lands on a section that doesn't explain it. Done, see BACKLOG-COMPLETE.md.

### 20261009-29. Timed-out caveats: their Details link lands on a section that doesn't explain them. Done, see BACKLOG-COMPLETE.md.

### 20261009-32. Report: reword the fate of a rewrite that regressed, and drop its correctness caution. Done, see BACKLOG-COMPLETE.md.

### 20261009-33. Ranked rewrites carry the "unproven" caution: find out why, and fix the cause.

The user, 2026-10-09, from their own report (`quaack-20261009T212424Z-7f4c43c1.html` in the repo root, untracked; it's a real report with production schema and table names, so never commit it, quote it in a fixture, or send it anywhere; reproduce with synthetic data). Every rewrite in it, including the ranked ones (Steady Lute, Tidy Trout, Plucky Spoon), says "Read it with care: every test QUAACK ran passed, but the test data never exercised some of its conditions, so those parts are unproven." The user reads that as "QUAACK didn't logically test it", which is a problem when it sits on the query QUAACK recommends. The run's burndown says why it shows: rewrite-test's vacuity-guard counted 132 conditions the test data never exercised (after 396 retries), and the LLM's data exercised 85 of them. The conditions left (about 47, if those counts are what the caution counts) mark every rewrite, because `Report::Cautions#warning` adds the caution whenever `unchecked_atoms(entry)` is non-empty. The query is a large one: an OR of ANDs over `assignments` and `submissions`, with `IN` lists and a `UNION ALL` subquery. Long `IN` lists aren't suspected: the user's own queries have lists of hundreds of items, and the untested list below holds simple conditions too.

Work out which of these is true, and fix it:
1. **Which atoms are left, and why.** From the run's store (ask the user for the run ID and for the shapes of the untested atoms; the report doesn't list them), say which atoms stay untested, and why vacuity-guard can't exercise them: an OR branch that can't be reached with a loadable row, a condition that the unique keys or the foreign-key cut rule out, or a bug.
2. **Whether an untested atom makes the rewrite unproven at all.** If the atom sits in a part of the query the rewrite left exactly as the original had it, no test could tell the two apart there, so the caution says nothing about the rewrite. Consider warning only when an untested atom lies in a part the rewrite changed. This needs a check against DESIGN.md's counterexamples and result-comparison design: is the caution meant to be about the whole query, or only the rewrite's difference?
3. **Whether to raise coverage** (more fixture variety for the atoms found in 1), which overlaps 20261003-39 and 20261003-42.
4. **Wording**, if the caution stays: it must not read as "no logical testing" (see 20261009-32, which rewords the not-better case; do these two together, or keep the wording the same in both).

Take the decision between 2 and 3 to the user before building, with the finding from step 1.

**Finding from the user's run (2026-10-09, from `quaacks counterexample-payload` for rewrite_1 to rewrite_7; the shapes hold no values):** rewrite_1 has no untested atoms (it's the rewrite planned the same as the original, so it's never tested). Each of rewrite_2 to rewrite_7 lists the same atoms, in the same order: about two dozen, and they're the original query's whole predicate set. They include the join key (`submissions.assignment_id = assignments.id`), every `IN` list, the `type`, `workflow_state` and `context_type` comparisons, `muted IS NULL`, the user filter, the date range, and one atom for the whole `assignments.id IN (SELECT ... UNION ALL SELECT ...)` subquery. 132 untested in all is that list's length times the 6 tested rewrites. So the caution isn't about anything a rewrite changed. It says that rewrite-test's fixtures exercised almost none of the original's conditions at all. Treat that as the lead: the likely cause is that scenarios didn't load or didn't reach the query's rows (DESIGN.md's counterexamples section says a scenario that won't load "exercises nothing: its atoms stay vacuous ... and end untested"), not that the rewrites differ in untested ways. Step 1 should reproduce this on a synthetic schema of the same shape (two tables joined on a key, an OR of ANDs, an `IN` list, a `UNION ALL` subquery under an `IN`), and check the case where every scenario fails to load first and find where the atoms go vacuous. The user's run store is on the jump server; if the builder needs more from it (rewrite-test's scenario results for this run), ask the user for a redacted copy.

- **Depends on:** None. Related: 20261009-32, 20261009-18, 20261003-39, 20261003-42.
- **Came from:** The user, 2026-10-09.
- **Design:** rewrite-test (vacuity-guard), counterexamples, report.
- **Decided by the user (2026-10-09):** the caution should warn only about untested atoms in the part the rewrite changed. That's task 20261009-40. This task builds the diagnostic (why an atom stayed vacuous) first; the cause of the untested atoms in the user's run is still unknown and waits on that diagnostic.
- **Landed so far:** 2026-10-09 (task/20261009-33): the diagnostic only. Each tested rewrite's `rewrite_test` message and `rewrite_tested_<n>` entry now carry `s1_load_rule` (nil, or a rule from `Protocol::VacuityDiagnostic::LOAD_RULES`) and `s1_rows` (the original's row count on S1). Next: a run on a build with it tells whether S1 failed to load or loaded and returned nothing; then fix the cause. The caution's scope is 20261009-40. Minor finding: 20261009-46.
- **Status:** todo (waits on a run with the diagnostic)

### 20261009-34. Report: sticky collapse bar, in pale rose, for the not-ranked and index-ideas sections. Done, see BACKLOG-COMPLETE.md.

### 20261009-35. Ranking: set each kind's heading apart from its rows. Done, see BACKLOG-COMPLETE.md.

### 20261009-38. Report: drop the "Tried for" column from "Indexes QUAACK thought of that you already have". Done, see BACKLOG-COMPLETE.md.

### 20261009-41. Burndown funnel: the top band is a rectangle, not a triangle. Done, see BACKLOG-COMPLETE.md.

### 20261009-42. Burndown: explain "set aside", drop "came in", no gap between bands, shorter hovers. Done, see BACKLOG-COMPLETE.md.

### 20261009-57. Redaction re-check: a jsonb `?` operator in a partial index fails the whole negative result. Done, see BACKLOG-COMPLETE.md.

### 20261009-58. Redaction re-check for the other DDL fields that leave the enclave. Done, see BACKLOG-COMPLETE.md.

### 20261009-63. Unchanged atoms: an added constant conjunct isn't a new atom. Done, see BACKLOG-COMPLETE.md.

### 20261009-66. Tint hue check and IP guard: small gaps from the review of 20261009-64 and -65.

- The Ranking tint hue check compares hue against white `--bg` and `--panel` in the light theme, where hue is undefined (atan2 gives 0), so the brown tint's 27 degree gap there means nothing. Skip hue for backgrounds with near-zero saturation (and say so in the spec), and fix the spec's comment: it says the closest hue gap is "21 degrees (light violet against `--head-bg`)", but the real chromatic minimum is 39.5 degrees (light violet against `--head-bg` is 55).
- The IP rule refuses `bad::cafe`, `a::b`, `1::`, `12:30:45:10` and `2:3:4:5` (unlikely in a block-count summary) and misses `::ffff:a00:1` and an IPv4 literal followed by a period ("sees 5.10.1.2."): inert text. Tighten if real answers ever trip it.

- **Depends on:** 20261009-64, 20261009-65.
- **Came from:** The reviews of 20261009-64 and -65, 2026-10-09 (minor).
- **Design:** report.
- **Status:** todo

### 20261010-1. `shared_scan_cte` GROUP BY widening: an untested guard.

From the review of 20261003-28 (minor). The `ref.fields.size == 2` check in `Grouping#read_columns` (`enclave/lib/quaack/enclave/rewrite_rules/shared_scan_cte/grouping.rb`) survives mutation: no test covers it. A related case: a nested subquery that reuses the copy's alias can make the rule add that subquery's column to the outer GROUP BY (harmless or refused by the prepare check, but untested). Add a test per case that goes red without the guard, and run both rewrites against Postgres to confirm equal rows. Enclave change: unreleased list.

- **Depends on:** 20261003-28.
- **Came from:** The review of 20261003-28, 2026-10-10 (minor).
- **Design:** rewrite-rules.
- **Status:** todo

### 20261010-2. rewrite-test fixtures: a row of another class with the copy set.

From 20261004-9's second paragraph and its review (a "Consider", left out of that task). `polymorphic_key_copy` rewrites a join through a denormalized copy (a column that holds a parent's id for rows of one class). The fixtures keep the copy equal for rows of the class, but nothing adds a row of ANOTHER class with the copy column set, so a twin of the rule that drops the type filter would pass rewrite-test. Make the fixture builder add such a row (a row of another class whose copy column is set, and one with no parent) when the schema has a polymorphic copy, test with a hand-written twin that drops the type filter (it must be disproved) and the real rule (it must pass), keep every row valid under the schema's constraints, and update DESIGN.md. A reviewer noted the fixture UPDATE that restores the copy also fires user triggers on the child table, which could change other columns (an unusual setup): check and note it. Enclave change: unreleased list.

- **Depends on:** 20261004-9.
- **Came from:** 20261004-9's entry and its review, 2026-10-10.
- **Design:** rewrite-test.
- **Status:** todo

### 20261010-4. rewrite-test variety: a unique self-FK, and the cases the review didn't check.

From the review of 20261003-39 (minor, and gaps in the review's coverage).
- With `parent_id bigint UNIQUE REFERENCES` its own table, a wrong rewrite (a filter on the child instead of the parent) still passes: `childless_parent` excludes self-references, so a unique self-FK's cross gets no fresh target and no distinguishing row. The task didn't promise it. Make the cross target a fresh parent row (a row that has no child) for a unique self-FK too, and add a wrong-twin test that passes today.
- The review did not check composite self-FKs, ON DELETE CASCADE self-FKs, partitioned tables or exclusion constraints, nor the row counts and runtime for a schema with ten FKs (by reading the code S3 grows linearly: 1 plus one row per pooled atom per self-FK, 2 per unique FK). Probe each with a correct and a wrong rewrite, measure the row count and time for a ten-FK schema (see 20261004-27 about rewrite-test CPU), and file any failures.

- **Depends on:** 20261003-39.
- **Came from:** The review of 20261003-39, 2026-10-10.
- **Design:** rewrite-test.
- **Status:** todo

### 20261010-5. rewrite-test: a unique cut foreign key's cross row.

From the review of 20261004-8 (minor). With `course_template_id bigint UNIQUE` (a cycle through a unique key) the cross row collides with the hit account's template, so that group is dropped: the correct twin still passes, but the wrong rewrite ("own template" rewritten as EXISTS own courses) passes too and goes undetected (the ORDER BY drop is still caught). Point a unique cut key's cross at a parent the hit doesn't hold (as 20261003-39 did for a unique FK with `childless_parent`), or list the case as a v1 gap in DESIGN.md. Enclave change: unreleased list. Related: 20261010-4 (a unique self-FK has the same shape).

- **Depends on:** 20261004-8, 20261003-39.
- **Came from:** The review of 20261004-8, 2026-10-10 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261010-6. Delete the producer-less error-line `cycle` field.

From 20261003-43. After the counterexamples round stopped naming a cycle on its error line, nothing in the enclave sends an error-line `cycle` field: `ErrorFilter::Cycle`, the driver's `ErrorFields.cycle`, `EnclaveError`'s cycle rendering, and the whitelist field are producer-less (the reviewer confirmed: the only exception that still has `cycle`, `Scenarios::Error` from the topology step, carries `TableName` structs and `shaped?` refuses them). They're harmless and kept as defense, but dead code on a trust boundary is a liability: delete them (a protocol change: unreleased list), or keep them and add a spec that pins why. Decide with the reviewer's view of whether a future producer is likely.

- **Depends on:** 20261003-43.
- **Came from:** 20261003-43's build and review, 2026-10-10.
- **Design:** What goes out of the enclave.
- **Status:** todo

### 20261010-7. Result comparison and literals: two small gaps from the review of 20261004-92 and -94.

- The `literals_already_used` pattern (`USERS`) lists the steps that store entries comparing literal sets by name, but `rewrite_prune`, `rewrite_check`, `index_test` and `index_rank` also load `literal_sets` and aren't in it. Harmless today (they write no entries compared across sets); add a spec that fails when a step that writes such an entry isn't listed, or list them.
- A full-run row-cap refusal is reported with the same rule as a timeout (`unsupported_order`), so the operator can't tell the two apart. Give the report a way to say which (a field or a separate note), if it matters to them.

- **Depends on:** 20261004-92, 20261004-94.
- **Came from:** The review of 20261004-92 and -94, 2026-10-10 (minor).
- **Design:** result comparison, literals.
- **Status:** todo

### 20261010-8. Index refusal rules: two gaps in the source scan.

From the review of 20261004-81 (minor). The scan only matches double-quoted literals, so (a) a rule written in single quotes, or built from a variable or constant (`Error.new(rule_var, ...)` outside the existing REFUSED_OPTIONS loop), would slip past it; add a guard that fails when an `Error.new(` in those files has a first argument that is neither a double-quoted literal nor one of the known dynamic forms. (b) The spec compares rule NAMES only: it doesn't check that each rule appears in a sample statement in `index_ddl_check_spec.rb` (the entry's `samples`), so a rule with no test of its own passes; add that check.

- **Depends on:** 20261004-81.
- **Came from:** The review of 20261004-81, 2026-10-10 (minor).
- **Design:** report, llm-index-ideas.
- **Status:** todo

### 20261010-9. Clock anchoring: small follow-ups from the review of 20261006-6.

(minor)
- The `current_time` anchor was checked against `now()::timetz` on Postgres 18 (including `current_time(3)` and a non-UTC TimeZone), but not against `quaack.clock_anchor()` itself: confirm `clock_anchor()` returns `timestamptz` like `now()` so `clock_anchor()::timetz` has the same semantics, with a spec.
- The driver's note for `run_from_older_version` (`driver/lib/quaack/driver/fixed_notes.rb`) says an older version started the run; for a corrupt or hand-edited inventory (now also refused with that rule when `TimeZone` is missing) that is slightly misleading. Word it to cover both, or add a rule (a protocol and driver change).
- Domain-typed and array casts in column defaults (`('today'::text)::public.clock_date`, `('{today}'::text)::date[]`) still read the wall clock: listed unsupported in v1. Decide whether to refuse such a default instead of letting it read the clock.

- **Depends on:** 20261006-6.
- **Came from:** The review of 20261006-6, 2026-10-10 (minor).
- **Design:** clock anchoring, arena setup.
- **Status:** todo

### 20261010-10. Index sources: a faithful store fake, and a mixed-label cell.

From the review of 20261004-89 (minor).
- The store fake in `enclave/spec/outbound_ddl_spec.rb` has an `entry?` that always returns false, so `IndexSources.sources` finds no searches and every entry's sources are `[]` in that spec. Harmless there (the sources path is covered against a real store in `report_payload_step_spec.rb`), but make the fake faithful (`def entry?(name) = data.key?(name)`).
- If a label mixes indexes with recorded sources and indexes without, the cell lists only the recorded sources and doesn't say some are unrecorded. Only a payload no single enclave version produces does this, so it's cosmetic; say "and others not recorded" or leave it.

- **Depends on:** 20261004-89.
- **Came from:** The review of 20261004-89, 2026-10-10 (minor).
- **Design:** report.
- **Status:** todo

### 20261010-11. Equality check: refuse when a same-signature `=` exists outside `pg_catalog`? (needs the user)

From the review of 20261007-58 (minor, a requirement question). The denormalized-equality check names its operator `OPERATOR(pg_catalog.=)`, so a planted `public.=(bigint, bigint)` can't change what the check reads (20261007-9's deliberate behavior; three specs depend on it). But the application's own queries use the bare `=`, which resolves through the search path: if the application's role sees a different `=` with the same signature, a rewrite could rest on an equality the application never uses. It takes a hostile or very unusual setup. Decide: (a) leave it (documented unsupported in v1), or (b) refuse the assumption when a same-signature `=` exists outside `pg_catalog` on the operand types, and update the three 20261007-9 specs and DESIGN.md's text for 20261007-9. Ask the user before building (b).

- **Depends on:** 20261007-58.
- **Came from:** The review of 20261007-58, 2026-10-10.
- **Design:** assumption check, CatalogShadow.
- **Status:** todo (needs the user)

### 20261010-12. `not_in_to_not_exists`: the same NOT IN twice in one SELECT.

From the review of 20261008-4 (minor). When the same NOT IN appears twice in one SELECT and Postgres needs the two copies to match, rewriting only one copy breaks the query: `SELECT x NOT IN (...), count(*) ... GROUP BY x NOT IN (...)` fails with "subquery uses ungrouped column" / "must appear in the GROUP BY clause", and `DISTINCT ON (x NOT IN ...) ... ORDER BY x NOT IN ...` fails with "DISTINCT ON expressions must match initial ORDER BY expressions". The rewrite errors instead of returning different rows, and plan-pruning discards a rewrite that fails to plan (`failed_to_plan`), so nothing wrong is recommended: it only wastes a candidate. Fix by rewriting every identical copy together, or refuse a condition that also appears in the same SELECT's GROUP BY, DISTINCT ON or ORDER BY. Add Postgres-backed tests for both queries and a note in docs/transforms/not_in_to_not_exists.md and DESIGN.md. Enclave change: unreleased list.

- **Depends on:** 20261008-4.
- **Came from:** The review of 20261008-4, 2026-10-10 (minor).
- **Design:** rewrite-rules.
- **Status:** todo

### 20261010-13. Deep EXPLAIN plans: one unbounded parse, and untested refusals.

From the review of 20261008-22 (minor).
- `single_candidate_test.rb` (`parse_plan`, ~line 269) still parses EXPLAIN JSON with `max_nesting: false`, which is unbounded; it doesn't crash at depth 100, but it's inconsistent with the new `PlainData::MAX_DEPTH` bound and a very deep plan could exhaust the stack before the parse fails. Use the same bound.
- In `Measurement.measure_set` and `IndexBuild.confirm`, a plan deeper than 3000 raises `JSON::NestingError`. Trace what the callers do with it: it must become a clean refusal (a fixed rule, no message), and add a test for a plan deeper than the bound in each path.

- **Depends on:** 20261008-22.
- **Came from:** The review of 20261008-22, 2026-10-10 (minor).
- **Design:** index-from-plan, measurement.
- **Status:** todo

### 20261010-14. `TableStatistics#type_map`: an empty type string isn't tested.

From the review of 20261008-24 and -25 (minor). Removing the `!v.empty?` check from `TableStatistics#type_map` leaves every spec green. It doesn't affect soundness (the value is only compared with `"bpchar"`), but add `column_types: { "id" => "" }` to the "rejects a type for a column that isn't in the list, and a type that isn't a name" example in `statistics_spec.rb`, and confirm it goes red without the check.

- **Depends on:** 20261008-25.
- **Came from:** The review of 20261008-24 and -25, 2026-10-10 (minor).
- **Design:** index-from-query.
- **Status:** todo

### 20261010-15. Load-order dedupe: test the laziness.

From the review of 20261008-33 (minor). Removing `.lazy` from `distinct_loads` leaves the load-order and counterexample specs green: the comment says a later order's `self_references` query isn't run when an earlier run ends the comparison, but no test shows it. Add a spec with a runner that counts calls (an earlier run that ends the comparison must leave the later orders' queries unrun) and confirm it goes red without `.lazy`.

- **Depends on:** 20261008-33.
- **Came from:** The review of 20261008-33, 2026-10-10 (minor).
- **Design:** fixture-compare.
- **Status:** todo

### 20261010-16. Candidate check: stable `*_in` and `*_recv` functions given a type oid.

The second review of 20261008-39 found this minor issue: rewrite candidates accept `record_in('(1)'::cstring, 999999, -1)`, `enum_in`, `array_in`, `domain_in`, `range_in`, `multirange_in` and their `*_recv` forms. They're stable, take a type oid, and raise "type with OID ... does not exist" or "cache lookup failed" for one that names nothing, so they probe whether a type oid exists. The completeness spec misses them because its `(in|out|send|recv|...)$` exclusion filters them out. Index DDL isn't affected, since an index expression must be immutable. Refuse a call to any `*_in` or `*_recv` function given an oid argument (or list these names), and narrow the spec's exclusion so they show up. It's exotic SQL that no ORM generates.

- **Depends on:** 20261008-39.
- **Came from:** The second review of 20261008-39, 2026-10-10.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261010-17. Tablespace check: minors from 20261008-38.

The reviews of 20261008-38 found these minor issues:

1. **Names only.** The comparison matches tablespaces by name and options. It never checks that the query's tables on the run server sit in the same tablespace as in production.
2. **Fail closed on a shortfall.** In qualify's tablespace query, a scanned relation missing from `pg_class` drops out of the needed set. `Relations.check` has already resolved every relation in the same transaction, so it can't happen today. Count the rows and refuse on a shortfall.
3. **TOAST tables** aren't looked at separately.
4. **Stale spec order.** `enclave/spec/cli_dispatcher_spec.rb:221` lists the old step order (harmless, it uses `match_array`).
5. **Flaky timing.** Two `reply_json_spec` examples with a 0.15 s bound failed once under heavy load.

- **Depends on:** 20261008-38.
- **Came from:** The reviews of 20261008-38, 2026-10-10.
- **Design:** What goes into the enclave.
- **Status:** todo
