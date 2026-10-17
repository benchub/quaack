# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

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

### 20261008-57. Running the rules: leftovers from 20261002-2. Done, see BACKLOG-COMPLETE.md.

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

### 20261010-7. Result comparison and literals: two small gaps from the review of 20261004-92 and -94.

- The `literals_already_used` pattern (`USERS`) lists the steps that store entries comparing literal sets by name, but `rewrite_prune`, `rewrite_check`, `index_test` and `index_rank` also load `literal_sets` and aren't in it. Harmless today (they write no entries compared across sets); add a spec that fails when a step that writes such an entry isn't listed, or list them.
- A full-run row-cap refusal is reported with the same rule as a timeout (`unsupported_order`), so the operator can't tell the two apart. Give the report a way to say which (a field or a separate note), if it matters to them.

- **Depends on:** 20261004-92, 20261004-94.
- **Came from:** The review of 20261004-92 and -94, 2026-10-10 (minor).
- **Design:** result comparison, literals.
- **Status:** todo

### 20261010-18. LLM adapter for the Claude Code CLI.

The `claude` CLI can run a single prompt and exit, the way the `copilot` CLI does (`claude -p`, with a model flag and no tools). Add a provider type, for example `claude_cli`, beside `copilot_cli`, modeled on `driver/lib/quaack/driver/llm/copilot_cli_adapter.rb`: a local command run once per ask without a shell, the prompt passed by file or stdin, a `command_template` with `{prompt_file}` and `{model}` placeholders, `timeout_seconds`, and the same error handling and reply shape checks as the other adapters. Check the CLI's current flags and output format (a JSON output mode, how to turn tools and session saving off, how it reports usage) before building. Keep it driver-only: the enclave must never see the adapter, and the prompt carries only what the other adapters already send. Update the provider list, the `llm` block rules and the example config in DESIGN.md and the README, and add the type to the boundary specs' provider coverage if they list providers.

- **Depends on:** none.
- **Came from:** the user, 2026-10-10.
- **Design:** LLM client.
- **Status:** todo

### 20261010-39. Untested conditions: CTE, scalar subquery, second column tie, and shapes found while building 20261010-33/34. Dropped, see BACKLOG-COMPLETE.md.

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

### 20261010-44. Burndown: minors from 20261010-20.

1. **index-rank's added count is combinations, not ideas.** The funnel this item was about is gone (20261012-6). The Sankey draws index-rank in its own unit, sets, with a note on why it tries that many combinations (`sankey.rb` `COMBINATIONS`), and the table says "combinations tried". Check that the Sankey's index-rank layer can't be read as more ideas going on than came in. If it can't, drop this item.
2. **The rewrites' index searches join only loosely.** The replay check (`spec/pipeline_replay_spec.rb`, `burndown_joins?` with `strict: false`) requires only `in < running` on the summed "Index ideas for the rewrites" rows, which can hide a real under-carry. Check each `rewrite_N` search strictly, one at a time, and show why a narrowing happens (a rewrite dropped after its index search keeps its index-test out but has no LLM round).
3. No focused enclave unit spec for `RewriteBurndown#carried` (nearest earlier stage, falling back past a missing stage); it is covered only through the replay and rewrite step specs.

- **Depends on:** 20261010-20 (landed).
- **Came from:** The reviews of 20261010-20, 2026-10-10.
- **Design:** report, burndown.
- **Status:** todo

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

### 20261010-52. `not_in_to_not_exists` repeat check: scope and spelling.

From the review of 20261010-12 (minor). `repeated?` uses `Tree.find_all(select, ...)`, which probably also counts copies in nested subqueries and CTEs of the same SELECT, so a copy in another scope plus one in GROUP BY or ORDER BY refuses a rewrite that would have worked (untested). Copies written differently (another alias, an added cast) aren't detected and fall back to `failed_to_plan`, which is safe but wastes a candidate; list that in docs/transforms/not_in_to_not_exists.md. Test the nested-scope case and either count only this SELECT's own copies or document the extra refusal.

- **Depends on:** 20261010-12 (landed).
- **Came from:** The review of 20261010-12, 2026-10-10.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261011-5. Denormalized fixture: a UNIQUE or CHECK on the copy column (minors from 20261010-2).

The review of 20261010-2 found: if the copy column has a UNIQUE (or exclusion) constraint, update 3 gives every parentless row the same class-parent id, and update 2 can repeat ids too, so the load fails where the old single update loaded. A CHECK on the copy column that another class's parent id violates fails the load the same way. Since 20261012-4, `DenormalizedFixture`'s UPDATEs run in fuzz's worlds (`fuzz/session/loader.rb`, `fuzz/lift.rb`), so such a world fails to load and fuzz treats it as illegal: fewer worlds get tested on that table, not a false disproof. A unique denormalized copy such as `course_id` isn't realistic, so both are minor. Possible fix: skip updates 2 and 3, or limit update 3 to one row, when the copy column has a unique index; with a CHECK, skip them too. Postgres-backed tests for each, red first.

Reworded 2026-10-14 after 20261012-4: from scenario fixtures to fuzz's worlds.

- **Depends on:** 20261010-2 (landed).
- **Came from:** The review of 20261010-2, 2026-10-11 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261011-7. A count threshold makes every atom of the query untested; keep the atoms outside the aggregate's scope.

From the review of 20261011-2 (minor, usefulness). Any query that compares an aggregate with a constant reports every atom as untested, including atoms unrelated to the count (`published = true` next to `HAVING count(*) > 5`). Since 20261012-4 that's fuzz's coverage: `Fuzz::Coverage` (`fuzz/coverage.rb`, ~line 53) skips every atom when `Fuzz::Reach.worst_case?` holds, and `Reach#threshold_bound?` (`fuzz/reach.rb`, ~lines 35–38) is true for any aggregate compared with a constant, or any constant comparison over a derived table or CTE with an aggregate. That is common in reporting and ORM SQL, so the caution says nothing useful for those queries. Keep the real result for atoms outside the aggregate's scope (WHERE atoms of the grouped query, whose chance of being reached by a world doesn't depend on the threshold); only the threshold atom, and atoms inside its correlated subquery, get the worst case.
- It needs its own across-literals proof in `enclave/spec/across_literals_postgres_spec.rb` (thresholds 0..10, all operators, every outgoing field identical, with the other atoms' states real), red first. Shapes to cover include `HAVING count(*) > 1` with a pinned `users.id IN` list (from 20261010-39) and `count(...) > 2 AND title = 'x' AND score > 3` (from 20261010-46).
- **Folded in from 20261010-48 (2026-10-14):** test the atoms under a correlated count threshold too (`(SELECT count(*) FROM comments c WHERE c.post_id = p.id) > 2`), so a `count > n` vs `count >= n` rewrite is caught, without letting any reported count or the caution depend on the threshold. 20261010-35's earlier attempt (n+1 children per parent, in the removed scenario builder) leaked the threshold through the load count and was rejected; its findings that may still apply: handle only count(*)/count(x) with no GROUP BY, window or second target; a non-aggregate scalar subquery returning several rows, or a count sharing its child table with one, crashed the old code; the boundary needs a parent with exactly n children and one with n+1.

Opus builder and reviewer.

Reworded 2026-10-14 after 20261012-4: the vacuity guard and its S1 reach became `Fuzz::Coverage` and `Fuzz::Reach`, and the corpus's HAVING entries are gone, so the proof goes in the across-literals spec.

- **Depends on:** 20261011-2 (landed with its fix round).
- **Came from:** The review of 20261011-2, 2026-10-11 (minor).
- **Design:** rewrite-test (coverage).
- **Status:** todo

### 20261011-8. report_spec: `html` and `ranking` are memoized lets, so a second render after changing the payload is stale.

Found in the build of 20261010-10. In `driver/spec/report_spec.rb` the memoized `html` and `ranking` lets make a second `whos` call after mutating the payload return the stale render. The existing example "says not recorded for the indexes of a run that recorded no sources" calls `whos` twice and likely has this weakness in its second half (it may pass whatever the code does). Render fresh for each call (build the report in a helper, not a memoized let), then mutate the code under test to confirm that example goes red. Check the other examples that call a render helper twice.

- **Depends on:** 20261010-10 (landed).
- **Came from:** The build of 20261010-10, 2026-10-11.
- **Design:** report.
- **Status:** todo

### 20261011-10. Rewrite budget: minors from 20261010-53.

(1) DESIGN.md's budget paragraph (rewrite-test, ~line 1149) doesn't say a running statement can overrun the deadline by up to its 10 s `statement_timeout`: add one clause. (3) Counterexample rounds have no overall budget (only the 10 s per statement). DESIGN.md says they "load only the LLM's inserts and have no such budget", but not why that's fine; add that, or add a budget if rounds can pile up.

Trimmed 2026-10-14 after 20261012-4: removed (2), the burndown losing an out-of-time rewrite-test's fixture loads and retries. rewrite-test no longer loads scenarios, and an out-of-time rewrite records fuzz's record with `not_tested_in_time` 1 (`RewriteBurndown#record_fuzz`).

- **Depends on:** 20261010-53 (landed).
- **Came from:** The review of 20261010-53, 2026-10-11 (minor).
- **Design:** rewrite-test, counterexamples.
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

### 20261012-1. A CHECK's IN list on a varchar column reads as one array literal. Done, see BACKLOG-COMPLETE.md.

### 20261012-3. rewrite-test: a bounded enumeration pass after the random search, and what a pass says. Done, see BACKLOG-COMPLETE.md.

### 20261012-4. rewrite-test: replace ScenarioTests with the disproof search. Done, see BACKLOG-COMPLETE.md.

### 20261012-5. Measure what the LLM counterexamples catch that the mechanical search and enumeration don't. Done, see BACKLOG-COMPLETE.md.

### 20261012-6. Report: remove the burndown funnels; the Sankey diagrams replace them. Done, see BACKLOG-COMPLETE.md.

### 20261012-7. A CHECK with NOT IN on a varchar column is refused as `complex_check`.

From the review of 20261012-1. `g varchar CHECK (g NOT IN ('bad', 'worse'))` prints as `((g)::text <> ALL ((ARRAY['bad'::character varying, 'worse'::character varying])::text[]))`. `Scenarios::Checks::KINDS` (`enclave/lib/quaack/enclave/scenarios/checks.rb:21`) doesn't hold `AEXPR_OP_ALL`, so `Checks.new` raises `complex_check`. fuzz doesn't use `Checks`, but llm-counterexamples' `Counterexamples::ParentRows` does (`counterexamples/parent_rows.rb`, ~line 44), so when a counterexample round's accepted inserts need a parent row, and any table in their foreign-key closure (`ArenaSchema.load_closure`) has such a CHECK, the round fails with `complex_check` instead of testing the LLM's rows. That hits every rewrite's rounds on a schema that uses NOT IN CHECKs on varchar columns near the queries' tables. `Sides.sides` already reads `<> ALL` over a cast ARRAY since 20261012-1, so accepting it should be small. DESIGN.md doesn't list NOT IN as simple today, so update its simple-CHECK sentence. Also add the specs the review found missing, for behaviour it checked by hand: a CHECK IN list holding NULL (`IN ('p', NULL)` gives values `["p"]` and, as in Postgres, rejects nothing), and a one-element IN list (which prints as `= 'only'`). Reworded 2026-10-14 after 20261012-4 for the ParentRows path (kept by the user, 2026-10-14).

- **Depends on:** None.
- **Came from:** The review of 20261012-1, 2026-10-12 (minor).
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261012-8. Value pools: an array literal under `= ANY` isn't split, and a bare `ARRAY[...]` compared with an array column is.

From the build and review of 20261012-1. Two readers of array sides in `ValuePools::Sides.sides` still get the wrong values. Check each first:
- An array literal, not `ARRAY[...]`: `CHECK (f = ANY ('{u,v}'::text[]))` gives `Checks#values` `[]` and then `unsatisfiable_check`, and a query's `s.a::text = ANY ('{x,y}'::text[])` gets a pool with nothing satisfying and `"{x,y}"` as its only literal. Postgres never prints an IN list this way, but drivers that bind a list as one array (node-postgres, Ecto, `= ANY($1)`) give queries in this shape. Split it into its elements in Postgres (`unnest`), not by parsing the text.
- A bare, uncast `ARRAY[...]` compared with `=` on an array column (`tags = ARRAY['a', 'b']`) is split into elements, so its pool comes out empty. 20261012-1 keeps the cast form whole; do the same for the bare one.
- Also from the builder, carried into fuzz by 20261012-4: `Fuzz::Reach#column_compared?` (`enclave/lib/quaack/enclave/fuzz/reach.rb:52`, which replaced the vacuity guard's `Skips#column_compared?`) counts only a constant or a list (IN, BETWEEN) as a constant side, not `col = ANY (ARRAY[...])`, cast or not. So a derived aggregate compared as `t.k = ANY (ARRAY[2, 3])` may not get the worst case, and the coverage caution could follow those literals. Read from the code, not yet run: reproduce first. If real, it's a trust-boundary fix (add the family to `across_literals_postgres_spec.rb`).

Unsupported in v1 instead, if any of these turns out hard: list it in DESIGN.md.

- **Depends on:** None.
- **Came from:** The build and review of 20261012-1, 2026-10-12 (minor).
- **Design:** rewrite-test (coverage), llm-counterexamples.
- **Status:** todo

### 20261012-9. LiteralSet and CastlessIndex don't read an `ARRAY[$1, ...]` under a cast.

From the build of 20261012-1, not yet checked by a reviewer. `LiteralSet#any` (`enclave/lib/quaack/enclave/literal_set.rb:322`) reads `col = ANY (ARRAY[$1, $2])`'s elements as list placeholders, but not when the ARRAY is cast (`= ANY (ARRAY[$1, $2]::text[])`, or the cast `IN` form Postgres prints), so those placeholders fall back instead of getting worst-case and typical picks. The builder said `CastlessIndex` has a similar gap. Reproduce each with a realistic query first; for each that's real, fix it test first, and for one that isn't, say so and drop it. The picks stay in the store, so this isn't a trust-boundary issue, only weaker picks.

- **Depends on:** None.
- **Came from:** The build of 20261012-1, 2026-10-12 (minor).
- **Design:** literal-sets, index-ideas.
- **Status:** todo

### 20261012-10. llm-counterexamples counts a round where the ORIGINAL query fails as a disproof. Done, see BACKLOG-COMPLETE.md.

### 20261012-11. rewrite-test crashes when the original query fails on a scenario's data. Done, see BACKLOG-COMPLETE.md.

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

Answers (the user, 2026-10-12):
- Yes, send the refused function's name back to the LLM. It goes in a new protocol field with an egress check. The task goes on the unreleased enclave list.
- Yes, judge the overload Postgres resolves the call to, not every overload with that many arguments.

Re-measure with the corpus harness, which builds prompts with the driver's and the enclave's real code. Compare round-1 refusals and catches before and after.

- **Depends on:** None.
- **Came from:** 20261012-5's phase 2, 2026-10-12.
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261012-13. fuzz: value classes from world knowledge, and many copies of a row. Done, see BACKLOG-COMPLETE.md.

### 20261012-14. Report: minors from the reviews of 20261012-6.

1. **`StageStyle.untimed` with `not_tested_in_time: 0` is untested** (`driver/lib/quaack/driver/report/stage_style.rb`, `untimed`). A zero must give no hover note, as a missing count does. No spec feeds it a zero.
2. **The burndown table prints a negative count as a raw number.** `StageStyle.counted` treats a negative `in` or `out` as no count, so the Sankey leaves it out. The table still prints it as recorded. Show it as not counted, or flag it, the way the Sankey does.
3. **Palette coverage that went with the funnel test.** The deleted funnel test checked two things that nothing checks now:
   - every stage key has an entry in `StageStyle::COLORS`;
   - the stages in one diagram all get different colors.

   Making `operator-rewrites` violet, the same as `llm-rewrites`, stays green, and so does removing the key of a stage that the spec's fixture doesn't draw. Add both checks.
4. **The color test checks the painted stages across all diagrams together, not per diagram.** Dropping one stage's layer in only one diagram, or dropping a merge layer but keeping its after layer, leaves "paints each stage's layers in the stage's own palette color" green. The sibling test "draws one layer per state" catches both, so this is only about which test fails. Asserting the full list of `[diagram, stage]` pairs, one per layer, would make the color test catch them too.

- **Depends on:** None.
- **Came from:** The reviews of 20261012-6, 2026-10-12 (minor).
- **Design:** report, burndown.
- **Status:** todo

### 20261012-16. ResultComparison disproves a rewrite that only adds a tiebreak to its ORDER BY. Done, see BACKLOG-COMPLETE.md.

### 20261012-17. Regrouped: minors from the review of 20261012-16.

1. **A false match on float noise** (`enclave/lib/quaack/enclave/result_comparison/regrouped.rb`, about lines 73–82, and DESIGN.md's sentence "both runs fit only when all its rows are the same").
   - Row keys round floats to 8 significant digits. So rows in one of the candidate's tied groups can look the same by key while the tiebreaker still sorts them apart, and a middle row with a different label slips through.
   - Repro (`scratch/review-20261012-16/probe_float_spec.rb` in the main checkout): the original is `SELECT f, label … ORDER BY g`, with groups {(1.0, 'z')} and {(1.0000000002, 'a'), (1.0000000003, 'z')}. The candidate is `SELECT cf AS f, label … ORDER BY cg`, which ties all three rows, with values 1.0, 1.0000000002 and 1.0000000005.
   - It matches now; `main` before 20261012-16 said `value`. Postgres can return `[1.0000000002, 'a']` first, which the original can't.
   - It needs values within 1e-9 of each other that differ between the two queries, and DESIGN.md already calls float noise unsupported. So the fix is a clean refusal: build the candidate's layout on exact row text and run CutTies' `covers?`, or refuse with `unsupported_order` when a candidate group's rows differ exactly but match by key.
2. **ProductionComparison's `unsupported_order` branch is untested** (`production_comparison.rb`, `tiebroken`). Mapping `:unsupported_order` to a pass survives every test in `production_comparison_postgres_spec.rb`. The fixture path's refusal is tested. Add the same volatile-key case for production.

- **Depends on:** None.
- **Came from:** The review of 20261012-16, 2026-10-12 (minor).
- **Design:** result-comparison.
- **Status:** todo

### 20261012-19. counterexamples' `original_failed` rerun: two untested branches, and the CutTies run it skips.

From the review of 20261012-10 (minor). When a round's comparison raises a non-load error, `Counterexamples::Failure.rerun` (`enclave/lib/quaack/enclave/counterexamples/failure.rb`) reruns the original against itself, once per distinct load order. If the original fails, the round reports `original_failed`.
- **The step check is untested.** Changing `e.step == :query ? :query_failed : :not_loaded` to always return `:query_failed` passes every spec. The branch runs only when a rerun's load fails in a later load order after the candidate's error in an earlier one.
- **The multi-load-order rerun is untested.** Limiting `original_fails?` to the first load order passes every spec.
- **The CutTies unlimited-original run isn't rerun.** The rerun takes the self-comparison's path, so the run of the original without its LIMIT, which only the candidate's cut triggers, never happens in the rerun. An original that fails only there would still count as a disproof. The reviewer judged it nearly unreachable: the tiebroken runs compute every output column for every row, so a failing original fails there first.

Add tests that go red under the two surviving mutants, using real Postgres. For the CutTies gap, either show it's unreachable on a realistic query, or make the rerun follow the comparison's path.

20261012-11 moved the rerun to `ResultComparison::OriginalRerun`; its only caller is `Counterexamples::Failure`.

Trimmed 2026-10-14 after 20261012-4: removed the paragraph about ScenarioTests also using the rerun, since ScenarioTests is gone.

- **Depends on:** None.
- **Came from:** The review of 20261012-10, 2026-10-12 (minor).
- **Design:** llm-counterexamples.
- **Status:** todo

### 20261012-20. TestPostgres's PgBouncer specs flake with "Connection refused" on the published port under load.

In 20261012-10's per-commit check, `spec/test_postgres_spec.rb:414`, `:433`, `:462` and `:510` failed with `PG::ConnectionBad: connection to server at "127.0.0.1", port <published port> failed: Connection refused`, from `through_pgbouncer` (`:401`). All four passed when rerun alone. Earlier checks saw `:414` and `:862` fail the same way, and landings have called them "port-forward flakes".

A likely cause: `PgBouncer.wait_until_ready` (`spec/support/test_pgbouncer.rb`) runs `pg_isready` inside the container on 127.0.0.1:6432. But the specs connect from the host through Docker's published port, and that forward can lag behind under load. Confirm the cause first. If it's right, also wait until the published port answers from the host (for example with `PG::Connection.ping`, which stops at PgBouncer's password request and so opens no server backend). Do the same for the server's own port if `wait_until_ready` there has the same gap. Then drop these examples from the "rerun alone" folklore in landing notes.

Another candidate, found while landing 20261012-13 (2026-10-13), and to rule out first: every run that saw these flakes ran the specs inside a `docker run` runner container (the overnight sandbox setup), often while another runner ran specs at the same time. Each runner had its own PID namespace, so `TestPostgres.remove_stale_containers` in one runner saw the other runner's owner PIDs as dead and removed its live Postgres containers. With two runners overlapping, that broke a per-commit check outright (3,605 enclave failures, "No such container"). A sweep that lands mid-example would look exactly like "Connection refused" on the published port. Running each runner with `docker run --pid host` fixes the sweep. If the flakes stop under `--pid host`, this task is moot for a developer running specs on the host. The sweep may still be worth hardening, for example by keying on the container's start time, or on a host label that names the PID namespace.

- **Depends on:** None.
- **Came from:** The landing of 20261012-10, 2026-10-12.
- **Design:** none (test harness).
- **Status:** todo

### 20261012-21. report-payload: the `original_failed` "isn't a rule bug" check was green before 20261012-11.

From the build and review of 20261012-11 (minor). The `original_failed` case in report-payload's "isn't a rule bug" list (`enclave/spec/report_payload_step_spec.rb`, ~lines 1155–1162) passed before 20261012-11 too, so it guards the rule without testing that task's change. Check whether a mutant (make `original_failed` a rule bug) turns it red. If one doesn't, make it a real test or drop it.

Trimmed 2026-10-14 after 20261012-4: removed the bullets about ScenarioTests' rerun after a load failure, `VacuityGuard::Compared#compare` swallowing a foreign cancel, `ScenarioTests#shows?`'s error handling, and `pipeline_progress_spec.rb`'s `original_failed` message with scenario `"s3"`. 20261012-4 removed the first three's code, and the driver spec no longer sends that message.

- **Depends on:** None.
- **Came from:** The build and review of 20261012-11, 2026-10-12.
- **Design:** report.
- **Status:** todo

### 20261012-24. fuzz copies: test that each table the copies' foreign keys point to gets a row. Done, see BACKLOG-COMPLETE.md.

### 20261012-25. fuzz: the trial rate fell 25–40% on ORM-shaped queries after 20261012-13. Done, see BACKLOG-COMPLETE.md.

### 20261012-29. The recorded pipeline replays never run enumerate.

From the build of 20261012-3. The root suite sets `QUAACKS_ENUMERATE_WORLDS=0` for the replays' `quaacks` children, so no recorded run sends an enumerate pass or disproof through the driver: its transport check, the report's enumerate sentence, the `enumerate_disproved` fate, the burndown's `enumerate` stage and its Sankey layer are only covered by specs that build the messages by hand. With enumerate on at 30 s, the `key_in_self_join` replay spent 30 s for a bound of 1, which is why the builder left it off.

Add a replay variant that turns enumerate on with a small world cap, so its verdict doesn't depend on the machine's speed, and check that it reaches the report: a rewrite whose section shows the enumerate sentence with its bound, and the `enumerate` stage in the burndown. If a planted run can be made to have a rewrite only enumerate catches (such as a NULLS LAST change, like `cv_topics_nulls_last`), check its `enumerate_disproved` fate too. Keep the per-commit check's run time about the same: put the variant in `rake full` if it's slow.

The replay example 20261012-15 added, that no rewrite outside a run's `outcome.wrong` is `fuzz_disproved` or `enumerate_disproved`, can't fail on enumerate until a replay runs it (the review of 20261012-15). Make sure the variant runs that example too.

- **Depends on:** None.
- **Came from:** The build of 20261012-3, 2026-10-13.
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-30. enumerate: a primary key the queries read gets only a few key classes. Done, see BACKLOG-COMPLETE.md.

### 20261012-31. enumerate's pass sentence at w = 1.

From the build of 20261012-3. A pass with w = 1 says only that every one-row database (one row in one table) gave the same result. On queries over several tables that's common: 21 of the 28 sound Canvas rewrites passed at w = 1, since a join needs a row in each table. The report then says "Found no difference on N random datasets, or on any dataset of up to 1 row over its value classes.", which is true but may read as more than it is.

Open question for the user: at w = 1, should the rewrite's section keep fuzz's sentence ("It also survived N random small databases built around its own values."), use the enumerate sentence as now, or word it another way? The same choice applies to the progress line and to the burndown's `bound_1` count.

Answers (the user, 2026-10-14):
- **When to claim the bound.** The report's rewrite section and the progress line mention enumerate's bound only when it gives every table the query reads at least one row. Otherwise they use fuzz's sentence. Enumerate still tries w = 1 first, since it's cheap and catches real bugs (an inner join turned outer differs with the second table empty, and a single-table query is fully covered at w = 1); only the pass claim changes. The burndown keeps its exact bound counts.
- **No "value classes".** The user didn't know the term, so readers won't either. The new sentence: "Found no difference on N random datasets, or on any dataset of up to W rows built from the query's own values (its constants, values next to them, and NULL)." Use the same words in the progress line, and check the report's other enumerate words (stage sentences, Sankey layer, burndown words) for the term.

- **Depends on:** None.
- **Came from:** The build of 20261012-3, 2026-10-13.
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-35. fuzz's stop rule rarely stops before the 5-minute deadline, and starves enumerate. Done, see BACKLOG-COMPLETE.md.

### 20261012-40. Enumerate's value classes: generated columns, the key fallback, and two stale comments. Done, see BACKLOG-COMPLETE.md.

### 20261012-42. fuzz's RangeTables: a TABLESAMPLE hides the table's alias.

From the review of 20261012-33, 2026-10-13 (minor). `Fuzz::RangeTables` (`enclave/lib/quaack/enclave/fuzz/range_tables.rb`) registers each FROM item's alias, but a `TABLESAMPLE` wraps the table in a `range_table_sample`, so `FROM orders o TABLESAMPLE SYSTEM (10) WHERE o.total / 3 > 2` doesn't find `o`, and the column falls back to matching by name. That's harmless: the solutions still reach `orders.total`, and a same-named column elsewhere in the query gets them too, as before 20261012-33. Look through `range_table_sample` to its relation, test first, or leave it and say so in DESIGN.md beside the other fallbacks.

- **Depends on:** None.
- **Came from:** The review of 20261012-33, 2026-10-13 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-46. enumerate: a key compared with a constant lowers the bound on keyset pages.

From the review of 20261012-30, 2026-10-14 (minor). Since 20261012-30, a key column the queries compare with a constant gets its read classes and then its key classes, so `orders.id` in a keyset page goes from 1 kind to 9. Enumerate then covers fewer rows in its 30 s: on `o.id > 100 AND o.status = 'paid' AND i.qty > 0 ORDER BY o.id, i.id LIMIT 10` against a sound rewrite, `main` before 20261012-30 reached w=2 at 3,000 and at 10,000 worlds, and after it only w=1 even at 10,000. The plain keyset page still reaches w=2. A lower bound is a weaker claim, not a wrong one, and under 20261012-31's rule the report then falls back to fuzz's sentence on a join.

Give a compared key fewer classes without losing the boundary catch, test first: for example, its read classes plus the shared keys only (dropping the key-class values), or count the key-class values as cost-2 changes, so the base-choice kinds stay small. Check that 20261012-30's probe pairs are still disproved, and measure the bound w on its sound keyset pairs and the hard corpus before and after (no false disproofs).

- **Depends on:** None.
- **Came from:** The review of 20261012-30, 2026-10-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-48. fuzz's 60 s cap: say "about 90 seconds", and watch the slowest kill's margin.

From the review of 20261012-35, 2026-10-14 (minor).
1. **"At most 90 seconds" is a soft bound.** DESIGN.md's Stop rule bullet and `Fuzz::StopRule`'s comment (`enclave/lib/quaack/enclave/fuzz/stop_rule.rb`) say fuzz plus enumerate takes at most 90 s per sound rewrite. Three things can run past it: the trial in progress when the cap fires; shrinking and lifting a kill found just before the cap (up to `SHRINKS` = 200 trials, `fuzz.rb`), whose lift then fails; and building enumerate's kinds, which happens before its 30 s `Limit` starts (`Fuzz::Search#enumerate`). The rewrite's 5-minute Deadline still bounds all three. Say "about 90 seconds", and name what can run over, wording only.
2. **The slowest kill's margin.** The slowest kill in any corpus, `cv_topics_nulls_last`, comes at trial 8,227: 25–28 s with four measurement shards running, about half the cap. A jump server about twice as slow would lose it. The user chose the plain 60 s cap (20261012-35's option 1) knowing this; option 3 there (a 10,000-trial floor up to the cap) is the fix if the user's real-schema run shows trial rates that low. Check the rates in that run's burndown (`fuzz` trials and times) and ask the user before changing the rule.

- **Depends on:** None.
- **Came from:** The review of 20261012-35, 2026-10-14 (minor).
- **Design:** rewrite-test.
- **Status:** todo

### 20261012-50. Fuzz coverage: check more worlds now that a check is one statement, and a literal 0.

From the second review of 20261012-4 (minor). Coverage checks every world for the first 64 observations, then 32 per doubling of the trial count (`Fuzz::Coverage#due?`). Since 20261012-4's fix round a check is one statement per world, so a denser schedule is now cheap. The reviewer saw why it matters: `SELECT s.id FROM (… ORDER BY id LIMIT 20 OFFSET n) s WHERE s.id <> 4` leaves `s.id <> $4` untested at OFFSET 0 in 2 of 3 seeds at 20,000 trials, and at OFFSET 1, 2 or 5 in none of 21. It isn't the cut (coverage removes it): a literal `0` anywhere changes which worlds get drawn (`s.id <> 0` at OFFSET 2 does the same, `s.id <> 9` doesn't). DESIGN accepts that literals shape the worlds, so this isn't a leak of the kind 20261011-2 forbids, but with every world checked OFFSET 0 settled by 1,500 trials. Try a denser schedule (every world, or a much higher FIRST), measure the trial rate on Canvas and the hard corpus against 20261012-4's numbers (0.92x and 1.13x; target no worse than about 0.85x), and add an across-literals family with a `<> k` atom over OFFSET 0 at production-like trial counts. Also q15a on Canvas swings between 0 and 5 of 5 atoms untested from run to run, since the search rarely gets a row for it: check whether a denser schedule settles it.

- **Depends on:** None.
- **Came from:** The second review of 20261012-4, 2026-10-14 (minor).
- **Design:** rewrite-test (coverage).
- **Status:** todo

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

### 20261015-1. TestPostgres.extra_server: a failed cleanup masks the readiness error.

From the second review of 20261008-60 (minor). `ExtraServer.start` (`spec/support/test_postgres.rb`) removes the container when the server never gets ready, then re-raises. If `remove_container` itself raises (Docker unavailable, permission denied), that error replaces the readiness failure. Keep the original error: attempt removal in its own rescue, and re-raise the readiness error either way. Test first: readiness and removal both raise, and the readiness error is the one reported.

- **Depends on:** None.
- **Came from:** The second review of 20261008-60, 2026-10-15 (minor).
- **Design:** Development (test Postgres).
- **Status:** todo

### 20261015-3. Tablespace moves: a non-ASCII table name refuses the whole report.

From the first review of 20261010-17 (minor). `Placement.moves` uses Postgres's `quote_ident`, which can emit a quoted non-ASCII identifier such as `public."café"`, but `Protocol::TablespaceMoves` allows printable ASCII only, so Egress refuses the report instead of carrying the warning. Accept valid UTF-8 quoted identifiers, keeping the control-character, length, quoting, membership and count checks. Test first.

- **Depends on:** None.
- **Came from:** The first review of 20261010-17, 2026-10-15 (minor).
- **Design:** What goes into the enclave, report.
- **Status:** todo

### 20261015-4. Result-comparison on the racetrack doesn't check inner cuts or picks.

From the build of 20261008-67. `ProductionComparison` (result-comparison on production data) runs neither `InnerCuts` (a LIMIT or OFFSET below the top level) nor `Picks` (a DISTINCT ON without a full order, an aggregate that follows its input order, a DISTINCT or set operation that keeps one of several equal values), which fixture-compare now has. A candidate whose inner pick goes another way can match there by luck, and a good one can fail against an original whose own pick decides its answer. Decide whether production gets the same checks (each forced run re-reads production rows, so it costs a full query run per direction), and test first.

- **Depends on:** None.
- **Came from:** The build of 20261008-67, 2026-10-15.
- **Design:** result comparison, fixture-compare.
- **Status:** todo

### 20261015-5. Fixture-compare: window functions over tied rows pick arbitrarily.

From the build of 20261008-67. `Picks` forces a DISTINCT ON, an aggregate that follows its input order, and a deduplicating DISTINCT or set operation, but not a window function whose frame or `ORDER BY` ties, such as `row_number() OVER (PARTITION BY grp ORDER BY created_at)` over equal timestamps, `first_value`, `lag`, or `array_agg(...) OVER (...)`, nor a SQL/JSON `JSON_ARRAYAGG`, an `ARRAY(SELECT ...)` with no `ORDER BY`, or a `GROUP BY` key under a nondeterministic collation (either of `'a'` and `'A'`). A candidate that drops a window's tiebreaking key can match the fixture by luck. Force them the same way (append each argument's or output's `::text` to the window's `ORDER BY`), or refuse; test first with a realistic dedupe-by-`row_number()` query.

- **Depends on:** None.
- **Came from:** The build of 20261008-67, 2026-10-15.
- **Design:** fixture-compare.
- **Status:** todo

### 20261015-6. Pick checks: a NULL beside one value makes `any_value` refuse.

From the second review of 20261008-67 (minor). `ResultComparison::PickChecks` (`result_comparison/pick_checks.rb`) lists every argument row of an `any_value`, NULLs included, but `any_value` ignores NULL inputs, so `any_value(v)` over `{NULL, 'x'}` has no real choice yet the check fires and the comparison refuses with `unsupported_order`. Leave NULL arguments out of `any_value`'s check, test first with one value plus NULLs, and mutation-test it. Also note in DESIGN.md that a query with picks runs about 5x slower in fuzz (about 156 against 750 trials/s), since it skips the cheap match.

- **Depends on:** None.
- **Came from:** The second review of 20261008-67, 2026-10-15 (minor).
- **Design:** fixture-compare, result comparison.
- **Status:** todo

### 20261016-16. Winner summary guard: capitalised one-word step names mid-sentence.

From the review of 20261016-13. The guard still counts a capitalised one-word step type mid-sentence as a plan step, so "The rewrite can Hash the smaller input" or "Group by tenant" is refused when neither plan has that step. That's rare in replies (SQL's `GROUP BY` in capitals doesn't match), but a good answer could be refused. Consider counting a one-word type only when the words around it mark it as a step, such as "a Hash step" or "the Group node".

- **Depends on:** None.
- **Came from:** Review of 20261016-13, 2026-10-16.
- **Design:** LLM prompts.
- **Status:** todo

### 20261016-17. Spec flake: the trigger-refuses-every-row fuzz example gets `no_world` under load.

From the build of 20261016-14. In one per-commit run, `enclave/spec/counterexample_steps_postgres_spec.rb`'s "passes, cautioning every atom, when a trigger refuses every row, without the database's message" got `"rule" => "no_world"` with `"trials" => 0, "worlds" => 0` instead of `"rule" => nil`, while all four suites ran at once. It passed on its own four times in a row, and the build didn't touch fuzz or rewrite-test. It looks like the search's time budget running out before it tries the empty world when the machine is busy. Find why a loaded machine can end the search with no world tried, and make the example (or the search's floor) independent of machine speed, as `QUAACKS_FUZZ_TRIALS` is meant to.

- **Depends on:** None.
- **Came from:** Build of 20261016-14, 2026-10-16.
- **Design:** rewrite-test.
- **Status:** todo

### 20261017-1. Selection: break footprint ties within each kind, among candidates that passed result comparison.

Minimax's footprint tiebreaker (`Minimax.discarded`) runs over every survivor of every kind, before Selection groups them by kind. So a rewrite with a small index can knock out every "original query with new indices" candidate within 5% of it, and that whole class goes missing from the ranking, though the report says the three best of each class are kept. It also runs before Selection drops candidates whose rewrite failed result comparison, so a wrong rewrite can still knock out a right one. Break ties only within one kind (`Protocol::CandidateKinds`), and only among candidates whose rewrite result comparison kept. Update DESIGN.md's minimax and selection sections.

- **Depends on:** None.
- **Came from:** The user, 2026-10-17, from a real run where the "original with new indices" class came out empty.
- **Design:** minimax, selection.
- **Status:** todo

### 20261017-2. Measure each candidate with the indices that made the ranking for other candidates.

Each candidate is measured only with the indices proposed for it: the original's own index search, or its rewrite's (rewrite-index-ideas). So a good index the LLM proposed for one candidate is never tried with another candidate on the same table, and the best pairing depends on the LLM proposing the same index twice. In a real run, a small partial index that read about half the original's blocks with a rewrite in one run was proposed in the next run only for a different rewrite, and the better pairing was never measured. After each candidate's own index search, also measure each candidate with every index that made the ranking for some other candidate (kept by index-rank or rewrite-index-rerank) and is on a table the candidate reads. Keep the extra runs bounded, and say in the report where a candidate's indices came from ("from another candidate"). Update DESIGN.md.

- **Depends on:** None.
- **Came from:** The user, 2026-10-17.
- **Design:** rewrite-index-ideas, index-rank, measurement.
- **Status:** todo
