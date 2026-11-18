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
- 20261112-032618-1
- 20261015-5
- 20261110-16
- 20261114-222449-1
- 20261114-053159-1
- 20261011-5
- 20261012-52
- 20261020-5
- 20261113-210241-1


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
- **Note (2026-11-18):** the review of 20261113-210241-1 found its spread worlds load about a threshold's worth of child rows per parent, so a pass's trial count under the real stop rule follows a count threshold somewhat more than before. Include count thresholds in the measurement.
- **Came from:** The second review of 20261010-35, 2026-10-10. Priority: trust boundary.
- **Design:** What goes into the enclave; the burndown; rewrite-test.
- **Landed so far:** 2026-10-11 (task/20261010-47): the first `across_literals_postgres_spec.rb`, for ScenarioTests' reports (since replaced by 20261012-4's version for fuzz).
- **Status:** todo

### 20261010-48. Untested conditions: a correlated count threshold, built without leaking the threshold. Dropped, see BACKLOG-COMPLETE.md.

### 20261010-52. `not_in_to_not_exists` repeat check: scope and spelling. Done, see BACKLOG-COMPLETE.md.

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

### 20261012-24. fuzz copies: test that each table the copies' foreign keys point to gets a row. Done, see BACKLOG-COMPLETE.md.

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
2. **The slowest kill's margin.** The slowest kill in any corpus, `cv_topics_nulls_last`, comes at trial 8,227: 25–28 s with four measurement shards running, about half the cap. A jump server about twice as slow would lose it. The user chose the plain 60 s cap (20261012-35's option 1) knowing this; option 3 there (a 10,000-trial floor up to the cap) is the fix if the user's real-schema run shows trial rates that low. Check the rates in that run's burndown (`fuzz` trials and times) and ask the user before changing the rule.

- **Landed so far:** Item 1 (2026-11-18): DESIGN.md's Stop rule bullet and `Fuzz::StopRule`'s comment now say "about 90 seconds" and name what can run over. Item 2 waits on the user's real-schema run.

- **Depends on:** None.
- **Came from:** The review of 20261012-35, 2026-10-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-50. Fuzz coverage: check more worlds now that a check is one statement, and a literal 0. Done, see BACKLOG-COMPLETE.md.

### 20261118-191500-1. Send every atom as untested when the search couldn't test a rewrite.

From 20261012-52, bullet 1. A rewrite rewrite-test's search couldn't test goes on with no untested atoms, so llm-counterexamples has nothing to aim its rows at for it. The builder recommends sending every atom of the original as untested, since none was tested. That changes the counterexample prompt for such rewrites, so recorded replays with an untested rewrite would drift and need re-recording. Waiting on the user's decision. Enclave change if built; it goes on "Unreleased enclave changes".

- **Depends on:** None.
- **Came from:** 20261012-52.
- **Design:** rewrite-test (coverage), counterexamples.
- **Open questions:** Whether to do it, and whether the replay drift is acceptable.
- **Status:** todo

### 20261118-185846-1. Fuzz and enumerate pass a wrong rewrite that needs both edges of an FK cycle filled.

From 20261012-52. On `accounts.course_template_id -> courses` (nullable) and `courses.account_id -> accounts` (NOT NULL), dropping a Rails `where.missing` anti join (`... LEFT JOIN courses c ON c.id = a.course_template_id WHERE c.id IS NULL` rewritten as all accounts) passes fuzz at 1000 trials and enumerate at 2000 worlds (bound 3). A world that tells them apart needs an account whose template is a course of an account, which the lift loads with every constraint enforced in table order (`Fuzz::Lift#loaded`, "a cycle among them loads in the order found, and fails to load if it must"), so the kill likely never lifts. Load the nullable cycle column after both tables, by UPDATE, as counterexample rounds do (20261003-17), and add the case to `enclave/spec/fuzz_fk_cycle_postgres_spec.rb`, red first. Enclave change; it goes on "Unreleased enclave changes".

- **Depends on:** None.
- **Came from:** The build of 20261012-52, 2026-11-18.
- **Design:** rewrite-test (fuzz's lift).
- **Status:** todo

### 20261015-1. TestPostgres.extra_server: a failed cleanup masks the readiness error. Done, see BACKLOG-COMPLETE.md.

### 20261015-4. Result-comparison on the racetrack doesn't check inner cuts or picks.

From the build of 20261008-67. `ProductionComparison` (result-comparison on production data) runs neither `InnerCuts` (a LIMIT or OFFSET below the top level) nor `Picks` (a DISTINCT ON without a full order, an aggregate that follows its input order, a DISTINCT or set operation that keeps one of several equal values), which fixture-compare now has. A candidate whose inner pick goes another way can match there by luck, and a good one can fail against an original whose own pick decides its answer. Decide whether production gets the same checks (each forced run re-reads production rows, so it costs a full query run per direction), and test first.

- **Depends on:** None.
- **Came from:** The build of 20261008-67, 2026-10-15.
- **Design:** result comparison, fixture-compare.
- **Status:** todo

### 20261015-5. Fixture-compare: window functions over tied rows pick arbitrarily. Done, see BACKLOG-COMPLETE.md.

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

### 20261020-5. Enclave: a local log of internal errors on the jump server. Done, see BACKLOG-COMPLETE.md.

### 20261020-6. redact-rewrite: test the parse-position range clamp. Done, see BACKLOG-COMPLETE.md.

### 20261021-4. Driver spec: `report_spec.rb` "writes the report to a file" is flaky. Done, see BACKLOG-COMPLETE.md.

### 20261021-5. Own rewrites in the report: send the deparsed text, not the raw `--rewrites` text. Done, see BACKLOG-COMPLETE.md.

### 20261110-1. Result comparison: don't refuse a nondeterministic collation when the original's order has no ties. Done, see BACKLOG-COMPLETE.md.

### 20261110-16. Arena Binding: cut the per-trial round trips. Done, see BACKLOG-COMPLETE.md.

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


### 20261111-200042-1. Keyword operators: a whole-row operand reaches a user operator on the row type. Done, see BACKLOG-COMPLETE.md.

### 20261111-220000-1. Counterexample rounds: cap the work in a round.

From 20261011-10 item 3. A counterexample round has no time budget of its own. A rewrite gets at most 3 rounds and each arena statement has a 10 s `statement_timeout`, but nothing caps how many inserts a round takes, and each insert loads in every load order and again for each untested atom (`Counterexamples.compare`, `ResultComparison.compare_in_load_orders`). The value evaluation of each insert has no timeout of its own (DESIGN.md, value evaluation). DESIGN.md now calls an unusually large LLM reply unsupported in v1. After v1, add a cap: either on inserts per round (a clean refusal past it) or a wall-clock budget per round like `Protocol::RewriteBudget`, and a timeout on the value evaluation. Test with real Postgres, red first. Enclave change; it goes on "Unreleased enclave changes". Not for v1 (the user chose to document the limit, 2026-11-11).

- **Depends on:** None.
- **Came from:** 20261011-10.
- **Design:** counterexamples.
- **Status:** todo

### 20261112-171103-1. Report: clearer `unstable_original` wording, a docs page with examples, and a link to it. Done, see BACKLOG-COMPLETE.md.


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

### 20261115-020212-1. Measure the trial rate after Coverage::FIRST = 1024.

From 20261012-50. Compare the trial rate with 20261012-4's numbers on the Canvas and hard corpora, and check q15a's run-to-run swing. The harnesses and q15a aren't in the repo, so this needs them first (or the user's real-schema run burndown: `fuzz` trials and times). Expected about 0.9x on a query with an atom no world can show, estimated only.

- **Depends on:** 20261012-50 (landed).
- **Came from:** The build of 20261012-50, 2026-11-14.
- **Design:** rewrite-test (coverage).
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

### 20261118-194818-1. Denormalized fixture: a domain CHECK on the copy column (minor from 20261011-5).

The review of 20261011-5 found that `DenormalizedFixture`'s `CONSTRAINED` query misses a CHECK defined on a domain used as the copy column's type (it sits on `contypid`, not `conrelid`), so updates 2 and 3 still run and such a world fails to load. Rare; the cost is fewer worlds, not a false disproof. Fix by also checking the column type's domain constraints, or list it in DESIGN.md as unsupported in v1. Postgres test red first.

- **Depends on:** 20261011-5 (landed).
- **Came from:** The review of 20261011-5, 2026-11-18 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261118-204800-1. Differ: mark the server clock per statement in `official?` (minor from 20261012-52).

The second review of 20261012-52 found that `Fuzz::Differ#official?` runs the original and the candidate under one savepoint and one `ServerClock.mark`. A foreign cancel that lands after more than the statement timeout has passed across both statements reads as QUAACK's own timeout and counts as "no difference". Narrow, and only near the timeout; it errs toward leaving an atom untested. Fix by marking the clock per statement. Postgres test red first. Enclave change.

- **Depends on:** 20261012-52 (landed).
- **Came from:** The second review of 20261012-52, 2026-11-18 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261118-211321-1. claude_cli: prove `--setting-sources ""` keeps user CLAUDE.md, memory, hooks and plugins out (follow-up to 20261110-19).

20261110-19 added `--setting-sources ""` to the default command, but couldn't verify its effect: this machine has no `~/.claude/CLAUDE.md`, and a temp `CLAUDE_CONFIG_DIR` isn't logged in. With a run the user approves, plant a sentinel in a user CLAUDE.md, in auto-memory, and in a UserPromptSubmit hook, make a synthetic ask, and confirm none reaches the reply or runs. If any does, document `--bare` with an API key instead.

- **Depends on:** 20261110-19 (landed).
- **Came from:** The review of 20261110-19, 2026-11-18 (minor).
- **Design:** LLM client.
- **Status:** todo (needs the user's go-ahead for real claude calls and a planted user CLAUDE.md)

### 20261118-220251-1. Disproof sizes show a count threshold of 1 to 4 (from 20261113-210241-1).

The review of 20261113-210241-1 found that a disproof of `count(...) > n` rewritten as `>= n` now reliably shrinks to a parent with about n children, so for n = 1..4 the `sizes` that go out show the threshold (5 and up are capped as "5 or more", DESIGN.md rewrite-test, "What it sends"). The cap already applied to HAVING copies; this task makes correlated thresholds reach it reliably. Ask the user whether count-threshold disproofs should drop `sizes` or always report "5 or more", then build it with an across-literals check on `sizes`.

- **Depends on:** 20261113-210241-1 (landed).
- **Came from:** The review of 20261113-210241-1, 2026-11-18. Priority: trust boundary.
- **Design:** rewrite-test.
- **Status:** todo (waits on the user's choice)

