# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

- 20261011-7
- 20261011-11
- 20261012-8
- 20261012-9
- 20261012-12
- 20261012-17
- 20261012-31
- 20261012-42
- 20261012-46
- 20261012-50
- 20261018-32
- 20261021-5
- 20261015-5
- 20261110-16


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

## Trust boundary.

## Input.

## Production inventory.

## Schema, statistics, and classification.

## Run server.

## Added later.

### 20260923-1. Postgres 17 parser under Postgres 18. Done, see BACKLOG-COMPLETE.md.

### 20260923-30. Predicate atom loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-7. fixture-compare comparator loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-25. redact loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20261001-19. Record the rewrite stages in the burndown. Done, see BACKLOG-COMPLETE.md.

### 20261002-1. Rule generator: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261002-2. Running the rules: minor findings. Done, see BACKLOG-COMPLETE.md.

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


### 20260927-28. Parser note loose ends, and the Postgres 18 upgrade. Done, see BACKLOG-COMPLETE.md.

### 20261003-3. Report payload: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261003-39. rewrite-test: more variety in self-references and repeated parents. Done, see BACKLOG-COMPLETE.md.

### 20261004-94. Result comparison: loose ends of the edge check. Done, see BACKLOG-COMPLETE.md.

### 20261007-21. Qualify functions and operators that several schemas define (full version of 20260926-56's qualification). Done, see BACKLOG-COMPLETE.md.

### 20261008-41. Candidate name lockdown: keyword operators and the failure for a pinned name. Done, see BACKLOG-COMPLETE.md.

### 20261008-50. Orphan index-build notes: advice that's moot after teardown. Done, see BACKLOG-COMPLETE.md.

### 20261008-53. redact: the rest of 20260924-25. Done, see BACKLOG-COMPLETE.md.

### 20261008-55. Foreign cancels: minors from 20260929-29. Done, see BACKLOG-COMPLETE.md.

### 20261008-57. Running the rules: leftovers from 20261002-2. Done, see BACKLOG-COMPLETE.md.

### 20261009-1. Upgrade pg_query to a Postgres 18 parser, and drop the parser note.

Carried from 20260927-28. As of 2026-10-08 the lockfile has pg_query 6.2.3 and the newest release is 6.2.5, both on the Postgres 17 grammar. When a release ships a Postgres 18 parser, upgrade it, drop the parser note (20260923-1), and update `parser_version_spec.rb`'s literal 17.

- **Depends on:** a pg_query release with a Postgres 18 parser.
- **Came from:** 20260927-28.
- **Design:** none.
- **Status:** blocked

### 20261009-32. Report: reword the fate of a rewrite that regressed, and drop its correctness caution. Done, see BACKLOG-COMPLETE.md.

### 20261009-33. Ranked rewrites carry the "unproven" caution: find out why, and fix the cause.

The user, 2026-10-09, from their own report (`quaack-20261009T212424Z-7f4c43c1.html` in the repo root, untracked; it's a real report with production schema and table names, so never commit it, quote it in a fixture, or send it anywhere; reproduce with synthetic data). Every rewrite in it, including the ranked ones (Steady Lute, Tidy Trout, Plucky Spoon), says "Read it with care: every test QUAACK ran passed, but the test data never exercised some of its conditions, so those parts are unproven." The user reads that as "QUAACK didn't logically test it", which is a problem when it sits on the query QUAACK recommends. The run's burndown says why it shows: rewrite-test's vacuity-guard counted 132 conditions the test data never exercised (after 396 retries), and the LLM's data exercised 85 of them. The conditions left (about 47, if those counts are what the caution counts) mark every rewrite, because `Report::Cautions#warning` adds the caution whenever `unchecked_atoms(entry)` is non-empty. The query is a large one: an OR of ANDs over `assignments` and `submissions`, with `IN` lists and a `UNION ALL` subquery. Long `IN` lists aren't suspected: the user's own queries have lists of hundreds of items, and the untested list below holds simple conditions too.

Work out which of these is true, and fix it:
1. **Which atoms are left, and why.** From the run's store (ask the user for the run ID and for the shapes of the untested atoms; the report doesn't list them), say which atoms stay untested, and why the search can't exercise them (vacuity-guard, until 20261012-4): an OR branch that can't be reached with a loadable row, a condition that the unique keys or the foreign-key cut rule out, or a bug.
2. **Whether an untested atom makes the rewrite unproven at all.** If the atom sits in a part of the query the rewrite left exactly as the original had it, no test could tell the two apart there, so the caution says nothing about the rewrite. Consider warning only when an untested atom lies in a part the rewrite changed. This needs a check against DESIGN.md's counterexamples and result-comparison design: is the caution meant to be about the whole query, or only the rewrite's difference?
3. **Whether to raise coverage** (more variety in fuzz's worlds for the atoms found in 1).
4. **Wording**, if the caution stays: it must not read as "no logical testing" (see 20261009-32, which rewords the not-better case; do these two together, or keep the wording the same in both).

Take the decision between 2 and 3 to the user before building, with the finding from step 1.

**Finding from the user's run (2026-10-09, from `quaacks counterexample-payload` for rewrite_1 to rewrite_7; the shapes hold no values):** rewrite_1 has no untested atoms (it's the rewrite planned the same as the original, so it's never tested). Each of rewrite_2 to rewrite_7 lists the same atoms, in the same order: about two dozen, and they're the original query's whole predicate set. They include the join key (`submissions.assignment_id = assignments.id`), every `IN` list, the `type`, `workflow_state` and `context_type` comparisons, `muted IS NULL`, the user filter, the date range, and one atom for the whole `assignments.id IN (SELECT ... UNION ALL SELECT ...)` subquery. 132 untested in all is that list's length times the 6 tested rewrites. So the caution isn't about anything a rewrite changed. It says that rewrite-test's fixtures exercised almost none of the original's conditions at all. Under ScenarioTests, the likely cause was that scenarios didn't load or didn't reach the query's rows, not that the rewrites differ in untested ways. Step 1 should reproduce the new run's result on a synthetic schema of the same shape (two tables joined on a key, an OR of ANDs, an `IN` list, a `UNION ALL` subquery under an `IN`) and find where the atoms stay untested under fuzz's coverage. The user's run store is on the jump server; if the builder needs more from it (the run's rewrite-test results), ask the user for a redacted copy.

- **Depends on:** None. Related: 20261009-32, 20261009-18, 20261003-39.
- **Came from:** The user, 2026-10-09.
- **Design:** rewrite-test (coverage), counterexamples, report.
- **Decided by the user (2026-10-09):** the caution should warn only about untested atoms in the part the rewrite changed. That's task 20261009-40. This task builds the diagnostic (why an atom stayed vacuous) first; the cause of the untested atoms in the user's run is still unknown and waits on that diagnostic.
- **Landed so far:** 2026-10-09 (task/20261009-33): a diagnostic (`s1_load_rule` and `s1_rows` on each tested rewrite's `rewrite_test` message) to tell whether S1 failed to load or loaded and returned nothing. The caution's scope is 20261009-40. Minor finding: 20261009-46.
- **Trimmed 2026-10-14 after 20261012-4:** 20261012-4 removed ScenarioTests, the vacuity guard and that diagnostic (`s1_load_rule`, `s1_rows`, `VacuityDiagnostic`), so the vacuity guard can't be the cause any more, and "a run with the diagnostic" can't happen. What's left: once the user runs 0.1.35 on the real schema, check whether its ranked rewrites still show every atom untested under fuzz's coverage (`Fuzz::Coverage`). `Fuzz::Reach`'s worst case (a count threshold or a volatile function) or a cut copy that won't deparse (`Fuzz::Uncut`) would do that. If they do, find the cause and fix it, as in steps 1 to 4 above, with coverage in place of the vacuity guard.
- **Status:** todo (waits on the user's next real-schema run)

### 20261010-39. Untested conditions: CTE, scalar subquery, second column tie, and shapes found while building 20261010-33/34. Dropped, see BACKLOG-COMPLETE.md.

### 20261010-46. Untested conditions: a count threshold with other conditions (`count(...) > 2 AND title = 'x' AND score > 3`). Dropped, see BACKLOG-COMPLETE.md.

### 20261010-47. Trust boundary: fuzz's trials, enumerate's worlds and bound can follow query literals through per-trial cost.

Reported counts must not depend on literal values (DESIGN: shapes, counts and fixed names cross, never values). The counts the search sends out are fuzz's `trials`, enumerate's `worlds` and its `bound` (`protocol/lib/quaack/protocol/fuzz_result.rb`; `steps/rewrite_fuzz.rb` puts them on the `rewrite_test` message), and the burndown's fuzz and enumerate records. `enclave/spec/across_literals_postgres_spec.rb` deliberately doesn't hold the trial count to its byte-identical check (its comment, ~lines 27–29: it follows how long each trial takes, under the real stop rule), and nothing else does. Under the time-based stop rule (`Fuzz::StopRule`: a 30 s floor, twice the last new signature, a 60 s cap) and enumerate's 30 s limit, these counts follow per-trial cost, which can shift with a literal: a larger LIMIT or OFFSET returns more rows per trial, and an IN list's values can change which worlds get drawn and so how much each costs. Find out how much a count can move with only a literal changed (LIMIT, OFFSET, IN-list values, BETWEEN bounds, count thresholds) on realistic queries, and whether that's more than noise. Then decide with the user whether to bucket the counts, report them in a coarser unit, or accept and document the timing channel in DESIGN.md, and extend the across-literals spec for whatever is decided. This is a Security/Privacy-relevant boundary check; have an Opus reviewer.

Trimmed 2026-10-14 after 20261012-4: removed the findings about ScenarioTests' `fixture_loads` following the LIMIT, `dropped` and the spills following IN-list values, `distinct_loads`' part in the scenario loads, and the "also cover the vacuity-guard search's untested set and `untested_states`" item. 20261012-4 removed all of them, and rebuilt the across-literals spec for fuzz's verdict, rule and coverage. 20261011-2, which carried the rest, is done.

- **Depends on:** None.
- **Came from:** The second review of 20261010-35, 2026-10-10. Priority: trust boundary.
- **Design:** What goes into the enclave; the burndown; rewrite-test.
- **Landed so far:** 2026-10-11 (task/20261010-47): the first `across_literals_postgres_spec.rb`, for ScenarioTests' reports (since replaced by 20261012-4's version for fuzz).
- **Status:** todo

### 20261010-48. Untested conditions: a correlated count threshold, built without leaking the threshold. Dropped, see BACKLOG-COMPLETE.md.

### 20261010-52. `not_in_to_not_exists` repeat check: scope and spelling. Done, see BACKLOG-COMPLETE.md.

### 20261011-5. Denormalized fixture: a UNIQUE or CHECK on the copy column (minors from 20261010-2).

The review of 20261010-2 found: if the copy column has a UNIQUE (or exclusion) constraint, update 3 gives every parentless row the same class-parent id, and update 2 can repeat ids too, so the load fails where the old single update loaded. A CHECK on the copy column that another class's parent id violates fails the load the same way. Since 20261012-4, `DenormalizedFixture`'s UPDATEs run in fuzz's worlds (`fuzz/session/loader.rb`, `fuzz/lift.rb`), so such a world fails to load and fuzz treats it as illegal: fewer worlds get tested on that table, not a false disproof. A unique denormalized copy such as `course_id` isn't realistic, so both are minor. Possible fix: skip updates 2 and 3, or limit update 3 to one row, when the copy column has a unique index; with a CHECK, skip them too. Postgres-backed tests for each, red first.

Reworded 2026-10-14 after 20261012-4: from scenario fixtures to fuzz's worlds.

- **Depends on:** 20261010-2 (landed).
- **Came from:** The review of 20261010-2, 2026-10-11 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261011-7. A count threshold makes every atom of the query untested; keep the atoms outside the aggregate's scope. Done, see BACKLOG-COMPLETE.md.

### 20261011-8. report_spec: `html` and `ranking` are memoized lets, so a second render after changing the payload is stale. Done, see BACKLOG-COMPLETE.md.

### 20261011-10. Rewrite budget: minors from 20261010-53. Done, see BACKLOG-COMPLETE.md.

### 20261011-11. Rewrite dedupe: normalize the stated assumptions, and say what happens to the same SQL with different assumptions. Done, see BACKLOG-COMPLETE.md.

### 20261012-1. A CHECK's IN list on a varchar column reads as one array literal. Done, see BACKLOG-COMPLETE.md.

### 20261012-3. rewrite-test: a bounded enumeration pass after the random search, and what a pass says. Done, see BACKLOG-COMPLETE.md.

### 20261012-4. rewrite-test: replace ScenarioTests with the disproof search. Done, see BACKLOG-COMPLETE.md.

### 20261012-5. Measure what the LLM counterexamples catch that the mechanical search and enumeration don't. Done, see BACKLOG-COMPLETE.md.

### 20261012-6. Report: remove the burndown funnels; the Sankey diagrams replace them. Done, see BACKLOG-COMPLETE.md.

### 20261012-8. Value pools: an array literal under `= ANY` isn't split, and a bare `ARRAY[...]` compared with an array column is. Done, see BACKLOG-COMPLETE.md.

### 20261012-9. LiteralSet and CastlessIndex don't read an `ARRAY[$1, ...]` under a cast. Done, see BACKLOG-COMPLETE.md.

### 20261012-10. llm-counterexamples counts a round where the ORIGINAL query fails as a disproof. Done, see BACKLOG-COMPLETE.md.

### 20261012-11. rewrite-test crashes when the original query fails on a scenario's data. Done, see BACKLOG-COMPLETE.md.

### 20261012-12. llm-counterexamples: tell the LLM which values get an insert refused, and what each refusal means. Done, see BACKLOG-COMPLETE.md.

### 20261012-13. fuzz: value classes from world knowledge, and many copies of a row. Done, see BACKLOG-COMPLETE.md.

### 20261012-14. Report: minors from the reviews of 20261012-6. Done, see BACKLOG-COMPLETE.md.

### 20261012-16. ResultComparison disproves a rewrite that only adds a tiebreak to its ORDER BY. Done, see BACKLOG-COMPLETE.md.

### 20261012-17. Regrouped: minors from the review of 20261012-16. Done, see BACKLOG-COMPLETE.md.

### 20261012-19. counterexamples' `original_failed` rerun: two untested branches, and the CutTies run it skips. Done, see BACKLOG-COMPLETE.md.

### 20261012-20. TestPostgres's PgBouncer specs flake with "Connection refused" on the published port under load. Done, see BACKLOG-COMPLETE.md.

### 20261012-21. report-payload: the `original_failed` "isn't a rule bug" check was green before 20261012-11.

From the build and review of 20261012-11 (minor). The `original_failed` case in report-payload's "isn't a rule bug" list (`enclave/spec/report_payload_step_spec.rb`, ~lines 1155–1162) passed before 20261012-11 too, so it guards the rule without testing that task's change. Check whether a mutant (make `original_failed` a rule bug) turns it red. If one doesn't, make it a real test or drop it.

Trimmed 2026-10-14 after 20261012-4: removed the bullets about ScenarioTests' rerun after a load failure, `VacuityGuard::Compared#compare` swallowing a foreign cancel, `ScenarioTests#shows?`'s error handling, and `pipeline_progress_spec.rb`'s `original_failed` message with scenario `"s3"`. 20261012-4 removed the first three's code, and the driver spec no longer sends that message.

- **Depends on:** None.
- **Came from:** The build and review of 20261012-11, 2026-10-12.
- **Design:** report.
- **Proposed drop (2026-11-14, waiting on the user):** the builder found this stale. Making `original_failed` a rule bug in `RuleBugs.disproved_by` turns exactly two examples red (the `original_failed` entries in the `%w[... original_failed]` loop in `report_payload_step_spec.rb`, ~line 1412: the rewrite-test scenario and the counterexample-compare round, each asserting `rule_bugs == []`), so they aren't vacuous any more and fail for the right reason.
- **Status:** todo (proposed drop; don't build)### 20261012-24. fuzz copies: test that each table the copies' foreign keys point to gets a row. Done, see BACKLOG-COMPLETE.md.

### 20261012-25. fuzz: the trial rate fell 25–40% on ORM-shaped queries after 20261012-13. Done, see BACKLOG-COMPLETE.md.

### 20261012-29. The recorded pipeline replays never run enumerate. Done, see BACKLOG-COMPLETE.md.

### 20261012-30. enumerate: a primary key the queries read gets only a few key classes. Done, see BACKLOG-COMPLETE.md.

### 20261012-31. enumerate's pass sentence at w = 1. Done, see BACKLOG-COMPLETE.md.

### 20261012-35. fuzz's stop rule rarely stops before the 5-minute deadline, and starves enumerate. Done, see BACKLOG-COMPLETE.md.

### 20261012-40. Enumerate's value classes: generated columns, the key fallback, and two stale comments. Done, see BACKLOG-COMPLETE.md.

### 20261012-42. fuzz's RangeTables: a TABLESAMPLE hides the table's alias. Done, see BACKLOG-COMPLETE.md.

### 20261012-46. enumerate: a key compared with a constant lowers the bound on keyset pages. Done, see BACKLOG-COMPLETE.md.

### 20261012-48. fuzz's 60 s cap: say "about 90 seconds", and watch the slowest kill's margin.

From the review of 20261012-35, 2026-10-14 (minor).
1. **"At most 90 seconds" is a soft bound.** DESIGN.md's Stop rule bullet and `Fuzz::StopRule`'s comment (`enclave/lib/quaack/enclave/fuzz/stop_rule.rb`) say fuzz plus enumerate takes at most 90 s per sound rewrite. Three things can run past it: the trial in progress when the cap fires; shrinking and lifting a kill found just before the cap (up to `SHRINKS` = 200 trials, `fuzz.rb`), whose lift then fails; and building enumerate's kinds, which happens before its 30 s `Limit` starts (`Fuzz::Search#enumerate`). The rewrite's 5-minute Deadline still bounds all three. Say "about 90 seconds", and name what can run over, wording only.
2. **The slowest kill's margin.** The slowest kill in any corpus, `cv_topics_nulls_last`, comes at trial 8,227: 25–28 s with four measurement shards running, about half the cap. A jump server about twice as slow would lose it. The user chose the plain 60 s cap (20261012-35's option 1) knowing this; option 3 there (a 10,000-trial floor up to the cap) is the fix if the user's real-schema run shows trial rates that low. Check the rates in that run's burndown (`fuzz` trials and times) and ask the user before changing the rule.

- **Depends on:** None.
- **Came from:** The review of 20261012-35, 2026-10-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-50. Fuzz coverage: check more worlds now that a check is one statement, and a literal 0. Done, see BACKLOG-COMPLETE.md.

### 20261012-52. After 20261012-4: the builder's flags.

From the build of 20261012-4. Check each first; drop any that isn't real:
- A rewrite the search couldn't test goes on with no untested atoms, so llm-counterexamples gets nothing to aim at for it. Decide whether it should send every atom as untested (it was never tested), and whether that changes any prompt (prompt drift in the replays).
- A cancel QUAACK didn't send, during a coverage check (`Fuzz::Differ`), isn't told apart from QUAACK's own: check it ends the step with `statement_canceled`, as one in fuzz's trials does, with a Postgres test.
- The `fk_cycle` wrong-rewrite corpus went with ScenarioTests' specs. Re-create a few of its wrong rewrites (FK cycles, a nullable cycle edge) as fuzz regression specs, so fuzz is shown to catch them.
- Fuzz alone, even at 962 trials, misses the polymorphic `$2 + 1` twin and the unhonoured copies; enumerate catches them, so `polymorphic_key_copy_step_postgres_spec.rb` now runs with enumerate on. Note this in DESIGN.md's fuzz section if it isn't there.

- **Depends on:** None.
- **Came from:** The build of 20261012-4, 2026-10-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261015-1. TestPostgres.extra_server: a failed cleanup masks the readiness error. Done, see BACKLOG-COMPLETE.md.

### 20261015-4. Result-comparison on the racetrack doesn't check inner cuts or picks.

From the build of 20261008-67. `ProductionComparison` (result-comparison on production data) runs neither `InnerCuts` (a LIMIT or OFFSET below the top level) nor `Picks` (a DISTINCT ON without a full order, an aggregate that follows its input order, a DISTINCT or set operation that keeps one of several equal values), which fixture-compare now has. A candidate whose inner pick goes another way can match there by luck, and a good one can fail against an original whose own pick decides its answer. Decide whether production gets the same checks (each forced run re-reads production rows, so it costs a full query run per direction), and test first.

- **Depends on:** None.
- **Came from:** The build of 20261008-67, 2026-10-15.
- **Design:** result comparison, fixture-compare.
- **Status:** todo

### 20261015-5. Fixture-compare: window functions over tied rows pick arbitrarily. Done, see BACKLOG-COMPLETE.md.

### 20261016-17. Spec flake: the trigger-refuses-every-row fuzz example gets `no_world` under load.

From the build of 20261016-14. In one per-commit run, `enclave/spec/counterexample_steps_postgres_spec.rb`'s "passes, cautioning every atom, when a trigger refuses every row, without the database's message" got `"rule" => "no_world"` with `"trials" => 0, "worlds" => 0` instead of `"rule" => nil`, while all four suites ran at once. It passed on its own four times in a row, and the build didn't touch fuzz or rewrite-test. It looks like the search's time budget running out before it tries the empty world when the machine is busy. Find why a loaded machine can end the search with no world tried, and make the example (or the search's floor) independent of machine speed, as `QUAACKS_FUZZ_TRIALS` is meant to.

Builder check 2026-11-15: the stated cause is ruled out. The example runs with `QUAACKS_FUZZ_TRIALS=40`, where `StopRule` counts trials and never reads a clock, and the worlds are seeded from the queries' text, so two runs gave the same 40 trials, five of them empty worlds that compare. 16 busy-loop processes didn't reproduce it. A `no_world` with 0 trials means all five empty-world trials raised a `PG::Error` (load or query), likely a server-side wait hitting the 10 s `statement_timeout` on a crowded Docker host, or state left by an earlier example. Proposed: drop this task, or narrow it to recording each failed trial's `PG::Error` class or SQLSTATE inside the enclave (never printed) during a full per-commit run to see what fails. Waiting on the user to choose.

- **Depends on:** None.
- **Came from:** Build of 20261016-14, 2026-10-16.
- **Design:** rewrite-test.
- **Status:** todo

### 20261018-32. index-build: build indices that differ only in spelling once. Done, see BACKLOG-COMPLETE.md.

### 20261019-3. redact-rewrite: turn a query with real literals into a `--rewrites` rewrite. Done, see BACKLOG-COMPLETE.md.

### 20261020-2. redact-rewrite: resolve a column reached through a CTE's name.

Split from 20261019-4. A rewrite that moves a predicate into a CTE and filters it from outside (`WITH x AS (SELECT * FROM orders WHERE status = 'a') SELECT * FROM x WHERE x.user_id = 5`) names the column through the CTE, `x.user_id`. The matcher resolves `x` as a table called `x`, so it finds no comparison in the original (`orders.user_id`) and refuses `redact_rewrite_no_match`. Take a CTE name map from the enclosing WITH clauses, and resolve a CTE that selects `*` or the column straight from one table to that table. Anything it can't resolve stays a clean refusal. Enclave change; it goes on "Unreleased enclave changes".

- **Depends on:** 20261019-3.
- **Came from:** The builder of 20261019-4, 2026-10-20.
- **Design:** Operator rewrites (`--rewrites`), redact-rewrite.
- **Open questions:** None.
- **Status:** todo

### 20261020-3. redact-rewrite: `internal_error` on the user's real run.

From the user's run on 2026-10-20, after redeploying with 20261019-4 on the jump server: `quaack redact-rewrite failed: internal_error (step redact-rewrite)`. The same synthetic query (the user's query, with made-up numbers) goes through `RewriteRedaction.redact` in a unit test with an original from `Redaction.query` and gives the right placeholders, so the failure comes from something the real run's store holds that the unit tests don't: what `quaacks redact`, `clock-anchor`, and `literals` leave in `redacted_query` and `placeholder_map` (clock-anchored date range, placeholders shared between expressions, a `placeholder_map` with entries a unit test doesn't build), or from the whole step path (the dispatcher, the egress whitelist, the driver call). Reproduce it end to end: run the real steps in order (`redact`, then whatever the pipeline runs before rewrites, through the installed `quaacks`, outside Bundler as the other step specs do) on a synthetic copy of the user's query (an `assignments` and `submissions` join with `workflow_state <> 'deleted'` in the ON and `!= 'deleted'` in the WHERE, a date range `cached_due_date BETWEEN '2026-03-16 00:00:00' AND '2036-09-16 07:00:00'`, a 21-literal `IN` list, an `EXISTS (SELECT 1 ...)`, and an `OR assignments.id IN (...)` of 12), then `quaacks redact-rewrite` with the same text. Find the exception, fix it test first (a test that fails with that exception today), and make the failure diagnosable: an exception the step can't classify should still end as `internal_error`, but a bug like this one must not hide behind it. If the enclave keeps a local log of internal errors on the jump server (check the store and ErrorFilter), say where, so the user can read the cause; if it doesn't, propose the smallest safe way (the exception class name and the file and line of the raise, never a message that could hold a value) as a new task rather than building it. Enclave change; it goes on "Unreleased enclave changes".

- **Depends on:** 20261019-4.
- **Came from:** The user, 2026-10-20.
- **Design:** Operator rewrites (`--rewrites`), redact-rewrite.
- **Open questions:** None.
- **Status:** todo. Landed so far (2026-10-20): `enclave/spec/redact_rewrite_pipeline_postgres_spec.rb`, which fills the store with the real `qualify` and `redact` (the only steps that write `qualified_query`, `redacted_query`, and `placeholder_map`; `literals` and `clock-anchor` only read them) through the installed quaacks on the synthetic query, and checks the identity round trip through `quaacks redact-rewrite`. It passes: the store holds exactly what `Redaction.query` gives, so the internal_error isn't reproduced with the original's own text or with a dozen common rewrites of it (UNION, CTE, JOIN instead of EXISTS, casts, `>=`/`<=`, `= ANY`); each either redacts or refuses with a rule. The user's rewrite text is needed to go further; the likeliest unclassified raises are a rewrite pg_query can't parse (see 20261020-1's review task) and `RewriteRedaction::Error`. See also 20261020-4 and 20261020-5.

### 20261020-4. redact-rewrite: OR split into a UNION refuses at the EXISTS's `SELECT 1`. Done, see BACKLOG-COMPLETE.md.

### 20261020-5. Enclave: a local log of internal errors on the jump server.

From 20261020-3. Nothing keeps the cause of an `internal_error`: ErrorFilter.guard sends one line with the rule, and stderr goes to the null device. When `to_egress` falls back to `internal_error`, append one line to a file under the store base (mode 0600, as the store's files are), with the time, the step, the exception's class name, and the gem-relative file and line of its first backtrace location inside the enclave gem. Never the message, which can hold a value, and never a backtrace line from outside the gem. Cap the file's size. Tell the operator where it is in the driver's internal_error text. Enclave change; it goes on "Unreleased enclave changes".

- **Depends on:** None.
- **Came from:** The builder of 20261020-3, 2026-10-20.
- **Design:** Error filter.
- **Open questions:** Whether the file lives per run (in the run's store) or once per store base.
- **Status:** todo

### 20261020-6. redact-rewrite: test the parse-position range clamp. Done, see BACKLOG-COMPLETE.md.

### 20261021-4. Driver spec: `report_spec.rb` "writes the report to a file" is flaky. Done, see BACKLOG-COMPLETE.md.

### 20261021-5. Own rewrites in the report: send the deparsed text, not the raw `--rewrites` text. Done, see BACKLOG-COMPLETE.md.

### 20261110-1. Result comparison: don't refuse a nondeterministic collation when the original's order has no ties. Done, see BACKLOG-COMPLETE.md.

### 20261110-16. Arena Binding: cut the per-trial round trips. Done, see BACKLOG-COMPLETE.md.

### 20261110-19. claude_cli: keep user-level Claude Code settings out of each ask.

From the review of 20261010-18 (minor). The command runs in a private temp dir, so project settings and CLAUDE.md stay out, but user-level ones still apply: `~/.claude` settings hooks run (a UserPromptSubmit hook receives the prompt), user plugins load, and `~/.claude/CLAUDE.md` and auto-memory reach the model as context even with `--system-prompt-file`. Prompts carry only shapes, so this isn't a boundary leak, but it can steer replies or run the operator's code on every ask. Check whether `--setting-sources ""` (or similar) also stops user CLAUDE.md and memory, and add it to the default command; otherwise document `--bare` with an API key. Verify with a real `claude` run the user approves.

- **Depends on:** None.
- **Came from:** The review of 20261010-18, 2026-11-10.
- **Design:** LLM client.
- **Status:** todo

### 20261110-14. Arena Binding, stage 3: the arena prepares with declared types. Done, see BACKLOG-COMPLETE.md.

### 20261110-7. Report: name the check behind an `unsupported_order` refusal. Done, see BACKLOG-COMPLETE.md.

### 20261111-1. Refusal-reason phrases: tighten three that are loose, and tell a user's own division by zero from a pick check. Done, see BACKLOG-COMPLETE.md.

### 20261110-8. Result comparison: `0` and `-0` don't make a `min`/`max` pick refuse. Done, see BACKLOG-COMPLETE.md.

### 20261018-1. Rule generator: never cap a one-rule rewrite. Done, see BACKLOG-COMPLETE.md.

### 20261018-2. Rule `cte_fence_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261018-3. Rule `count_to_exists`. Done, see BACKLOG-COMPLETE.md.

### 20261018-4. Rule `subquery_distinct_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261018-5. Rule `subquery_order_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261018-6. Rule `distinct_key_removal`. Done, see BACKLOG-COMPLETE.md.

### 20261018-7. Rule `left_join_to_inner`. Done, see BACKLOG-COMPLETE.md.

### 20261018-8. Rule `union_to_union_all`. Done, see BACKLOG-COMPLETE.md.

### 20261018-9. Rule `count_distinct_to_subquery`. Done, see BACKLOG-COMPLETE.md.

### 20261018-10. Rule `date_cast_to_range`. Done, see BACKLOG-COMPLETE.md.

### 20261018-11. Rule `coalesce_comparison_split`. Done, see BACKLOG-COMPLETE.md.

### 20261018-12. Rule `scalar_aggregates_to_filter`. Done, see BACKLOG-COMPLETE.md.

### 20261018-13. Rule `correlated_aggregate_to_join`. Done, see BACKLOG-COMPLETE.md.

### 20261018-14. Rule `aggregate_before_join`. Done, see BACKLOG-COMPLETE.md.


### 20261112-032618-1. Tests and a missed case left by 20261112-000801-1.

- **Depends on:** None.
- **Came from:** The first review of 20261112-000801-1 (minor), 2026-11-12.
- **Design:** DESIGN.md, result-comparison; docs/float-values.md.
- **Status:** todo.
- **What's wrong:**
  - A cut-tie layout in the second look is meant to need both hashes to match, but keying it on the first-look hash alone keeps every spec green. Either key is strict, so this can only lose the flag, never set it wrongly.
  - The second look cancels rows on the first-look hash greedily before pairing the rest on the second-look hash. When two rows share a first-look hash but have different second-look hashes, it can cancel the wrong pair and miss the flag, though a one-to-one pairing exists. This also only loses the flag.
- **Do:** Add a test that goes red when the cut-tie layout keys on one hash only. Decide whether the greedy miss is worth a fix (for example, cancel on the full 64-byte hash first); if so, test it first. Keep the guarantee that values one part in ten million or more apart are never flagged.

### 20261111-200042-1. Keyword operators: a whole-row operand reaches a user operator on the row type. Done, see BACKLOG-COMPLETE.md.

### 20261111-220000-1. Counterexample rounds: cap the work in a round.

From 20261011-10 item 3. A counterexample round has no time budget of its own. A rewrite gets at most 3 rounds and each arena statement has a 10 s `statement_timeout`, but nothing caps how many inserts a round takes, and each insert loads in every load order and again for each untested atom (`Counterexamples.compare`, `ResultComparison.compare_in_load_orders`). The value evaluation of each insert has no timeout of its own (DESIGN.md, value evaluation). DESIGN.md now calls an unusually large LLM reply unsupported in v1. After v1, add a cap: either on inserts per round (a clean refusal past it) or a wall-clock budget per round like `Protocol::RewriteBudget`, and a timeout on the value evaluation. Test with real Postgres, red first. Enclave change; it goes on "Unreleased enclave changes". Not for v1 (the user chose to document the limit, 2026-11-11).

- **Depends on:** None.
- **Came from:** 20261011-10.
- **Design:** counterexamples.
- **Status:** todo

### 20261112-171103-1. Report: clearer `unstable_original` wording, a docs page with examples, and a link to it. Done, see BACKLOG-COMPLETE.md.

### 20261113-210241-1. Fuzz worlds: build a parent with exactly n children, and one with n+1, for a correlated count threshold.

The verdict half of 20261010-48, folded into 20261011-7 and not landed. A rewrite of `(SELECT count(*) FROM comments c WHERE c.post_id = p.id) > n` as `>= n` should be disproved at every n, but fuzz missed it at n=7 and n=10 even with 200 trials: world generation doesn't reliably build a parent with exactly n children. Make it do so, without letting any reported count (trials, worlds, bound) or the caution follow the threshold. 20261010-35's earlier attempt (n+1 children per parent) leaked the threshold through the load count and was rejected; handle only count(*)/count(x) with no GROUP BY, window or second target; a scalar subquery returning several rows, or a count sharing its child table with one, crashed the old code. Add the across-literals proof for it (thresholds 0..10), red first. Trust boundary: have an Opus reviewer.

- **Depends on:** 20261011-7 (landed).
- **Came from:** 20261011-7 (not landed part), 20261010-48.
- **Design:** rewrite-test (fuzz worlds).
- **Status:** todo

### 20261113-210241-2. Coverage: minors from the review of 20261011-7.

(1) `threshold_scoped?` in `enclave/lib/quaack/enclave/fuzz/coverage.rb`: its "atom holds a threshold" branch (`at.first(atom.path.size) == atom.path`) has no test; dropping it keeps the suite green. Plant one atom that contains a threshold (a boolean CASE or an unsplit expression wrapping `count(*) > n`) and assert it is reported untested, red first. (2) `Reach.worst_case?` and `Reach#threshold_bound?` in `fuzz/reach.rb` are no longer called by Coverage. Find out whether anything else uses them; if not, remove them and any spec that only covers them.

- **Depends on:** 20261011-7 (landed).
- **Came from:** The review of 20261011-7, 2026-11-13 (minor).
- **Design:** rewrite-test (coverage).
- **Status:** todo

### 20261114-053159-1. Rewrite dedupe: minors from the review of 20261011-11.

(1) `RewriteAssumptions.normalized` (`enclave/lib/quaack/enclave/rewrite_assumptions.rb`) collapses whitespace inside quoted literals of a check `expression`, so `status <> 'a  b'` and `status <> 'a b'` dedupe and the second assumption is never checked. Leave quoted text alone, or compare after a pg_query parse and deparse. (2) Duplicates inside one rewrite-check call don't dedupe: `context[:stored]` holds only earlier calls' entries and `save` doesn't add to it, so one LLM response with the same SQL twice (reordered assumptions, or identical ones) stores two entries. This predates 20261011-11. Fix and test both, red first. Enclave change.

- **Depends on:** 20261011-11 (landed).
- **Came from:** The review of 20261011-11, 2026-11-13 (minor).
- **Design:** rewrite-rules.
- **Status:** todo

### 20261114-060517-1. Array reads: minors from the review of 20261012-8.

(1) The `'{%d,%d}'::bigint[]` family in `enclave/spec/across_literals_postgres_spec.rb` (~line 64) stays green with `Reach#constants?` broken, because a cast string already counts as one constant. It guards regressions only. Either say so in its name or replace it with a family that pins the change. (2) In `value_pools.rb` `literals`, the `next evaluate(...) if whole_array?(...)` line wraps awkwardly at the line limit; a plain if/else reads better. Cosmetic.

- **Depends on:** 20261012-8 (landed).
- **Came from:** The review of 20261012-8, 2026-11-14 (minor).
- **Design:** rewrite-test (coverage).
- **Status:** todo

### 20261114-160902-1. LiteralSet: picks for the varchar IN shape Postgres prints.

From the review of 20261012-9 (minor). `LiteralSet` doesn't pick for `(status)::text = ANY ((ARRAY[$1::varchar, $2::varchar])::text[])`: `lexpr` isn't a plain column and the elements carry their own casts (`enclave/lib/quaack/enclave/literal_set.rb`, ~lines 332-336). The cost is weaker picks, not a leak. Reproduce with a realistic ORM varchar IN query first; if the client's own SQL doesn't take this form, say so and drop the task.

- **Depends on:** 20261012-9 (landed).
- **Came from:** The review of 20261012-9, 2026-11-14 (minor).
- **Design:** literal-sets.
- **Status:** todo

### 20261114-170743-1. InsertValues: judge the overload Postgres resolves a call to, not every overload with that many arguments.

The part of 20261012-12 that didn't land (the user said yes to it on 2026-10-12). `InsertValues::MUTABLE_SQL` matches by name and argument count, so `timezone($1, <timestamp>)` is refused because `timezone(text, timetz)` is STABLE, though `timezone(text, timestamp)` is IMMUTABLE. Doing it right means asking Postgres which overload a call resolves to (a temporary view plus `pg_depend`, or a probe like qualify uses), which would run analysis, including type input functions, before the volatility check, or reorder insert-check rules 11 and 12. Find a way that doesn't run anything a refused insert shouldn't, test first, and update the system prompt's overload sentence and DESIGN.md (both say overloads are judged by argument count today). Enclave change; have an Opus reviewer.

- **Depends on:** 20261012-12 (landed).
- **Came from:** 20261012-12 (not landed part).
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261114-170743-2. llm-counterexamples: re-measure round-1 refusals with the new prompt and feedback.

The measuring half of 20261012-12, skipped because it needs live LLM calls (spend). With the corpus harness from 20261012-5 phase 2 (`scratch/corpus-20261012-5/` in the main checkout), re-run round 1 for the three models on the new prompt, replay through production InsertCheck with the new feedback, and compare round-1 refusals per rule and wrong rewrites caught against the old numbers (claude 41/76, gemini 35/76, gpt-6.1-sol 69/76 after 3 rounds; claude ended round 1 with nothing accepted on 42 of 99 cases). Ask the user before spending on the API.

- **Depends on:** 20261012-12 (landed); the user's go-ahead on spend.
- **Came from:** 20261012-12 (not landed part).
- **Design:** llm-counterexamples.
- **Status:** todo (waits on the user)

### 20261114-190619-1. TestPostgres: don't sweep another runner's live containers when hostnames match but PID namespaces differ. Done, see BACKLOG-COMPLETE.md.

### 20261114-190619-2. TestPostgres PgBouncer wait: minors from the review of 20261012-20.

(1) The timeout error in `spec/support/test_pgbouncer.rb` (~line 85) names the container but not the port, and doesn't say which probe failed (in-container `pg_isready` or the host ping). Name both. (2) The new spec's TCP forward (`spec/test_postgres_spec.rb`, ~lines 545-576) leaves its copy threads and proxied sockets alive until the process exits, because the listener closes only through the forward thread's own `ensure`. Close them in the spec's `ensure`. Both harmless today.

- **Depends on:** 20261012-20 (landed).
- **Came from:** The review of 20261012-20, 2026-11-14 (minor).
- **Design:** none (test harness).
- **Status:** todo

### 20261114-193920-1. Test harness owner-host label: minors from the review of 20261114-190619-1.

(1) A crashed pre-change run on Linux leaves a container labeled with the bare hostname; the new label never matches it, so it counts as foreign and stays until someone runs `docker rm` by hand (it can't remove a live run's container, so this is safe). Say so in a comment at `spec/support/test_postgres.rb` (~line 270) and `e2e/verify.rb` (~line 86), and in the sweep's docs if they describe cleanup. (2) `spec/support/test_postgres.rb` (~line 256) checks `File.exist?` before `File.stat` on `/proc/self/ns/pid`, while `e2e/verify.rb` (~line 35) rescues `SystemCallError`; make them the same so an unreadable `/proc` can't raise in one and not the other. Cosmetic.

- **Depends on:** 20261114-190619-1 (landed).
- **Came from:** The review of 20261114-190619-1, 2026-11-14 (minor).
- **Design:** none (test harness).
- **Status:** todo

### 20261114-211947-1. A planted replay for the enumerate_disproved fate.

From the review of 20261012-29. No replay run ends a rewrite as `enumerate_disproved`, so a driver regression in carrying an enumerate disproof passes every replay. Plant a rewrite that random fuzz misses and enumerate catches (such as a NULLS LAST change) and check its fate and report text. Also make the cache-key check in the replay helper independent of example order (the enumerate cache key only shows under defined order).

- **Depends on:** 20261012-29 (landed).
- **Came from:** The review of 20261012-29, 2026-11-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261114-222449-1. FuzzSizes.count: bare relation names count as zero.

From the review of 20261012-31 (minor). `query_tables` skips any relation that isn't schema-qualified, so `SELECT * FROM a JOIN public.b` counts 1 and the bound could be claimed too early. Queries reach it fully qualified today. Count bare RangeVars that aren't CTE names, or treat an unqualified relation as one more table. Enclave change; it goes on "Unreleased enclave changes".

- **Depends on:** 20261012-31 (landed).
- **Came from:** The review of 20261012-31, 2026-11-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261114-222449-2. fuzz_sizes_count_spec has no self-join or CTE example.

From the review of 20261012-31 (minor). Add examples: a self-join counts one table, a CTE name isn't counted, aliases collapse. Test only.

- **Depends on:** 20261012-31 (landed).
- **Came from:** The review of 20261012-31, 2026-11-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261115-020212-1. Measure the trial rate after Coverage::FIRST = 1024.

From 20261012-50. Compare the trial rate with 20261012-4's numbers on the Canvas and hard corpora, and check q15a's run-to-run swing. The harnesses and q15a aren't in the repo, so this needs them first (or the user's real-schema run burndown: `fuzz` trials and times). Expected about 0.9x on a query with an atom no world can show, estimated only.

- **Depends on:** 20261012-50 (landed).
- **Came from:** The build of 20261012-50, 2026-11-14.
- **Design:** rewrite-test (coverage).
- **Status:** todo

### 20261115-030731-1. Kinds: no spec covers the hold of a compared :key column.

From the review of 20261012-46 (minor). Narrowing `key_compared?` in `enumerate/kinds.rb` to `%i[pk]` leaves the whole spec file green; the bound would fall from w=2 to w=1 on a keyset shape that compares a foreign key (`orders.customer_id > 25`). Add a Kinds expectation for a compared `:key` column, like the `:pk` one.

- **Depends on:** 20261012-46 (landed).
- **Came from:** The review of 20261012-46, 2026-11-15 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261115-055039-1. Own rewrites: rescue a deparse failure, and decide on quoted identifier names.

From the review of 20261021-5 (minor). (1) `OwnRewrites.text` doesn't rescue an exception from `deparse`; a statement that parses but can't deparse would crash the step (no leak). Rescue and return nil. (2) A quoted identifier's name (`AS "Odd Name"`) still goes out in the report's own-rewrite text. The report already carries table and column names and the operator wrote the text, so it isn't a new leak. Open question for the user: should identifier names in own rewrites be redacted too?

- **Depends on:** 20261021-5 (landed).
- **Came from:** The review of 20261021-5, 2026-11-15 (minor).
- **Design:** Report, Operator rewrites (`--rewrites`).
- **Open questions:** Whether identifier names in own rewrites should be redacted (part 2 only).
- **Status:** todo

### 20261115-073253-1. Window picks: gaps the builder of 20261015-5 left.

From the build of 20261015-5. (1) `ARRAY(SELECT ...)` with no `ORDER BY`, or one that ties, is neither forced nor refused; only reordered loads catch it, and the load-order specs rely on it to expose ties, so refusing it means rewriting those specs. (2) A window `min` or `max` over values that are equal but print differently (numeric 10 vs 10.0) has no check; the non-window ones do. (3) A window over unique input in an aggregate select with no GROUP BY uses `name.*::text` and fails at run time as `pick_run_failed`; refuse it cleanly. (4) Fail-closed costs worth revisiting if real runs hit them: the `row_number` check refuses any tie in the partition, not just at the kept row; `first_value`, `last_value` and `array_agg` over the default RANGE frame refuse; named windows refuse (inline them before forcing); `PEER_AGGREGATES` is a fixed list. Check each is real before building.

- **Depends on:** 20261015-5 (landed).
- **Came from:** The build of 20261015-5, 2026-11-15.
- **Design:** fixture-compare.
- **Status:** todo

### 20261115-073253-2. Window picks: an unaliased FROM subquery, and GROUPING SETS with a window.

From the review of 20261015-5 (minor). (1) A Postgres 16+ unaliased FROM subquery (`SELECT *, row_number() OVER (...) rn FROM (SELECT * FROM items)`) refuses as `unforceable_pick` where the aliased form matches. Support it or list it in DESIGN.md as unsupported in v1. (2) `GROUP BY GROUPING SETS` or `ROLLUP` with a window function may end as `pick_run_failed` rather than a clean refusal (the reviewer's guess, untested). Test first, then refuse cleanly.

- **Depends on:** 20261015-5 (landed).
- **Came from:** The review of 20261015-5, 2026-11-15 (minor).
- **Design:** fixture-compare.
- **Status:** todo

### 20261115-092519-1. Pipelined batch: a spec for a statement_timeout mid-pipeline with a binding.

From the review of 20261110-16 (minor). No spec covers a statement_timeout firing mid-pipeline with a binding. The code is right today (57014 isn't a DataError SQLSTATE, so it's no kill), but a later change that counted a late Sync cancel as a candidate kill would pass every spec. Add a Postgres test: a bound trial whose candidate times out mid-pipeline is not compared and not a kill.

- **Depends on:** 20261110-16 (landed).
- **Came from:** The review of 20261110-16, 2026-11-15 (minor).
- **Design:** fuzz.
- **Status:** todo

### 20261115-110237-1. Report: the accountability note says "two runs of the original query" for cut_tie too.

From the build of 20261112-204606-2 (minor). The note in `driver/lib/quaack/driver/report/template.html.erb` still says "or two runs of the original query", which is loose for `cut_tie` (its runs are the full runs without the cut). Reword, red first.

- **Depends on:** 20261112-204606-2 (landed).
- **Came from:** The build of 20261112-204606-2, 2026-11-15 (minor).
- **Design:** report.
- **Status:** todo
