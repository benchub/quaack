# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

- 20261012-1: value pools and simple CHECKs read each element of an `ARRAY[...]` under casts for `= ANY` and `<> ALL` (a varchar IN CHECK no longer refuses as `unsatisfiable_check`); no change to any reported field.

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

### 20261008-22. Live EXPLAIN JSON parses with JSON's default nesting limit. Done, see BACKLOG-COMPLETE.md.

### 20261008-23. index-from-plan booleans and MCV coverage: minors from 20260923-24. Done, see BACKLOG-COMPLETE.md.

### 20261008-25. index-from-query join reduction and pattern keys: minors from 20260923-21. Done, see BACKLOG-COMPLETE.md.

### 20261008-26. NATURAL JOIN marker: minors from 20260923-30. Done, see BACKLOG-COMPLETE.md.

### 20261008-28. Boolean folding in index-dedupe: minors from 20260923-36. Done, see BACKLOG-COMPLETE.md.

### 20261008-29. Rewrite candidate relation check: minors from 20260923-57. Done, see BACKLOG-COMPLETE.md.

### 20261008-30. Production inventory: minors from 20260924-24, and silent packet drops. Done, see BACKLOG-COMPLETE.md.

### 20261008-31. Rewrite candidates: a regclass literal reveals that a relation exists. Done, see BACKLOG-COMPLETE.md.

### 20261008-32. Rewrite candidates: whether a function, type, collation, or operator exists is visible. Done, see BACKLOG-COMPLETE.md.

### 20261008-33. Load orders: minors from 20260924-9, and skipping a redundant rotated run. Done, see BACKLOG-COMPLETE.md.

### 20261008-34. Statistics a non-owner production role can't see: extended statistics, expression indexes, and row security. Done, see BACKLOG-COMPLETE.md.

### 20261008-41. Candidate name lockdown: keyword operators and the failure for a pinned name. Done, see BACKLOG-COMPLETE.md.

### 20261008-47. Scenario loading: minors from 20260927-18. Done, see BACKLOG-COMPLETE.md.

### 20261008-50. Orphan index-build notes: advice that's moot after teardown. Done, see BACKLOG-COMPLETE.md.

### 20261008-51. `quaack start --database`: name production's database. Done, see BACKLOG-COMPLETE.md.

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
- **Status:** todo. Items 5 (plan depth: `Egress::TooDeep`, rule `plan_too_deep`) and 6 (`Cast#type` nil) landed 2026-10-10. Items 1 to 4 are open; 1 and 2 need design decisions, 3 and 4 are refactors to split.

### 20261008-55. Foreign cancels: minors from 20260929-29. Done, see BACKLOG-COMPLETE.md.

### 20261008-56. Rule generator: leftovers from 20261002-1.

1. **Three or more INs.** A query with three or more matching INs never gets its fully rewritten form, given depth two and the cap.
2. **Wider coverage.** Nested SELECTs and derived tables, unqualified columns, an IN in a join's ON, and `= ANY (subquery)`.
3. **The standalone spec's rule count.** `rewrite_rules_standalone_spec.rb` hard-codes 12 rules. Derive the count, or check that it's more than zero.
4. **A grandchild chain.** No test covers a legacy-inheritance chain where the table's only child has its own child.

- **Depends on:** 20261002-1.
- **Came from:** The build and review of 20261002-1, 2026-10-08.
- **Design:** rewrite-rules.
- **Landed so far:** items 3 and 4, 2026-10-10 (task/20261008-56; spec-only). Items 1 and 2 are open.
- **Status:** todo

### 20261008-57. Running the rules: leftovers from 20261002-2.

1. **`failed_checks` vs plan-pruning drops.** A rule-made rewrite that fails the checks is counted in rewrite-rules' `failed_checks` and also in plan-pruning's drops. Settle this with 20261001-19's counting.
2. **A second `status` call.** `CounterexampleStage` asks `status` again right after `RewriteStage` did. Fixing it means passing the entries between the stages.
3. **Which assumptions win on a deduped rewrite.** Dedupe now covers any later call of the same source, not just a rerun. A later rewrite with the same SQL but different stated assumptions keeps the earlier entry's assumptions. Say in DESIGN.md which wins, or merge them.
4. **Duplicate constant.** `RuleBugs::MISMATCHES` duplicates `RewriteFate::MISMATCHES`. Share one.

- **Depends on:** 20261002-2.
- **Came from:** The build and review of 20261002-2, 2026-10-08.
- **Design:** rewrite-rules, report.
- **Landed so far:** items 2, 3 and 4, 2026-10-11 (task/20261008-57; Opus review clean). Item 2: `RewriteStage.run` returns the status entries it read after rewrite-rules, llm-rewrites and operator-rewrites, and the later stages use them (no second `status` call; the guard stays). Item 3: stored rewrites dedupe on the SQL and the stated assumptions together, so the same SQL with different assumptions gets its own entry (DESIGN.md, rewrite-rules). Item 4 was already done. Open: item 1 (needs a counting decision: count a rule rewrite that fails the checks in `failed_checks`, in plan-pruning's drops, or both labelled as overlapping).
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

### 20261008-67. Inner cuts: a dead guard, and the remaining picks.

1. **A dead guard (second review of 20261008-61).** The `|| select[:larg]` guard in `InnerCuts.sole_table` never fires, since a set-operation node has no `from_clause`. Remove it.
2. **Inner DISTINCT, GROUP BY, and UNION picks (builder of 20261008-61).** A bad candidate can still match through these. DESIGN.md lists this as a known gap. Decide whether they get the same treatment as inner cuts.

- **Depends on:** 20261008-61.
- **Came from:** The build and second review of 20261008-61, 2026-10-08.
- **Design:** fixture-compare.
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

### 20261010-7. Result comparison and literals: two small gaps from the review of 20261004-92 and -94.

- The `literals_already_used` pattern (`USERS`) lists the steps that store entries comparing literal sets by name, but `rewrite_prune`, `rewrite_check`, `index_test` and `index_rank` also load `literal_sets` and aren't in it. Harmless today (they write no entries compared across sets); add a spec that fails when a step that writes such an entry isn't listed, or list them.
- A full-run row-cap refusal is reported with the same rule as a timeout (`unsupported_order`), so the operator can't tell the two apart. Give the report a way to say which (a field or a separate note), if it matters to them.

- **Depends on:** 20261004-92, 20261004-94.
- **Came from:** The review of 20261004-92 and -94, 2026-10-10 (minor).
- **Design:** result comparison, literals.
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
- **Landed so far:** items 2, 4 and 5, 2026-10-10 (task/20261010-17). Item 2: `Qualify.tablespaces` counts the tables its query finds and refuses with `unknown_relation` on a shortfall. Item 4: the dispatcher spec's step order. Item 5: the `reply_json_spec` bound is 1 s.
- **Open, needs the user:** item 1 (compare the run server's tablespaces with production's: how run-server learns the placement, and when to refuse) and item 3 (what to do about TOAST tables; one option is adding `reltoastrelid` to the `used` set).
- **Decided by the user (2026-10-11):** item 1 is a warning in the report, not a refusal. Item 3: TOAST tables' tablespaces count (a table's TOAST table is part of its storage).
- **Status:** todo

### 20261010-18. LLM adapter for the Claude Code CLI.

The `claude` CLI can run a single prompt and exit, the way the `copilot` CLI does (`claude -p`, with a model flag and no tools). Add a provider type, for example `claude_cli`, beside `copilot_cli`, modeled on `driver/lib/quaack/driver/llm/copilot_cli_adapter.rb`: a local command run once per ask without a shell, the prompt passed by file or stdin, a `command_template` with `{prompt_file}` and `{model}` placeholders, `timeout_seconds`, and the same error handling and reply shape checks as the other adapters. Check the CLI's current flags and output format (a JSON output mode, how to turn tools and session saving off, how it reports usage) before building. Keep it driver-only: the enclave must never see the adapter, and the prompt carries only what the other adapters already send. Update the provider list, the `llm` block rules and the example config in DESIGN.md and the README, and add the type to the boundary specs' provider coverage if they list providers.

- **Depends on:** none.
- **Came from:** the user, 2026-10-10.
- **Design:** LLM client.
- **Status:** todo



### 20261010-38. Aggregated columns: untested CHECK guard and the `MIN_APART` wrap.

From the review of 20261010-36:
1. **The CHECK guard in `Scenarios::FreeValues#default_value` has no test.** Replacing `value && @checks.allows?(table, col, value) ? value : :omit` with `value || :omit` leaves every focused spec green. Add a spec: a defaulted, aggregated column whose CHECK rejects the near miss's own value; the scenario must load and the atom be reported untested; red when the guard is dropped.
2. **`MIN_APART` (999_999) wraps negative on narrow numeric types** (`Literals.numeric` wraps above the type's maximum: smallint becomes -16989, `numeric(5,2)` goes negative), so a min() near miss silently stays untested. Clamp the value to the type's maximum, or skip the wrap for it; test with a smallint column.
3. A column read by both min() and max() gets only the max treatment; under `MIN_APART` a min-only column in a boundary group loses its boundary values (builder's known gaps).

- **Depends on:** 20261010-36 (landed).
- **Came from:** The review and build of 20261010-36, 2026-10-10.
- **Design:** rewrite-test, scenarios.
- **Status:** todo

### 20261010-39. Untested conditions: CTE, scalar subquery, second column tie, and shapes found while building 20261010-33/34.

Still in the corpus's `PENDING`, causes unconfirmed unless noted:
- CTE with an outer filter (`posts.created_at > $1`); scalar subquery in WHERE (`p2.published = $1`: the near miss must move avg() across the hit's score); a second column-to-column tie between the same two tables (`comments.user_id = posts.user_id`).
- A sibling that must fail every other scope the parent could pass through (20261010-34 fixed one level with `Plan#scope_mate`): a variant whose second UNION branch is `published = true AND score > 9` still leaves `score > $6` untested because the sibling fails `published` but passes `score > 9`, which satisfies branch 1.
- `SELECT count(*) FROM posts JOIN comments ... WHERE posts.id IN (SELECT posts.id FROM posts WHERE published AND title <> 'draft' AND user_id IN (...) AND id IN (501..504)) AND comments.user_id = 7` leaves `published`, `title` and the `id IN` untested.
- A count over an IN subquery whose second UNION ALL branch pins `posts.id IN (11..14)` leaves that branch's `score`, `title` and `id IN` untested.
- A manager self-join with both `m.id IN` and `e.id IN` lists gives an S1 that returns no rows; three atoms untested.
- A `HAVING count(*) > 1` query with a pinned `users.id IN` list leaves three atoms untested.
Add each to the corpus (`PENDING` with the shape and atoms), confirm each cause, fix what is cheap or clear and file the rest.

- **Depends on:** 20261010-36 and 20261010-34 (landed).
- **Came from:** The work on 20261010-36, -33 and -34, 2026-10-10. Priority: the untested conditions.
- **Design:** rewrite-test, scenarios.
- **Status:** todo

### 20261010-40. Scenarios: copies' child rows don't follow their copy's parent (possible fixture bug).

Found while building 20261010-33: in S6, with copies of posts under `posts.id IN (201..204)`, all three copied comments point at post 202, not at their own copy's post. If real, a copy's children attach to the wrong parent, so what S6 tests differs from what its description says (it can hide or invent differences between a rewrite and the original). Reproduce on the corpus schema, find whether it is by design (copies of one table's row share a parent) or a bug, and fix or document it with a test.

- **Depends on:** 20261010-33 (landed).
- **Came from:** The work on 20261010-33, 2026-10-10.
- **Design:** scenarios.
- **Status:** todo

### 20261010-41. Winner summary: minors from 20261010-37.

1. A repeated condition's column cut merges columns of different tables (`a.x = $1` and `b.x = $3` both read `x = $`), which can overstate how often a condition repeats; keep the qualifier when the query reads more than one table.
2. No spec covers a duplicate condition inside one OR arm (`a = $1 AND a = $2`): removing the `.uniq` on each arm's conjuncts stays green and would report a repeat that isn't one. Add the spec.
3. The `(all|every) quer(y|ies)` guard refuses a plain description such as "Every query in the run read fewer blocks"; narrow it to advice use.
4. No spec covers `Repeats.of` getting nil from a rejected `sql()` string (over 20000 characters or a NUL).
5. The three rule preconditions not checked in depth (implied_predicate_removal, cte_hoist_dedupe, unused_join_removal): verify against the code.
6. The not_in "when it wouldn't help" sentence says only when the rewrite doesn't apply, not when it doesn't pay off.

- **Depends on:** 20261010-37 (landed).
- **Came from:** The reviews of 20261010-37, 2026-10-10.
- **Design:** report.
- **Status:** todo

### 20261010-42. `s1_nonzero_rows`: what counts as empty.

From the review of 20261010-22. Only NULL and numeric zeros (regex `/\A[-+]?(0+(\.0*)?|\.0+)\z/`) count as empty, so values that read as empty but aren't numeric zeros count as nonzero: `bool_or`/`bool_and` returning `f`, a zero interval (`00:00:00`), an empty string, an epoch-like date. It is a heuristic, not a security issue. Say so in DESIGN.md (only NULL and numeric zero count as empty), and decide whether `bool_or` (the existence-check shapes) needs `f` counted as empty.

- **Depends on:** 20261010-22 (landed).
- **Came from:** The review of 20261010-22, 2026-10-10.
- **Design:** rewrite-test.
- **Status:** todo

### 20261010-44. Burndown: minors from 20261010-20.

1. **index-rank's added slice counts combinations, not ideas.** "Trying indexes together" adds 6 combinations (`added: {combinations: 6}`), which the funnel now draws as a lighter slice on top of the 9 ideas it takes in (widest point 15) and then narrows to 4 that went on. That mixes units, and it is the kind of "output wider than input" picture the user objected to. Leave index-rank out of the added slice, or draw it as a separate kind of mark, and word its label so it doesn't read as added ideas.
2. **The rewrites' index searches join only loosely.** The replay check (`spec/pipeline_replay_spec.rb`, `burndown_joins?` with `strict: false`) requires only `in < running` on the summed "Index ideas for the rewrites" rows, which can hide a real under-carry. Check each `rewrite_N` search strictly, one at a time, and show why a narrowing happens (a rewrite dropped after its index search keeps its index-test out but has no LLM round).
3. No focused enclave unit spec for `RewriteBurndown#carried` (nearest earlier stage, falling back past a missing stage); it is covered only through the replay and rewrite step specs.
4. The two extra synthetic funnel cases (a round that adds more than it keeps, a skipped refine) weren't rendered in headless Firefox.

- **Depends on:** 20261010-20 (landed).
- **Came from:** The reviews of 20261010-20, 2026-10-10.
- **Design:** report, burndown.
- **Status:** todo

### 20261010-46. Untested conditions: a count threshold with other conditions (`count(...) > 2 AND title = 'x' AND score > 3`).

From the review of 20261010-35, pre-existing on `main` and the branch: `(SELECT count(*) ...) > 2 AND title = 'x' AND score > 3` leaves `title` and `score` untested, because their near misses have one child and so fail the count too. A near miss for a non-count atom needs the parent to keep its n+1 children (and fail only its own atom). Find the cause in the scenario build, fix it without weakening the guard, and add the corpus shape.

- **Depends on:** 20261010-35 (landed when its fix round lands).
- **Came from:** The review of 20261010-35, 2026-10-10. Priority: the untested conditions.
- **Design:** rewrite-test, scenarios.
- **Status:** todo

### 20261010-47. Trust boundary: counts that leave the enclave vary with query literals (LIMIT, IN-list values).

Found by the second review of 20261010-35, pre-existing on `main`. Reported counts depend on literal values, which must not cross the boundary (DESIGN: shapes, counts and fixed names cross, never values):
- `fixture_loads` (the burndown total, via `ScenarioTests::Report` `loads`) varies with the LIMIT value at equal untested sets: with no ORDER BY, `LIMIT 1` gives 26 and `LIMIT >= 2` gives 22; with ORDER BY, `LIMIT 0` gives 23 and `LIMIT 1` gives 47.
- `dropped`, `fixture_loads` and the spills vary with IN-list values (not just their count): `user_id IN (7,10,16)` gives dropped 3 and an extra S5 spill; `(1,4,10)`, `(2,5,11)` and `(100,103,109)` give 2.
- The cause of the loads steps: `ResultComparison::LoadOrders.distinct_loads` skips the rotated run when a table run has fewer than 3 rows (the same mechanism that carried the count threshold in the rejected 20261010-35 extra-children feature).
Work out which reported fields can vary with a literal, using the reviewer's experiment as the starting point (scratchpad `review-20261010-35-r2/` of that session: a spec that runs `ScenarioTests.run` per query family varying only the literal, comparing every outgoing field: results, untested shapes, retries, dropped, loads, s1 diagnostics, spills; rebuild it as a committed spec), then make each reported count independent of literal values: bucket it, report a value that doesn't depend on the data, or compute it from shape only (for example count a fixed number of load orders per comparison). The `(a, b, c)` values of an IN list are values; the number of elements is shape. Add the across-literals spec for LIMIT, OFFSET, IN-list values, BETWEEN bounds and count thresholds, as a standing guard (byte-identical outgoing messages when only literals change). This is a Security/Privacy-relevant boundary check; have an Opus reviewer.

- **Also cover (from the review of 20261010-43, 2026-10-10):** the vacuity-guard search's pools hold IN-list values and BETWEEN bounds, so which atoms stay untested, and their `untested_states` words, can change when only those literals change. Extend the across-literals spec to the untested set and `untested_states`.
- **Depends on:** 20261010-35 (landed).
- **Came from:** The second review of 20261010-35, 2026-10-10. Priority: trust boundary.
- **Design:** What goes into the enclave; the burndown.
- **Landed so far:** 2026-10-11 (task/20261010-47; Opus review: no regression, a strict improvement). `across_literals_postgres_spec.rb` (11 families, byte-identical reports across literal values within one side of a reach boundary); each fixture compare counts as 3 loads and the guard's LIMIT/OFFSET comparisons count none; a group's own pinned key avoids every pooled value. Still open, carried by 20261011-2.
- **Status:** todo (see 20261011-2)

### 20261010-48. Untested conditions: a correlated count threshold, built without leaking the threshold.

20261010-35 built n+1 children for a correlated scalar count compared to an integer literal (so `(SELECT count(*) FROM comments c WHERE c.post_id = p.id) > 2` is fully tested), but its second review found the threshold leaked through `fixture_loads` (`distinct_loads` steps at 3 rows), and the feature was removed before landing. Rebuild it so that no reported count depends on the threshold (do 20261010-47 first or together: the standing across-literals spec must pass for thresholds 0..9 and every operator), with these findings from the reviews: children only for count(*)/count(x) with no GROUP BY, window and a single target (a non-aggregate scalar subquery returning several rows crashed the guard: `(SELECT p.score FROM posts p WHERE p.user_id = u.id) > 3`); also a count sharing its child table with a non-count scalar subquery crashed S1 (`count(*) > 1 AND (SELECT p2.score ...) > 3`); the child count follows the operator and its side (n+1 for `>`, n for `>=`, `=` and `<=`, n-1 for `<`, 2 for `<> 1` else 1, within 1..10); `count > n` vs `count >= n` rewrites pass rewrite-test for n = 2 and 4..9 because no parent has exactly n children (main misses it too): add a boundary parent with exactly n children and one with n+1; near misses of other atoms under a count threshold keep their children (20261010-46); tighten `Protocol::VacuityDiagnostic.valid?` to nil, 0 or 1 for `s1_rows` and `s1_nonzero_rows` (defense in depth). The rejected branch's code is in git history (task/20261010-35's earlier commits c556f60e and 950568a2).

- **Depends on:** 20261010-47, 20261010-35.
- **Came from:** The reviews of 20261010-35, 2026-10-10. Priority: the untested conditions.
- **Design:** rewrite-test, scenarios.
- **Also (review of 20261011-2, 2026-10-11):** `loads` follow a candidate's verdict, not the fixed worst case: with a non-equivalent candidate, results flip between n <= 1 (S1 row_count fail) and n >= 2 (pass), and loads flip 10 vs 25 with them, because testing stops at the first failing scenario. About one bit (whether n is at or below S1's reach) is recoverable. Include `loads` and the verdict in the work.
- **Status:** todo

### 20261010-49. Minors from 20261010-35 and -23.

1. The across-thresholds spec in `scenarios_unmatched_postgres_spec.rb` doesn't compare `untested_atoms` (its size goes to the burndown, its indices to counterexamples), `s1_load_rule` or `results`; add them.
2. In `vacuity_guard_postgres_spec.rb` (around line 47) "records no load failure and the original's row count on S1" asserts `eq([expected, 2].min)`; the cap is now 1: use `REPORTED_ROWS`.
3. `Protocol::VacuityDiagnostic.valid?` still accepts any Integer up to `MAX_ROWS` for `s1_rows` and `s1_nonzero_rows`: tighten to nil, 0 or 1 (defense in depth; also in 20261010-48).
4. A weak test for the Branches look-ahead (`.map(&:first)` vs `.map(&:last)` survived before the fix round; check it is now killed).

- **Depends on:** 20261010-35 (landed).
- **Came from:** The reviews of 20261010-35 and -23, 2026-10-10.
- **Design:** rewrite-test, scenarios.
- **Status:** todo

### 20261010-51. Vacuity-guard search: loose ends from 20261010-43.

1. The search skips every query with a LIMIT or OFFSET (it made the threshold-invariance spec fail). That leaves out ORM `find_by ... LIMIT 1` queries. Find a way to search them without letting the result vary with the LIMIT value (do 20261010-47 first).
2. `untested_states` isn't in the counterexample payload.
3. There's no separate word for "no difference within the search bound" (the exhaustive small pass finished). Add one only if the report can say it truthfully.
4. The README sample doesn't show the state sentence.
5. `Search::Trials` treats each column of a composite unique key as unique on its own (`uniques.flatten`). That wastes trials and is safe; make only the whole key unique.

- **Depends on:** 20261010-43 (landed), 20261010-47 for item 1.
- **Came from:** The build and review of 20261010-43, 2026-10-10.
- **Design:** rewrite-test, scenarios, report.
- **Status:** todo

### 20261010-52. `not_in_to_not_exists` repeat check: scope and spelling.

From the review of 20261010-12 (minor). `repeated?` uses `Tree.find_all(select, ...)`, which probably also counts copies in nested subqueries and CTEs of the same SELECT, so a copy in another scope plus one in GROUP BY or ORDER BY refuses a rewrite that would have worked (untested). Copies written differently (another alias, an added cast) aren't detected and fall back to `failed_to_plan`, which is safe but wastes a candidate; list that in docs/transforms/not_in_to_not_exists.md. Test the nested-scope case and either count only this SELECT's own copies or document the extra refusal.

- **Depends on:** 20261010-12 (landed).
- **Came from:** The review of 20261010-12, 2026-10-10.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261011-5. Denormalized fixture: a UNIQUE or CHECK on the copy column (minors from 20261010-2).

The review of 20261010-2 found: if the copy column has a UNIQUE (or exclusion) constraint, update 3 gives every parentless row the same class-parent id, and update 2 can repeat ids too, so the load fails (`fixture_load_failed`, a refusal, not a false disproof) where the old single update loaded. A CHECK on the copy column that another class's parent id violates fails the load the same way. A unique denormalized copy such as `course_id` isn't realistic, so both are minor. Possible fix: skip updates 2 and 3, or limit update 3 to one row, when the copy column has a unique index; with a CHECK, skip them too. Postgres-backed tests for each, red first.

- **Depends on:** 20261010-2 (landed).
- **Came from:** The review of 20261010-2, 2026-10-11 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261011-6. Duplicate IN-list values leak whether two literals are equal.

From the reviews of 20261011-2 and its builder. `email IN ('a','a')` and `('x','x')` report dropped 9 and loads 49, while `('a','b')` reports 5 and 34, so the fact that two literals are equal crosses the boundary (not the values). Duplicates are rare in app SQL. Dedupe the IN-list values (or refuse a duplicate) before the scenarios are built, so the report doesn't depend on it, and add a family to `across_literals_postgres_spec.rb`: `IN ('a','a')`, `('a','b')`, `('x','y')`, red first. Enclave change.

- **Depends on:** 20261010-47 (landed).
- **Came from:** The review of 20261011-2, 2026-10-11 (minor, trust boundary).
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261011-7. A count threshold makes every atom of the query untested; keep the atoms outside the aggregate's scope.

From the review of 20261011-2 (minor, usefulness). Since 20261011-2, any query that compares an aggregate with a constant reports every atom as untested, including atoms unrelated to the count (`published = true` next to `HAVING count(*) > 5`). That is common in reporting and ORM SQL, so the guard says nothing useful for those queries. Keep the real result for atoms outside the aggregate's scope (WHERE atoms of the grouped query whose S1 reach doesn't depend on the threshold); only the threshold atom, and atoms inside its correlated subquery, get the worst case. It needs its own across-literals proof (thresholds 0..10, all operators, every outgoing field identical, with the other atoms' states real), red first, and the corpus HAVING entries then expect the other atoms tested again. Opus builder and reviewer.

- **Depends on:** 20261011-2 (landed with its fix round).
- **Came from:** The review of 20261011-2, 2026-10-11 (minor).
- **Design:** rewrite-test, scenarios.
- **Status:** todo

### 20261011-8. report_spec: `html` and `ranking` are memoized lets, so a second render after changing the payload is stale.

Found in the build of 20261010-10. In `driver/spec/report_spec.rb` the memoized `html` and `ranking` lets make a second `whos` call after mutating the payload return the stale render. The existing example "says not recorded for the indexes of a run that recorded no sources" calls `whos` twice and likely has this weakness in its second half (it may pass whatever the code does). Render fresh for each call (build the report in a helper, not a memoized let), then mutate the code under test to confirm that example goes red. Check the other examples that call a render helper twice.

- **Depends on:** 20261010-10 (landed).
- **Came from:** The build of 20261010-10, 2026-10-11.
- **Design:** report.
- **Status:** todo

### 20261011-10. Rewrite budget: minors from 20261010-53.

(1) DESIGN.md's budget sentence doesn't say a running statement can overrun the deadline by up to its 10 s `statement_timeout`: add one clause. (2) An out-of-time rewrite-test records an empty report, so the burndown loses the fixture loads and retries it really used and under-counts the work done; carry the counts the test had reached into the burndown (as fixed small counts, not literals; check 20261011-2's worst-case rules and 20261010-47's across-literals spec so the count doesn't vary with a literal), or say in DESIGN.md that out-of-time rewrites count as 0. (3) Counterexample rounds have no overall budget (only the 10 s per statement); say in DESIGN.md why that's fine (they load only the LLM's inserts), or add one if rounds can pile up.

- **Depends on:** 20261010-53 (landed).
- **Came from:** The review of 20261010-53, 2026-10-11 (minor).
- **Design:** rewrite-test, burndown.
- **Status:** todo

### 20261011-11. Rewrite dedupe: normalize the stated assumptions, and say what happens to the same SQL with different assumptions.

From the review of 20261008-57 (minor). Dedupe now matches on the SQL plus the stated assumptions as the raw array the LLM sent, so the same assumptions in another order or with trivially different text become a separate entry that gets its own rewrite-test, counterexamples, burndown count and report row (two rewrites that look the same). A rerun of the same input is unaffected. Compare a sorted, normalized form (strip and collapse whitespace, sort) so reordering dedupes. Also say in DESIGN.md whether two entries with the same SQL and really different assumptions are both tested and ranked (extra time and LLM calls, the same SQL twice in the report) or whether the report groups them. Enclave change.

- **Depends on:** 20261008-57 (landed).
- **Came from:** The review of 20261008-57, 2026-10-11 (minor).
- **Design:** rewrite-rules, report.
- **Status:** todo

### 20261011-12. Keyword operators in candidates: refuse an ambiguous one the original doesn't use (and document the original's behavior).

From 20261008-44 (option b) and item 1 of 20261008-41. The original query's keyword operators (IN, BETWEEN, NOT BETWEEN, LIKE, ILIKE, IS DISTINCT FROM, NULLIF, simple CASE, USING, NATURAL) stay bare and resolve through the stored `search_path`, which every racetrack and arena connection sets, so they behave on the run server as in production given the same dump. A rewrite candidate (LLM or rule) could add a keyword form the original doesn't use whose operator resolves differently on the path (more than one usable schema on the path defines the operator, such as citext or hstore next to pg_catalog). Fix in the candidate name lockdown: refuse a candidate whose keyword operator is ambiguous on the path unless the original uses the same keyword form (mirror `unmade_lookup`'s exemption); reuse an existing rule code if one fits (a new rule code needs the protocol `ErrorRules` and driver text). Add a DESIGN.md paragraph saying how keyword operators resolve and what is refused. Postgres-backed tests with a user schema defining a same-signature `=`/`~~`/`LIKE`-family operator placed ahead of or beside pg_catalog on the path (red first, mutate), and one that shows an ordinary query with IN, BETWEEN and LIKE and no ambiguity still passes. Enclave change; trust boundary (Opus builder and reviewer).

- **Depends on:** 20261008-41 (landed), 20261007-21 (landed).
- **Came from:** The builder of 20261008-44, 2026-10-11.
- **Design:** qualify, rewrite-check.
- **Built, not merged:** branch `task/20261011-12` (head `6270cc2a`), two Opus reviews clean (the first found the refusal too coarse for citext and hstore in `public`; the fix narrows it to operators with a reachable argument type, `rewrite_candidate_check/keyword_reach.rb`). Held until after the 0.1.33 bump so `main` stays deployable; merge it as the first change of the next batch and put `20261011-12` on the unreleased list. Minors: a relation's row type (`pg_class.reltype`) isn't among the seen types, so a user operator on a composite row type in a whole-row comparison like `(t.*) IN (...)` gets through (add `reltype`, or refuse whole-row operands of keyword forms); the example at `rewrite_candidate_check_spec.rb:1201` covers three rules at once (implicit-cast target, pseudo-type, function result type): split it; one earlier full run had a single unidentified failure in `rewrite_candidate_check_spec.rb` that didn't recur: watch for it.
- **Status:** todo

### 20261011-13. rewrite-test is still too slow on the user's 583-table schema.

The user's first run on 0.1.33 (2026-10-11): arena of 583 tables, 5 rewrites in rewrite-correctness; the first took 2 s and the other four each hit the 5-minute budget (`out_of_time`, "Couldn't test the rewrite within 5 minutes"), so 0 of 5 passed in 20m15s. The budget works as designed, but it hides that testing is still far too slow. The RowSet fix (20261011-4) removed one quadratic cost, and something else dominates at this table count. Reproduce on a synthetic ~580-table schema, profile, fix the top hot spots test-first without changing any reported field (across-literals spec and corpus stay green). Also get the user's own profile from a by-hand run of `quaacks rewrite-test --search rewrite_N` on 0.1.33 (the per-rewrite deadline now ends the step and the profile is written at the end).

- **Depends on:** 20261011-4 (landed), 20261010-53 (landed), 20261012-2.
- **Came from:** The user's run, 2026-10-11. Priority: high, the pipeline can't test rewrites on the real schema.
- **Design:** rewrite-test, scenarios.
- **Landed so far:** 2026-10-11 (task/20261011-13; Opus review: no blocking findings, the full report byte-identical on main and the branch for 40 and 580 tables, with and without an extra join). `Parts#spill?` no longer re-runs `parents_of` for every fixture each try is offered to (it was cubic: 3.3M calls became 55k); a new `Scenarios::Held` index replaces `RowSet`'s group scans in `parents_of` and `orphan?`; `Sequences.advance` sends one statement per load (`json_to_recordset`) instead of one `setval` per integer column; `Values#shared_nth` is memoized; `FixtureRow` keeps its hash. On the synthetic 580-table schema with a joined table whose FK parent closure reaches 20 tables: 300.7 s to 21.7 s; 34 tables: at least 207 s to 105 s; 168 tables: still minutes. Not yet measured on the user's real schema.
- **Still open:** the parent closure itself (a joined table that reaches dozens of tables through foreign keys makes every group lift hundreds of parents, times the guard's up-to-4 rebuilds, times many spilled fixtures). Option: set a nullable foreign key to a table outside the query to NULL when neither the query nor the candidate reads that column, so no parent is lifted. It changes which rows the fixtures contain, so it needs the user's go (20261011-18). The user, 2026-10-12, chose instead to replace ScenarioTests with a disproof search that fills only the queries' own tables (20261012-2, 20261012-4), and deprioritized 20261011-18. Close this task once 20261012-2 has been measured on the user's real schema.
- **Minors:** nothing tests multi-try spill order in `Parts` (changing `lifted`'s `if i == done.size` to `if done.empty?` leaves 584 examples green): add a spec; no spec compares a whole scenario build, with loaded rows dumped, between the old and the new code: add a reference spec.
- **Status:** in progress (the rest waits on 20261012-2)

### 20261011-16. A standalone randomized differential test of each rewrite (hundreds of small databases). Dropped, see BACKLOG-COMPLETE.md.

### 20261011-18. rewrite-test: narrow the foreign-key parent closure (nullable keys to tables outside the query).

From 20261011-13. A joined table whose foreign keys reach 20, 34 or 168 tables makes every group lift all those parents' rows into every fixture (and the guard rebuilds up to four times, across many spilled fixtures), which is the remaining cost at the user's scale (583 tables; 168-table closures still take minutes). Idea: when a foreign key column is nullable, the table it points at isn't one the query or the candidate reads, and the column itself isn't read by the query or the candidate (select list, join, filter, group, order, a function, a window; use the existing read-column analysis in `scenarios/reads.rb`), set it to NULL instead of lifting a parent; a NOT NULL key still needs its parent. Soundness: the fixtures then hold NULL in a column nobody reads, so no query result can depend on it; check for CHECKs, unique and exclusion constraints, generated columns and triggers (disabled in the arena) that read it, and cascades. Measure on the synthetic 580-table schema (`scratchpad/build-20261011-13/gen.rb`): expect the 168-table case to drop from minutes to seconds. Reported values must stay identical where the closure was unnecessary; add a reference build-level spec comparing fixtures and reports old versus new on several schema shapes (also the review's minors: a multi-try spill order spec, a whole-build reference spec with loaded rows dumped). Opus builder and reviewer. Needs the user's go because fixtures change.

- **Depends on:** 20261011-13 (landed).
- **Came from:** 20261011-13's builder and review, 2026-10-11.
- **Design:** rewrite-test, scenarios.
- **Status:** todo (deprioritized by the user, 2026-10-12: 20261012-2's search fills only the queries' own tables, so it needs no closure; drop this when 20261012-4 removes ScenarioTests)

### 20261012-1. A CHECK's IN list on a varchar column reads as one array literal. Done, see BACKLOG-COMPLETE.md.

### 20261012-2. rewrite-test: a disproof search over small random databases on the queries' own tables.

The user, 2026-10-12: rewrite-test still hits its 5-minute budget on the 583-table schema, and the LLM counterexamples that follow are weak evidence when they find nothing. A spike (`scratch/spike-disproof/` in the main checkout, git-ignored; results in its `RESULTS.md`) built three non-LLM disproof searches and compared them with today's ScenarioTests on four corpora whose labels the searches didn't make: the e2e cases' 14 planted traps and 33 sound queries; 208 mutants of those sound queries (152 wrong, 53 hand-checked equivalent, 3 errors); an 18-query, 62-rewrite hand-labelled corpus on a synthetic 582-table Canvas-like schema; and 121 real LLM rewrites from the recorded runs. The swarm search caught every wrong rewrite (14/14 traps, 152/152 mutants, 34/34 Canvas) with no false disproof, in a 10 to 15 s budget, with a median time to a counterexample of 0.02 s and a maximum of 4.3 s. ScenarioTests caught 10/14, 92/152 and 16/34; on one Canvas query it took about 75 s per rewrite even with the full 5 minutes, and it left out 14 of the 28 sound Canvas rewrites (10 refused by 20261012-1, 4 when a fixture failed to load). This supersedes 20261011-16.

Build it in the enclave, near `vacuity_guard/search/` and `scenario_tests.rb`, called from `Steps::Counterexamples::RewriteTest` before ScenarioTests: a counterexample disproves the rewrite and ScenarioTests doesn't run; a pass goes on to ScenarioTests as today, until 20261012-4 removes it. How it works:

- Footprint: rows go only into the tables the original or the rewrite reads. Inside the arena's rolled-back transaction, the foreign keys from a footprint table to a table outside it are dropped, so no world needs the parent closure. Foreign keys between footprint tables stay enforced.
- Values: per column, the queries' own constants (a dictionary of every literal in either query, offered to each column of a compatible type, since atoms miss columns read through a CTE or subquery output), their neighbours (one step of the column's type either side), NULL for a nullable column, duplicates, the type's boundaries, and a few typical values. Join and FK columns share a small typed key pool, so joins match.
- Search: each trial loads a random world of 0 to 4 rows per footprint table under a savepoint, runs both queries, compares them cheaply first and with the official `ResultComparison` on any difference, then rolls back to the savepoint. Seeded, so a run can be repeated by hand.
- Lift: a candidate counterexample is reloaded in a fresh transaction with every constraint enforced, plus generated parent rows for each out-of-footprint reference (nullable foreign keys on those parents set to NULL), and compared again. Only a lifted counterexample disproves, so no disproof rests on a dropped constraint. The user gave the go for this on 2026-10-12. It amends DESIGN.md's "never bypass constraints" for the search, as rewrite-test's `denormalized_equal` handling already does: update DESIGN.md.
- Assumptions: honour a rule's `denormalized_equal`, and any other assumption the rewrite states, in every world, as ScenarioTests does.
- Budget: the existing 5-minute per-rewrite deadline (`Protocol::RewriteBudget`) is the cap. The user, 2026-10-12: 300 s is fine "assuming it's not wasted work; some rewrites will be huge". So stop early once the search has saturated, and use the whole cap only while it keeps reaching new ground.
- Trust boundary: the worlds hold real literals and never leave the enclave. Only the rule (row_count, multiset, order), counts, and fixed words go to the driver, as for ScenarioTests now. Sentinel tests for both.
- Burndown (the user, 2026-10-12): the search is its own burndown stage, between plan-pruning and rewrite-test, so the report shows what it caught apart from ScenarioTests and the LLM counterexamples. Its record has `in`, `out`, drops by the comparison's rule, and the trials it ran as an extra. That means a row in DESIGN.md's burndown table, and everything in the driver's report that knows `rewrite-test` by name: the Sankey layer, its color and its unit (`sankey.rb`, `sankey_layers.rb`, and the colors that lived in `report/funnel.rb` before 20261012-6), the stage sentence (`stage_sentences.rb`), the words (`words.rb`, `stages.rb`), and the spec that checks that the recorded stages join up. Also the step's progress line (`pipeline.rb`), a fate of its own in `RewriteFate` with its wording in the rewrite's section (`report/rewrites.rb`), and `rule_bugs`, since a rule-made rewrite the search disproves is a rule bug. A run from before the stage existed must still render.

Spike lessons the build must keep (each one caused a missed disproof or a false refusal there):
- Key pools are typed: a `timestamptz` join key needs `timestamptz` keys.
- Never use `ON CONFLICT DO NOTHING`. It silently drops a row that collides on a unique column the query reads; fix the collision instead.
- Typical values cover `bit(n)`, `money`, `tsvector`, `point`, and a long text (an `overlay(... FOR 13)` needed 19 characters).
- Steps follow the type: 1 microsecond for a timestamp, 0.000001 for a numeric of scale 6.
- Expression unique indexes need handling, and a CHECKed unique column cycles through the CHECK's values.
- Whether a world is legal is decided per query: don't merge the two queries' verdicts.

Answers (the user, 2026-10-12):
- Stop rule: run at least 30 s, then stop once the search has gone twice as long as it took to find its last new kind of database (a new coverage signature), never past the 5-minute cap.
- The burndown stage is named `fuzz` (the enumeration in 20261012-3 is `enumerate`).
- A rewrite's section says how many random databases it survived, such as "It also survived 41,200 random small databases built around its own values".
- A counterexample is shrunk to a minimal one. The report gives its size per table and the rule (such as 2 rows in orders and 1 in customers; row count differs), never its rows.

Open questions: whether the `rewrite_test` message gets new fields (trials, the stage's name) and what egress checks on them; what counts as a coverage signature.

From 20261012-5's phase 1 (2026-10-12, `scratch/corpus-20261012-5/REPORT.md` in the main checkout), two traps in the spike's code that the build must avoid:
- The footprint reads only schema-qualified relations, as `Scenarios.query_tables` does. Production qualifies both queries before rewrite-test, but a spec or harness that feeds raw SQL gets an empty footprint and a pass that tested nothing. Make an empty footprint for a query that reads a table an error, not a pass.
- After a candidate fails with a data error, the spike's lift read an out-of-footprint parent's catalog on the aborted transaction, so every lift failed with "current transaction is aborted" and the counterexample was lost. Roll back to the world's savepoint before lifting.

- **Depends on:** 20261011-15 (landed), 20261012-6.
- **Came from:** The user and the disproof spike, 2026-10-12.
- **Design:** rewrite-test, fixture-scenarios, llm-counterexamples.
- **Status:** todo

### 20261012-3. rewrite-test: a bounded enumeration pass after the random search, and what a pass says.

From 20261012-2. A random search's pass says only that N random databases didn't differ. The spike's algorithm B enumerates worlds instead. It reduces each row to a kind, a tuple of value classes per column drawn from the same value domains, and tries every world in order of total rows, so a pass can say "no database of at most w rows over these value classes differs". In the spike, in 15 s, w reached 8 to 12 on single-table queries, 4 to 8 on two tables, and 4 on four tables. It caught 151 of 152 wrong mutants (it missed one that needs 4 orders per customer) and 32 of 34 wrong Canvas rewrites (two 4-table queries need more than 4 rows). Run it when the random search finds nothing, within the same per-rewrite cap and saturation rule. Like the search (20261012-2), it's its own burndown stage, `enumerate`, between `fuzz` and rewrite-test (the user, 2026-10-12). It gets a record with drops by rule, the worlds it tried, and the bound w it finished as extras, plus everything that stage needs in the Sankey, the table, the stage sentence, the fates, and `rule_bugs`. Decide with the user how a pass is worded (such as "survived N random small databases and every database of up to w rows over its value classes"), where it shows (the rewrite's section and the burndown), and how the counts leave the enclave (integers only).

- **Depends on:** 20261012-2.
- **Came from:** The user and the disproof spike, 2026-10-12.
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-4. rewrite-test: replace ScenarioTests with the disproof search.

The user, 2026-10-12: replace ScenarioTests entirely, not just run the search before it. Once 20261012-2 and 20261012-3 have landed and been measured on the user's real schema, remove the scenario builder from rewrite-test and everything that names it:
- `ScenarioTests` and `Scenarios`, keeping whatever the search reuses, such as `Checks` and `ValuePools`.
- The vacuity guard's replay of its fixtures into scenarios.
- RewriteFate's `SCENARIOS` and the fates' `scenario` field.
- The burndown's `rewrite-test` stage, with its per-scenario reasons (s0 to s6), and its Sankey layer, sentence and words in the driver. The search's and the enumeration's stages, added by 20261012-2 and 20261012-3, stay in the burndown and take its place (the user, 2026-10-12), so rewrite-correctness still shows what each mechanical stage caught.
- The report's untested shapes and dropped scenario groups.
- `rule_bugs`' scenario rules.
- DESIGN.md's fixture-scenarios and vacuity-guard sections.
- The specs and recorded pipeline replays that pin all of these.

Stored entries and messages from older versions must still read, as `out_of_time` ones from before 20261011-15 do. A fixture that fails to load stops being a rewrite-level failure: today it leaves the rewrite out as `rewrite_test_failed` (4 sound Canvas rewrites in the spike), but in the search it's just an illegal world. Decide with the user:
- What replaces the vacuity guard's guarantee that every atom of the original was exercised. The search can report which atoms came out both true and false across its trials, and caution or refuse when one never did.
- What replaces a scenario's name where the report and burndown say why a rewrite was disproved.

- **Depends on:** 20261012-2, 20261012-3.
- **Came from:** The user, 2026-10-12.
- **Design:** rewrite-test, fixture-scenarios, vacuity-guard.
- **Status:** todo

### 20261012-5. Measure what the LLM counterexamples catch that the mechanical search and enumeration don't. Done, see BACKLOG-COMPLETE.md.

### 20261012-6. Report: remove the burndown funnels; the Sankey diagrams replace them.

The user, 2026-10-12: the Sankey diagrams are better, so stop spending work on the funnels. Remove every funnel from the report's burndown:
- the original query's indexes, the rewrites, and the rewrites' index searches;
- `report/funnel.rb`'s drawing, the template's `<h4>Funnel</h4>` and `svg.funnel` styles, and the note that says the funnel and the Sankey show the same counts;
- the specs that pin funnels, such as `report_spec.rb`, `report_out_of_time_spec.rb`, and `pipeline_replay_spec.rb`'s first-band checks from 20261009-43 and 20261009-53.

What the Sankey uses from `Funnel` stays, under a name of its own: the stage colors (`COLORS`, `BLUE`), `text`, `untimed` and `untimed_note`, `NOT_NONE`, and the counting helpers (`funnel_counted`). Rename the `--funnel-text` and `--funnel-count` CSS variables, which the Sankey also uses, and keep their dark values. Each section then reads Sankey diagrams, then the table. The table keeps every exact number, and the recorded-runs spec still checks that the stage records join up. Anything a funnel showed that no Sankey or table shows must not be lost, such as the not-recorded and partial stages, and the "went on though not tested in time" note: check that the Sankey or the table carries each one. Update DESIGN.md's burndown section, dropping the funnel paragraph and the "may be replaced by the Sankey later" aside, and the README sample. Driver only, so it doesn't go on the unreleased enclave list.

- **Depends on:** None.
- **Came from:** The user, 2026-10-12. Do it before 20261012-2 and 20261012-3, so their new burndown stages need no funnel work.
- **Design:** burndown, report.
- **Status:** todo

### 20261012-7. A CHECK with NOT IN on a varchar column is refused as `complex_check`.

From the review of 20261012-1. `g varchar CHECK (g NOT IN ('bad', 'worse'))` prints as `((g)::text <> ALL ((ARRAY['bad'::character varying, 'worse'::character varying])::text[]))`. `Scenarios::Checks::KINDS` (`enclave/lib/quaack/enclave/scenarios/checks.rb:21`) doesn't hold `AEXPR_OP_ALL`, so `Checks.new` raises `complex_check` and rewrite-test refuses every query whose fixtures need a row in that table (the reviewer saw `[[false, :complex_check, nil]]` end to end). `Sides.sides` already reads `<> ALL` over a cast ARRAY since 20261012-1, so accepting it should be small. DESIGN.md doesn't list NOT IN as simple today, so update its simple-CHECK sentence. Also add the specs the review found missing, for behaviour it checked by hand: a CHECK IN list holding NULL (`IN ('p', NULL)` gives values `["p"]` and, as in Postgres, rejects nothing), and a one-element IN list (which prints as `= 'only'`). Still worth doing after 20261012-4 only if the search reuses `Checks`; if it doesn't, drop this when 20261012-4 lands.

- **Depends on:** None.
- **Came from:** The review of 20261012-1, 2026-10-12 (minor).
- **Design:** fixture-scenarios.
- **Status:** todo

### 20261012-8. Value pools: an array literal under `= ANY` isn't split, and a bare `ARRAY[...]` compared with an array column is.

From the build and review of 20261012-1. Two readers of array sides in `ValuePools::Sides.sides` still get the wrong values. Check each first:
- An array literal, not `ARRAY[...]`: `CHECK (f = ANY ('{u,v}'::text[]))` gives `Checks#values` `[]` and then `unsatisfiable_check`, and a query's `s.a::text = ANY ('{x,y}'::text[])` gets a pool with nothing satisfying and `"{x,y}"` as its only literal. Postgres never prints an IN list this way, but drivers that bind a list as one array (node-postgres, Ecto, `= ANY($1)`) give queries in this shape. Split it into its elements in Postgres (`unnest`), not by parsing the text.
- A bare, uncast `ARRAY[...]` compared with `=` on an array column (`tags = ARRAY['a', 'b']`) is split into elements, so its pool comes out empty. 20261012-1 keeps the cast form whole; do the same for the bare one.
- Also from the builder: `VacuityGuard::Search::Skips#column_compared?` doesn't count `col = ANY (ARRAY[...])`, cast or not, as a column compared with constants. Drop this bullet if 20261012-4 lands first, since it removes the vacuity guard.

Unsupported in v1 instead, if any of these turns out hard: list it in DESIGN.md.

- **Depends on:** None.
- **Came from:** The build and review of 20261012-1, 2026-10-12 (minor).
- **Design:** fixture-scenarios, vacuity-guard.
- **Status:** todo

### 20261012-9. LiteralSet and CastlessIndex don't read an `ARRAY[$1, ...]` under a cast.

From the build of 20261012-1, not yet checked by a reviewer. `LiteralSet#any` (`enclave/lib/quaack/enclave/literal_set.rb:322`) reads `col = ANY (ARRAY[$1, $2])`'s elements as list placeholders, but not when the ARRAY is cast (`= ANY (ARRAY[$1, $2]::text[])`, or the cast `IN` form Postgres prints), so those placeholders fall back instead of getting worst-case and typical picks. The builder said `CastlessIndex` has a similar gap. Reproduce each with a realistic query first; for each that's real, fix it test first, and for one that isn't, say so and drop it. The picks stay in the store, so this isn't a trust-boundary issue, only weaker picks.

- **Depends on:** None.
- **Came from:** The build of 20261012-1, 2026-10-12 (minor).
- **Design:** literal-sets, index-ideas.
- **Status:** todo

### 20261012-10. llm-counterexamples counts a round where the ORIGINAL query fails as a disproof.

Found by 20261012-5's corpus work (2026-10-12) and reproduced with the real enclave code (`scratch/corpus-20261012-5/bugdemo.rb` in the main checkout). `Counterexamples.compare` (`enclave/lib/quaack/enclave/counterexamples.rb` ~109) turns any runner failure that isn't a load failure into `match: false`, and the round disproves the rewrite. Its comment assumes the candidate failed, but `ArenaRunner#run_query` raises `query_failed` for either query. So inserts that make the original fail make every rewrite look wrong, even an exactly equivalent one: `SELECT t.id, t.a / t.b FROM public.t t ORDER BY t.id` against the same query with `WHERE true` added, and a row with `b = 0`, comes out disproved with rule `query_failed`. LLMs reach for division by zero, overflow and bad casts on their own, so this drops sound rewrites on realistic data. ScenarioTests doesn't have this bug: it counts `query_failed` as a runner failure (`rewrite_test_failed`), not a disproof.

Fix it test first. A round where the original fails says nothing about the candidate: report it like a load failure (match nil, with its own rule, such as `original_failed`), so the next round runs. Keep the disproof when only the candidate fails while the original ran (that's a real difference: the rewrite errors where the original doesn't). Check which query failed from the runner's error (its step and index), not from the message text. Check `RewriteFate`, the burndown's drop reasons and `rule_bugs` for the new rule, and say in DESIGN.md's counterexamples section that an original that fails disproves nothing. Also check that the disproof search (20261012-2) and the enumeration (20261012-3), when they land, follow the same rule; the spike's code already does (it counts only a candidate data error where the original ran).

- **Depends on:** None.
- **Came from:** 20261012-5's phase 1, 2026-10-12.
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261012-11. rewrite-test crashes when the original query fails on a scenario's data.

Found by 20261012-5's corpus work (2026-10-12). On the Canvas schema, `ScenarioTests.run` raises `ArenaRunner::Error` (`query_failed`) for `SELECT s.id FROM public.submissions s JOIN public.assignments a ON a.id = s.assignment_id WHERE s.course_id = 1 AND (s.score / a.points_possible) >= 0.9`, even with no candidates. A scenario row has `points_possible = 0`, the original divides by it, and VacuityGuard re-raises any runner error that isn't a load (`vacuity_guard.rb`, `loaded_exercised_atoms` and `spill_exercised_atoms`). Nothing in the rewrite-test step (`steps/counterexamples.rb`, `run`) rescues it, so the step fails for the whole query and no rewrite of it is tested. Dividing by a column that can hold 0 is ordinary SQL, and a column's typical values include 0. (Reproduce: `scratch/corpus-20261012-5/` in the main checkout, case `cv_score_ratio`.)

Fix it test first, on a realistic query like this one. A fixture on which the original fails says nothing about a rewrite, the way a fixture that won't load says nothing: treat it like a load failure in the guard (its atoms stay vacuous and are retried) and in the scenario comparison (that scenario is skipped, not a disproof), and test the rewrite on the other scenarios. Say so in DESIGN.md where it says scenarios never crash rewrite-test. Check that 20261012-10 (counterexamples) and the disproof search (20261012-2) follow the same rule: an original that fails disproves nothing.

- **Depends on:** None.
- **Came from:** 20261012-5's phase 2, 2026-10-12.
- **Design:** rewrite-test, vacuity-guard, fixture-scenarios.
- **Status:** todo

### 20261012-12. llm-counterexamples: tell the LLM which values get an insert refused, and what each refusal means.

Found by 20261012-5's phase 2 (2026-10-12; `scratch/corpus-20261012-5/results/llm-score.md` in the main checkout). We replayed 531 replies from three models through production's InsertCheck, over up to 3 rounds with production's feedback. Many inserts were refused for values the system prompt never warns about, and the feedback doesn't say enough for the model to recover.

What we saw:
- **Operators.** `$1 || ' '`, `$2 - interval '1 day'` and `$1 * 2` are refused as `not_plain_value` (`insert_values.rb` `plain!`, `insert_check.rb` rule 10). The system prompt (`driver/lib/quaack/driver/counterexamples.rb` `SYSTEM`) says values must be "constants, casts, $n, DEFAULT, or immutable function calls on those", and models read that as allowing operators. claude-opus-5.5 had 50 such refusals and gemini-3.8-flash 24. In round 1, claude ended with nothing accepted on 42 of 99 cases.
- **`not_immutable` doesn't name the refused call.** The enclave's error detail does ("function pg_catalog.timezone is stable, not immutable"), but only the rule reaches the LLM.
  - claude and gemini kept using `jsonb_build_object` and `concat`, which are STABLE.
  - `InsertValues::MUTABLE_SQL` matches by name and argument count, not by the overload Postgres would resolve. So `timezone($1, <timestamp>)` is refused because `timezone(text, timetz)` is STABLE, even though `timezone(text, timestamp)` is IMMUTABLE. A model can't work that out from "not_immutable".
- **One refused value loses the whole statement.** It refuses the whole multi-row INSERT, so every row in it is lost.
- **Misleading feedback.** After a round where every insert was refused, the feedback still says "The accepted inserts gave both queries the same results." (`result_line`).

Most of claude's gain from round 1 to round 3 (41 to 73 of 76 wrong rewrites) came from working around these refusals, not from new ideas. gemini went from 35 to 72. gpt-6.1-sol, which seldom wrote operators, got 69 in round 1. So a clearer prompt should make round 1 much stronger, and fewer rounds means less time.

Fix it test first:
- **System prompt.**
  - Say that operators are refused, and that the way around them is an immutable function (`pg_catalog.textcat`, `int4pl`, ...) or the value written out.
  - Say that a function is refused if any of its overloads with that many arguments isn't IMMUTABLE (`timezone`, `concat`, `jsonb_build_object`), and suggest writing the value out instead.
  - Suggest one row per INSERT when a value might be refused.
- **Feedback.**
  - Give each refusal rule a fixed sentence that says what it means.
  - When nothing was accepted, say so.

Decide with the user:
- Whether the enclave should also send the refused function's name, which its error detail already holds. The name comes from the insert's own text, never a value, but it would need a protocol field and an egress check, and the change would go on the unreleased enclave list.
- Whether `MUTABLE_SQL` should resolve the overload from the argument types instead.

Re-measure with the corpus harness, which builds prompts with the driver's and the enclave's real code. Compare round-1 refusals and catches before and after.

- **Depends on:** None.
- **Came from:** 20261012-5's phase 2, 2026-10-12.
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261012-13. fuzz: value classes from world knowledge, and many copies of a row.

From 20261012-5 (the user, 2026-10-12: keep llm-counterexamples, and teach the mechanical search what only the LLM caught). On 20261012-5's hard corpus (`scratch/corpus-20261012-5/` in the main checkout; the answer key is `cases/index.json`), the spike's swarm and enumeration caught 41 of the 76 wrong rewrites in scope, and the LLM caught all 76. The 35 the search missed need values nowhere near the queries' constants, or more than 4 rows in a table.

Add to the fuzz search's value pools (20261012-2), per column type:
- **Text:**
  - the queries' string constants padded with spaces, tabs and newlines;
  - an all-spaces string and the empty string;
  - case-fold oddities: the long s (U+017F), the Kelvin sign (U+212A), dotted and dotless i;
  - a decomposed (NFD) copy of an accented constant;
  - a multibyte character;
  - a constant's case variants, so a unique index that's case-sensitive still lets them in;
  - a string holding the separator a `split_part` or LIKE pattern in the query uses, twice.
- **Numbers:**
  - NaN and ±infinity for numeric and float;
  - .5 values on both sides of 0 for rounding;
  - a negative value and 0 for a column that's divided by;
  - a value just past int4's range where a query casts to int.
- **Dates and times:**
  - ISO-week and year-end dates (Dec 29 to Jan 3);
  - Sundays, for dow against isodow;
  - the same date in two years;
  - ±infinity;
  - DST hours: the switch and summer times, in the zones the queries name or else a few common ones.
- **JSON:** each JSON type for a key the query reads: a number, the same number as a string, 10 against 10.0, JSON null, a missing key, a bare string against an array holding it, a number inside an array.
- **Arrays:** an array holding NULL; duplicates and a different order.

Add a generator that makes N rows sharing a group or a foreign key, where N is each integer constant in the queries, ±1 (a HAVING threshold, a window frame, a LIMIT or OFFSET).

Keep the trust boundary as in 20261012-2: these values stay in the enclave.

Measure with the harness on the hard corpus, 60 s per rewrite. Report:
- what the search now catches of the 35;
- any false disproof on the 23 sound rewrites in scope;
- the change in time per rewrite.

Some cases need rows that relate to each other in ways a value pool can't plan, such as days missing from a lag. Those, and classes nobody has listed, are why the LLM stage stays. Say so in DESIGN.md's counterexamples section.

- **Depends on:** 20261012-2.
- **Came from:** 20261012-5, 2026-10-12 (the user's decision).
- **Design:** rewrite-test, llm-counterexamples.
- **Status:** todo

