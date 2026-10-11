# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

- 20261010-12: `not_in_to_not_exists` refuses a NOT IN that appears again in the same SELECT when a copy is in its GROUP BY, DISTINCT ON, or ORDER BY.
- 20261008-36: the statistics read pins DateStyle to ISO, so stored date and timestamp values replay the same in any session.
- 20261010-13: a plan deeper than PlainData::MAX_DEPTH in measurement or index-build confirm is refused as plan_too_deep; the SingleCandidateTest plan parse is bounded.
- 20261010-16: the candidate check refuses calls to the oid-taking type input and recv functions of pg_catalog (`name_lookup_function`), unless the original makes the same call.
- 20261011-3: the `name_lookup_function` message for oid-taking type input functions is reworded.
- 20261010-17: qualify refuses (`unknown_relation`) when a scanned relation is missing from its tablespace query.
- 20261010-47: fixture loads count 3 per comparison and skip the guard's LIMIT comparisons; pinned own keys avoid pooled values.
- 20261010-43: vacuity-guard search for a distinguishing database; `untested_states` (`searched`/`not_searched`) in `rewrite_tested`, the report payload and the driver report.

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

### 20261008-41. Candidate name lockdown: keyword operators and the failure for a pinned name. Done, see BACKLOG-COMPLETE.md.

### 20261008-44. Qualifying overloaded names: keyword forms (part 2 of 20261007-21).

Split from 20261007-21. IN, BETWEEN and NOT BETWEEN, LIKE and ILIKE, IS DISTINCT FROM, NULLIF, simple CASE, and USING and NATURAL joins have no qualified spelling. When several schemas on the path define the operator they use, rewrite each one into an equivalent explicit form that can be qualified, or refuse it cleanly, and list it as unsupported in v1. This also covers item 1 of 20261008-41 (keyword operators LIKE, IN, IS DISTINCT FROM, NULLIF resolving through the search path).

- **Depends on:** 20261007-21.
- **Came from:** The split of 20261007-21, 2026-10-08.
- **Design:** qualify.
- **Status:** todo

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

### 20261009-2. Have the enclave send its parser major for `query_unparsable`.

Carried from 20260927-28. `EnclaveError#unparsable` builds the note from the driver's own pg_query, so if the two sides' pg_query differ, the note names the wrong grammar. The fix touches all three gems: a new field in the protocol whitelist's error-line fields; `ErrorFilter` emitting it only for `query_unparsable`, as a small integer (raised in `intake/query.rb` and the qualifier's `Unparsable`); and the driver reading it. It adds a value to enclave output, so test it with sentinels. Both sides install from one lockfile, so this only matters if they drift.

- **Depends on:** 20260927-28.
- **Came from:** The build of 20260927-28, 2026-10-08.
- **Design:** none.
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

### 20261010-10. Index sources: a faithful store fake, and a mixed-label cell.

From the review of 20261004-89 (minor).
- The store fake in `enclave/spec/outbound_ddl_spec.rb` has an `entry?` that always returns false, so `IndexSources.sources` finds no searches and every entry's sources are `[]` in that spec. Harmless there (the sources path is covered against a real store in `report_payload_step_spec.rb`), but make the fake faithful (`def entry?(name) = data.key?(name)`).
- If a label mixes indexes with recorded sources and indexes without, the cell lists only the recorded sources and doesn't say some are unrecorded. Only a payload no single enclave version produces does this, so it's cosmetic; say "and others not recorded" or leave it.

- **Depends on:** 20261004-89.
- **Came from:** The review of 20261004-89, 2026-10-10 (minor).
- **Design:** report.
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

### 20261010-45. Burndown: a Sankey diagram beside the funnel, for side-by-side comparison.

The user, 2026-10-10. The burndown funnel (driver/lib/quaack/driver/report/funnel.rb) tracks several things at once: items that enter at several stages (index ideas from the query text and the plan, then the LLM; rewrites from transform rules, the LLM, and the user's own), items that leave for different reasons, and units that change (ideas, then combinations of indexes, then rewrite-plus-index-set candidates). It strains to show that (the "added" slice was the patch, and "Trying indexes together" mixes combinations with ideas; see 20261010-44 item 1). The user may replace the funnel with a Sankey diagram and wants to compare them first: **keep the current funnel and add the Sankey in the same report, side by side or one under the other within each burndown subsection, labelled so it is clear they show the same data.** The user will decide afterwards; removing the funnel is a separate later task.

Build it from the data the report already has (no enclave or protocol change is expected: each stage record has `in`, `added` by source, `dropped` by reason, `set_aside`, `out`, and `extra`; check that this is enough, and if not, say what is missing): one column per stage; the flow that carries from a stage's `out` to the next stage's `in` as a ribbon; each source in `added` entering the stage where it arrives as its own named input (query text, plan, LLM, your own rewrites, transform rules) so nothing appears to widen out of nowhere; each drop reason as its own labelled sink; `set_aside` ("held back for a real build") as its own sink. Keep units apart: draw a separate diagram for each unit (index ideas; rewrites; combinations and candidates at the end), each with a one-line caption naming its unit, so widths in one diagram are always comparable.

Rendering: inline SVG generated in Ruby, like the funnel (no JavaScript or external library; the report is self-contained and the contrast and dark-theme specs apply: colors as variables with dark values; links and text readable). Write a small layout (columns by stage, nodes stacked in order with a minimum height so a count of 1 is still visible, ribbons as cubic paths, labels outside the nodes, collision-free for the real stage counts, for zero counts, and for large counts), keep the existing table under each diagram as the accessible exact numbers, and give each ribbon and node a tooltip that says only the stage's sentence and its numbers (as the user asked for the funnel). Decide with a screenshot: render a synthetic burndown with the real stage set (the 6/8/9/4 and 2/6/7 flows from 20261010-20's screenshots and one with a skipped refine and one with no LLM rewrites) in headless Firefox in both themes and show the user; ask nothing else until they have seen it. Test first in driver/spec/report_spec.rb (structure, node and ribbon counts equal the stage records, flows conserve: a node's inputs equal its outputs, units kept apart, both diagrams present), mutate, update DESIGN.md and the README sample.

- **Depends on:** 20261010-20 (landed). Not started: the user asked that no new items be picked up until their next run; they have not said whether this goes before the version bump.
- **Came from:** The user, 2026-10-10.
- **Design:** report, burndown.
- **Decided by the user (2026-10-11):** the Sankey goes in before the next version bump. Start now.
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

### 20261010-50. Vacuity-guard search: the wall clock decides the state word.

From the review of 20261010-43 (minor). `VacuityGuard::Search` stops after `SECONDS = 5` per query, and every atom left then reads `not_searched`. The same query can report `searched` on one machine or load and `not_searched` on another, and which atoms close can differ. No literal value leaks, but the task asked for a search that is reproducible from its seed. Make the trial count the only budget (and size it so a query stays within a few seconds), or keep the clock only as a hard abort that refuses the search instead of changing a word. Test first: the same seed and query give the same states under a slow runner.

- **Depends on:** 20261010-43 (landed).
- **Came from:** The review of 20261010-43, 2026-10-10.
- **Design:** rewrite-test, scenarios.
- **Decided by the user (2026-10-11):** count attempts, not the clock: the trial count is the only budget. Also warn in `quaack` output when the search (or its requests) is taking a long time; the warning may carry only a duration or a fixed word, nothing from the data. Do it after 20261010-47 lands (same files).
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

### 20261010-53. rewrite-test ran a whole hour on one rewrite and killed the run.

The user's run 20261011T031856Z-b92bbf95 (2026-10-10, main at 75cd879e) failed at step 9 of 18 (`rewrite-test`): one rewrite took 4 s, the next took 1h00m04s and hit the driver's 3600 s step cap (`Transport::Base::DEFAULT_TIMEOUT`), which failed the whole run. Nothing bounds one rewrite's test except the 10 s statement timeout per statement. Two parts: (1) find why that rewrite was slow (needs the user's profile: rerun the step by hand with `QUAACKS_PROFILE`, README "profile it on the jump server"; same data 20261004-27 item 1 waits for); (2) give rewrite-test a wall-clock budget per rewrite, so a rewrite that can't be tested in time is reported as "could not be tested" and dropped, not fatal. Part 2 is a design change: confirm with the user (budget size, wording in the report) before building.

- **Depends on:** the user's profile for part 1; the user's go-ahead for part 2.
- **Came from:** The user's run, 2026-10-10.
- **Design:** rewrite-test, Where QUAACK runs.
- **Decided by the user (2026-10-11):** the budget is 5 minutes per rewrite. The user will profile part 1. The version bump waits until rewrite-test's performance is fixed.
- **Profile (user, 2026-10-11, quaacks 0.1.32, ran 51,667 samples before the user interrupted it):** about 92% of the samples are in `Scenarios::RowSet` (`row_set.rb:48` `add?` through `parts.rb:46-47` and `scenarios.rb:282`), under `vacuity_guard.rb:56-57` and `scenario_tests.rb:70`, reached from `steps/counterexamples.rb`. Self time sits in `row_set.rb:121` (`values`, 12.5k), `:84` and `:67` (the `parent` find and `include?`, 11k and 9k), `:92` (`clash?` scan, 4.6k) and `parts.rb:46` (2.5k): the linear scans of 20261004-27 item 2. Part 1 is answered; the fix is 20261011-4. Part 2 (the budget) still stands.
- **Status:** todo (needs the user)

### 20261011-2. Count thresholds and small LIMIT/OFFSET still show in the report (found in the review of 20261010-47).

The review of 20261010-47 grouped outgoing reports by literal value over 0..10 and found classes that differ: LIMIT {0} {1..10}; ORDER BY LIMIT {0} {1} {2..10}; OFFSET {0} {1} {2..10}; `count(*) > n` {0} {1} {2} {3} {4..10}; `HAVING count() > n` {0} {1} {2..10}; IN list with `count(*) >= n` {0} {1} {2} {3..10}. The differing fields are loads (7/10/16/25 for `count(*) > 0..3`), retries, the untested set, `untested_states` and results (row_count vs pass). It saturates by 4, nothing scales without bound. LIMIT and OFFSET (0, 1, 2+) are a coarse shape fact. **Count thresholds are not**: an observer recovers the exact n for n = 0..3 from `loads` or the untested set, and small thresholds are the common case. This was already so on main before 20261010-47 (the diff only fixed LIMIT and IN-list values). DESIGN says literal values never cross.
Do: (1) make the fields that depend on a count threshold's value independent of it (bucket, report a fixed value, or compute from shape only; the result classes above are what the guard truly finds, so the likely route is to report, for a query with a count compared to a constant, the same untested set, states, loads and retries for every threshold, for example by treating those atoms as unproven and not counting loads for them), without weakening the guard's honesty; (2) extend `across_literals_postgres_spec.rb` so it passes for thresholds 0..10 and every operator, and add a family that straddles the old 3-row load step (the standing guard doesn't catch a revert of `counted_as` today); (3) fix the DESIGN.md sentence 20261010-47 added so it doesn't imply full independence for thresholds until this lands. Do 20261010-48's work after this (48 needs the spec to pass for thresholds 0..9). Security/Privacy-relevant boundary check: Opus builder and reviewer. Enclave change: unreleased list.

- **Depends on:** 20261010-47 (landed).
- **Came from:** The review of 20261010-47, 2026-10-11. Priority: trust boundary.
- **Design:** What goes into the enclave; the burndown.
- **Status:** todo

### 20261011-4. `Scenarios::RowSet`: replace the linear scans with hash indexes (the hour-long step).

From the user's profile of the slow step (see 20261010-53) and 20261004-27 item 2. `RowSet#add?` checks each new row against every row already in its table, and recomputes keys each time: `@rows[r.table].include?(r)` (deep row compare), `clash?` (`@rows[...].any? { yield(other) == key }`, which recomputes `values(other, columns)` and `columns.index(c)` for every row on every check), `parent` (`@rows[key.parent].find { values(...) == wanted }`), `outside_parents`/`parents_of` (`rows.any?`, `found.include?`, `rows.include?`) and `orphan?`. With many rows per table that is quadratic or worse, and `Parts#add` and the retries call it for every group in every fixture (`parts.rb:46-47`, `retries.rb`). About 92% of the profile's 51,667 samples were in it. Fix it with indexes that keep every result identical: a set of rows per table (Row needs `hash`/`eql?` by table and values), per table and unique column list a hash of key to row (for `clash?`, with the NULLS NOT DISTINCT rule and the `:error` key handled as now), per table and foreign-key parent columns a hash of key to row (for `parent`/`orphan?`), and a precomputed column-index map for `values`. Keep the delete in `add?`'s rollback (remove from every index). Test first: a spec that builds a RowSet with a few thousand rows over a table with a unique key, a composite unique key, an expression index and a foreign key, and asserts the work is near linear by counting calls (for example the number of `values`/`evaluate` computations is below a bound that grows linearly, not quadratically; wall-clock bounds are flaky), red against today's code; plus a behavior-equality spec that runs the same adds on the old algorithm (kept in the spec as a slow reference) and the new one over random small cases and compares what `add?`, `add_any?`, `parents_of` and `in_order` return and leave. The across-literals spec (`across_literals_postgres_spec.rb`) and the corpus must stay green, byte for byte. Mutate (drop a delete from an index, key a NULL as equal, ignore `nulls_not_distinct`) and confirm red. Then run the user's kind of query again: the step should be seconds, not an hour; say what a 19-table fixture measures before and after (20261004-23 measured about 3 s).

- **Depends on:** 20261004-23, 20261010-53 (profile).
- **Came from:** The user's profile, 2026-10-11. Priority: the version bump waits for it.
- **Design:** rewrite-test, scenarios.
- **Status:** todo
