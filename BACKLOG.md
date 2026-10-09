# QUAACK backlog.

This is the working backlog for QUAACK. It breaks DESIGN.md into tasks we can pick up one at a time.

## Unreleased enclave changes.

Enclave or protocol changes on `main` since the last version bump (see CLAUDE.md). While this list isn't empty, don't deploy from `main`.

- 20261009-23: suggested drops see varchar partial indexes.















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

### 20261002-16. `distinct_join_to_exists`: handle what Rails sends. Done, see BACKLOG-COMPLETE.md.

### 20261002-6. 6c rule: `shared_scan_cte`. Done, see BACKLOG-COMPLETE.md.

### 20261002-4. `distinct_join_to_exists`: minor findings. Done, see BACKLOG-COMPLETE.md.

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

### 20260926-55. Keyset and expression-unique leftovers. Dropped, see BACKLOG-COMPLETE.md.

### 20260926-59. Keyset tie rows are dropped on realistic schemas. Done, see BACKLOG-COMPLETE.md.


### 20260927-17. Covering-check and volatility-list gaps. Done, see BACKLOG-COMPLETE.md.

### 20260927-28. Parser note loose ends, and the Postgres 18 upgrade. Done, see BACKLOG-COMPLETE.md.

### 20261001-5. An LLM error reads the reason out of a JSON array body. Done, see BACKLOG-COMPLETE.md.

### 20261001-10. The full schema dump finds the schemas its objects reference, and takes overrides. Done, see BACKLOG-COMPLETE.md.

### 20261003-7. Intake unreadable causes: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261003-3. Report payload: minor findings. Done, see BACKLOG-COMPLETE.md.

### 20261003-5. Report payload: what the index accountability table still lacks. Done, see BACKLOG-COMPLETE.md.

### 20261003-18. A scenario refusal shouldn't end the run. Done, see BACKLOG-COMPLETE.md.

### 20261003-19. Name the tables in an `fk_cycle` refusal. Done, see BACKLOG-COMPLETE.md.

### 20261003-23. Step 9: break a cycle when the query joins on its nullable edge. Done, see BACKLOG-COMPLETE.md.

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
- **Note (2026-10-07):** the nondeterministic-collation key with a `COLLATE "C"` index is covered by 20261002-4's shared unique check (`assumption_check/index_equality.rb`).
- **Status:** todo

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

### 20261004-6. Pin the type part of rewrite-test's probe cache key.

`ValuePools::Probe#key` is `[sql, oid, format_type]` (`value_pools.rb:200`). If it drops the type, entries are shared wrongly across types and fixtures change, yet every committed spec still passes. Add a spec where the same CHECK sits on columns of different types, for example `integer` and `numeric`, or `varchar(8)` and `varchar(255)`. Assert each fixture's value, and confirm the spec goes red when the key drops `oid` and the type.

- **Depends on:** 20261004-2.
- **Came from:** The review of 20261004-2.
- **Design:** rewrite-test.
- **Status:** todo

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
- **Status:** todo (item 1 needs the user)

### 20261004-51. Report: explain the untested-conditions note under a rewrite, and render its conditions readably. Done, see BACKLOG-COMPLETE.md.

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

### 20261004-77. Index burndown loose ends from 20261001-20. Done, see BACKLOG-COMPLETE.md.

### 20261004-80. Indexes table: which source proposed each built index. Done, see BACKLOG-COMPLETE.md.

### 20261004-81. Index refusal rules: keep the list from going stale.

- **Status:** todo
- **Depends on:** 20261004-77 (done)
- **Came from:** the review of 20261004-77.
- **Design:** report, llm-index-ideas.

1. `IndexDdlCheck::RULES` is kept by hand. A new refusal added to `IndexDdlCheck`, `SupportedSql`, `VolatilityCheck` or `Deparse` without updating `RULES` and the samples in `enclave/spec/index_ddl_check_spec.rb` fails nothing, so the cross-gem words spec misses it. Find a way for a new rule to fail a test, such as a spec that scans those files for the rules they raise and compares them with `RULES`.
2. "Planner ignored" in the Indexes table doesn't count index-rank's re-test drops (`never_used`, `hypopg_refused`). That matches the LLM row and DESIGN.md, so it's a choice of definition. Consider saying so in the table's note.

### 20261004-88. ambiguous_user_schema: minors and the operator's own schema. Done, see BACKLOG-COMPLETE.md.

### 20261004-89. Index sources: a test gap and the remaining "not recorded" cells.

From the builder and review of 20261004-80.
1. Removing `!ran.empty? &&` in `IndexSources.not_better` keeps every spec green, yet 5 of 16 recorded replays have a built index no label ran with; without that guard it would count as "not better" by source but not in "All sources together". Add a label-less built index to the producer spec's fixture.
2. In the "Measured, and not ranked" table, "Who proposed it" still says "not recorded" for index candidates.
3. For the generators, "Already existed" and "Planner ignored" still say "not recorded".

- **Depends on:** 20261004-80.
- **Came from:** The builder and review of 20261004-80.
- **Design:** report, burndown.
- **Landed so far:** item 1, 2026-10-08 (task/20261004-89, commit 835eb325; review clean). Items 2 and 3 wait on a user decision, since DESIGN.md keeps both cells "not recorded" on purpose. Item 2 would add a `sources` list to each `indexes` entry in the payload, checked on the way out, and the user would also choose what the cell says for a rewrite with new indexes. Item 3 would record index-dedupe's and index-test's drops by generator in the burndown, which changes its shape.
- **Status:** todo

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

### 20261006-2. Structured columns: minors from 20261004-91.

From the builder and review of 20261004-91.
1. The classify-level tests for xml, tsvector, range and multirange columns (`pii_classification_postgres_spec.rb` ~380-418) stay green when those types are dropped from the list, since ANALYZE gives them no positive `n_distinct`. Only `planner_statistics_postgres_spec.rb` (~131) catches it. Rename the tests to say what they show, or make them bite.
2. Done in 20261006-3. `planner_statistics/catalog.rb` (~47-49) compares an `oid` with `regtype` values using a bare `=`. A planted `public.=` operator on (oid, regtype) turns json, jsonb and xml columns non-structured. Use `OPERATOR(pg_catalog.=)` or cast to `pg_catalog.oid`. Related: 20260930-13, 20260930-14.
3. The trust-boundary test's comment (`pii_classification_postgres_spec.rb` ~222-226) doesn't mention the json sentinel in `customers.preferences`.
4. tsvector lexemes and array elements go to `most_common_elems`, which statistics doesn't read today. If it ever does, apply the same rule there.

- **Depends on:** 20261004-91.
- **Came from:** The builder and review of 20261004-91.
- **Design:** classify, statistics, trust boundary.
- **Status:** todo

### 20261006-3. Classify: bytea, geometric and other non-text types can still send MCV values. Done, see BACKLOG-COMPLETE.md.

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

### 20261006-10. Stats trimming: minor findings from 20261001-7. Done, see BACKLOG-COMPLETE.md.

### 20261006-17. Clock binding: overloaded user functions. Done, see BACKLOG-COMPLETE.md.

### 20261006-27. Clock overloads: minors from 20261006-17.

From the review of 20261006-17 (`enclave/lib/quaack/enclave/insert_clock_words.rb`).
1. A target whose candidates mix a pseudo type and a date type, such as `f(anyelement)` beside `f(date)`, now counts as disagreeing. Its `$n` is refused where it used to be anchored. That's conservative and rare, so revisit it only if someone hits it.
2. The comment at ~198 says "one target's types disagree", but `oids` drops pseudo types before counting. Fix the wording.

- **Depends on:** 20261006-17.
- **Came from:** The review of 20261006-17.
- **Design:** counterexamples inserts, clock anchoring.
- **Status:** todo

### 20261006-28. Stats trimming: join aliases with column lists, and a boundary test.

From the review of 20261006-10 (`enclave/lib/quaack/enclave/stats_payload.rb`).
1. `renames` (~116-123) reads only `range_var` aliases, so a join alias's column list is ignored. For `SELECT j.x FROM (orders o JOIN customers c ON o.customer_id = c.id) j(x)`, the subset drops `orders.id`, the column `j.x` renames. This SQL is rare. Keep every column of the tables under any join alias that has a column list.
2. Changing the length guard (~61) from `>` to `>=` leaves every test green. Add a test with a list exactly as long as the table's columns.

- **Depends on:** 20261006-10.
- **Came from:** The review of 20261006-10.
- **Design:** llm-index-ideas, llm-rewrites.
- **Status:** todo

### 20261007-21. Qualify functions and operators that several schemas define (full version of 20260926-56's qualification). Done, see BACKLOG-COMPLETE.md.

### 20261007-38. `not_in_to_not_exists`: extensions. Done, see BACKLOG-COMPLETE.md.

### 20261007-47. `or_to_union`: extensions. Done, see BACKLOG-COMPLETE.md.

### 20261007-51. Equality: refuse a half-exact `=` too. Done, see BACKLOG-COMPLETE.md.

### 20261007-58. Equality: planted operators on domains and same-signature shadows.

From the review of 20261007-51. Neither is new in that task.
1. A planted `=` on a domain type (`=(email, email)` for a domain over text) is matched exactly by Postgres before domains are reduced, so it wins, while `Equality` compares base types and returns `OPERATOR(pg_catalog.=)`. Run the exact check against the unreduced domain types too, or list it as unsupported in v1; DESIGN.md's "a domain counting as its base type" hides the case.
2. A same-signature `=` in another schema (`public.=(text, text)` with `public` listed before `pg_catalog` on the path) wins over pg_catalog's, for any type whose family `=` is exact on both sides. Refuse it, or document it as unsupported.
3. A one-side-exact `=` the columns can't be cast to (`=(mood, int4)`) isn't a Postgres candidate but still refuses. Only costs a refusal; tighten the wording or the rule.

- **Depends on:** 20261007-51.
- **Came from:** The review of 20261007-51.
- **Design:** trust boundary, assumption checks.
- **Status:** todo

### 20261007-64. Intake unreadable reasons: new causes, and one shared list.

The two items 20261003-7 left, since each changes enclave or protocol behavior and goes in a batch.
1. Give `EIO`, `ENAMETOOLONG`, and `IOError` their own unreadable reasons in the enclave (`ErrorFilter::UNREADABLE_REASONS`), with the driver's `ErrorFields::REASONS` and `EnclaveError#reason_message` updated to match.
2. Move the reason list into the protocol gem so the enclave and the driver share one copy; `EnclaveError#reason_message` still repeats the keys in its hash. Under the batching rule this lands with the next version bump, so a jump server never runs a protocol gem without the constant.

- **Depends on:** 20261003-7.
- **Came from:** The builder of 20261003-7, 2026-10-08.
- **Design:** intake, trust boundary.
- **Status:** todo

### 20261008-4. `not_in_to_not_exists`: support `NOT IN` outside the top-level WHERE.

One of 20261007-38's extensions, each its own task by the user's decision (2026-10-08). Extend `not_in_to_not_exists` to `NOT IN` outside the top-level WHERE (in a JOIN ON, a HAVING, or a nested subquery). A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-38.
- **Came from:** The split of 20261007-38, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-5. `not_in_to_not_exists`: support `<> ALL`.

One of 20261007-38's extensions, each its own task by the user's decision (2026-10-08). Extend `not_in_to_not_exists` to `<> ALL (SELECT ...)`, which means the same as `NOT IN`. A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-38.
- **Came from:** The split of 20261007-38, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-7. `or_to_union`: support a query with GROUP BY.

One of 20261007-47's extensions, each its own task by the user's decision (2026-10-08). Extend `or_to_union` to a query with GROUP BY. A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-47.
- **Came from:** The split of 20261007-47, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-8. `or_to_union`: support outer joins.

One of 20261007-47's extensions, each its own task by the user's decision (2026-10-08). Extend `or_to_union` to outer joins. A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-47.
- **Came from:** The split of 20261007-47, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-9. `or_to_union`: support a bare `*` in the select list.

One of 20261007-47's extensions, each its own task by the user's decision (2026-10-08). Extend `or_to_union` to a bare `*` in the select list. A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-47.
- **Came from:** The split of 20261007-47, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** todo

### 20261008-18. `or_to_union` composite keys: minors from 20261008-6. Done, see BACKLOG-COMPLETE.md.

### 20261008-20. `not_in_to_not_exists` over a UNION: minors from 20261008-3. Done, see BACKLOG-COMPLETE.md.

### 20261008-21. index-from-plan: `(InitPlan 1).col1` conditions and COLLATE filters.

Split from 20260923-24, whose builder found both larger than a loose end:

1. **`(InitPlan 1).col1` conditions are dropped whole, because pg_query can't parse them.** A fix would rewrite those tokens as a parameter before parsing. It should use pg_query's scanner, so a match inside a string literal is left alone.
2. **COLLATE filters propose nothing.** A plain key would be a wasted candidate, since Postgres uses a btree for the comparison only when the index's collation matches the query's. A real fix needs two things: collation-aware key columns from the plan, and a decision on how a `COLLATE` predicate passes through index-dedupe.

- **Depends on:** 20260923-24.
- **Came from:** The builder of 20260923-24, 2026-10-08.
- **Design:** index-from-plan.
- **Status:** todo

### 20261008-22. Live EXPLAIN JSON parses with JSON's default nesting limit.

From the builder of 20260923-24. `enclave/lib/quaack/enclave/index_build.rb:144` and `measurement.rb:68` parse live EXPLAIN JSON with JSON's default `max_nesting` of 100. A plan more than about 49 nodes deep raises `JSON::NestingError` there. `SingleCandidateTest#parse_plan` handles the same case with `max_nesting: false`. Pick a limit that matches the store's (`PlainData::MAX_DEPTH`), and test it with a deep plan from real Postgres.

- **Depends on:** none.
- **Came from:** The builder of 20260923-24, 2026-10-08.
- **Design:** index-test and the baseline.
- **Status:** todo

### 20261008-23. index-from-plan booleans and MCV coverage: minors from 20260923-24.

The review of 20260923-24 found these minor issues:

1. **The rarest boolean flags lose their partial.** If ANALYZE never samples the rare value, pg_stats shows `deleted` as `{f}` at 1.0, and `WHERE deleted` gets no partial, though that's the best case for one. The coverage rule is there for values written another way, and booleans can't be, since `boolean_text` maps them. Consider exempting booleans from the rule.
2. **No test covers the case the rule exists for.** Nothing checks that `n = 1.5` on a numeric that pg_stats prints as `1.50` gets no partial.
3. **An existing index may not count as covering a candidate.** pg_indexes keeps an existing `WHERE (deleted = true)` as written. Unless index-dedupe normalizes `b = true` to `b`, a matching `WHERE deleted` candidate is tested as new. Check this, and fix it in index-dedupe if needed (see 20260923-36).

- **Depends on:** 20260923-24.
- **Came from:** The review of 20260923-24, 2026-10-08.
- **Design:** index-from-plan.
- **Item 3 done:** 20260923-36 added `BooleanFold`, so an existing `WHERE (deleted = true)` now covers `WHERE deleted`. Items 1 and 2 are still open.
- **Status:** todo

### 20261008-24. index-from-query: incremental sort, derived-table reduction, and whole-row reads.

The builder of 20260923-21 left these items out:

1. **Incremental sort isn't handled.** This one is large.
2. **INCLUDE beyond the select list and GROUP BY.** DESIGN.md step 5 limits INCLUDE to those two on purpose, so changing it is a design question for the user.
3. **No join reduction through derived-table columns.** In `o LEFT JOIN (subquery) s ... WHERE s.x = 1`, the strict WHERE on the subquery's column doesn't reduce the join, because subquery columns aren't tracked.
4. **Whole-row references.** `SELECT o FROM public.orders o` isn't counted as reading every column, so an INCLUDE could look covering when it isn't.

- **Depends on:** 20260923-21.
- **Came from:** The builder of 20260923-21, 2026-10-08.
- **Design:** index-from-query.
- **Status:** todo

### 20261008-25. index-from-query join reduction and pattern keys: minors from 20260923-21.

The review of 20260923-21 found these minor issues:

1. **`IS DISTINCT FROM` has no test.** Adding `AEXPR_DISTINCT` to `Strict::KINDS` keeps every test green. Add it to the "isn't plainly strict" test.
2. **A column under COLLATE has no test.** Dropping the `collate_clause` arm of `Strict.bare` keeps every test green.
3. **The pattern key's opclass is wrong for `char(n)`.** A prefix LIKE on a `char(n)` column gets a `text_pattern_ops` key, which HypoPG refuses. The column needs `bpchar_pattern_ops`. The refusal is recorded and costs only a wasted candidate, but the useful key is missed.
4. **The skip rule and its docs don't match.**
   - Under `COLLATE "ucs_basic"`, a prefix LIKE still gets a `text_pattern_ops` key, though a plain btree already serves it.
   - DESIGN.md says the extra key is skipped only under `COLLATE "C"`, but the code also skips it under POSIX.

- **Depends on:** 20260923-21.
- **Came from:** The review of 20260923-21, 2026-10-08.
- **Design:** index-from-query.
- **Status:** todo

### 20261008-26. NATURAL JOIN marker: minors from 20260923-30.

The review of 20260923-30 found these minor issues:

1. **DESIGN.md doesn't say what a NATURAL JOIN leaves untested.** It never ties its shared columns, so the query's other atoms can come out untested too: in the spec's query, `o.status = $1` stays untested after three retries that can't succeed. Add a line to "Also unsupported in v1", around line 1151.
2. **The counterexample prompt asks for something no reply can give.** It asks the LLM to exercise every untested atom, but a "NATURAL JOIN" marker, like a USING one, can never be covered. Consider leaving unreplaceable markers out of that list.
3. **The new vacuity-guard spec is loose.** It checks the marker only with `include`. Also assert that the marker shows up exactly once and gets no retry.

- **Depends on:** 20260923-30.
- **Came from:** The review of 20260923-30, 2026-10-08.
- **Design:** vacuity-guard.
- **Status:** todo

### 20261008-28. Boolean folding in index-dedupe: minors from 20260923-36.

The review of 20260923-36 found these minor issues:

1. **`BooleanFold` folds only once, so it isn't idempotent.** `(f = true) = true` becomes `f = true`, and only a second normalization, after an `IndexStore` round trip, takes it to `f`. Fold until nothing changes.
2. **A double NOT isn't collapsed.** `NOT (f = false)` folds to `NOT NOT f`, not to `f`. Postgres prints an existing index as `WHERE (NOT (f = false))`, and the planner uses it for `WHERE f`, so a matching candidate is tested as new. Collapse double NOT.
3. **One guard has no test.** The `expr.name.size == 1` guard in `BooleanFold.operator` can be replaced with `true` and every test stays green. Either drop it or add a test with `OPERATOR(pg_catalog.=)`.

- **Depends on:** 20260923-36.
- **Came from:** The review of 20260923-36, 2026-10-08.
- **Design:** index-dedupe.
- **Status:** todo

### 20261008-29. Rewrite candidate relation check: minors from 20260923-57.

The first review of 20260923-57 found these minor issues:

1. **A descendant's kind leaks when ONLY is dropped.** Say the original reads `ONLY public.parent_s` and a candidate drops the ONLY. The candidate is refused with the descendant's own rule, such as `foreign_relation` for a foreign-table inheritance child, so the LLM learns the kind of a child it never saw. Only the rule leaves the enclave, not the child's name. Use one rule for every descendant refusal.
2. **The newly inherited rules have no candidate-level tests.** `rewrite_candidate_check_spec.rb` doesn't test the inheritance-descendant check (ONLY dropped) or `ambiguous_user_schema`. `relations_spec.rb` covers their logic.
3. **`user_function_in_from` runs before the allowed check.** It reveals nothing about relations, since it only says whether a FROM function is pg_catalog's, but it should run after the allowed check, for consistency.

- **Depends on:** 20260923-57.
- **Came from:** The first review of 20260923-57, 2026-10-08.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261008-30. Production inventory: minors from 20260924-24, and silent packet drops.

The build and review of 20260924-24 found these:

1. **The final drain isn't tested.** No test pins `ShellCommand`'s drain after the shell exits. A mutant that returns as soon as the status shows an exit, before the final drain, survives every spec. It would only lose output when the shell writes and exits between a drain and the next status check. A test that delays `Process.wait2` at the edge would pin it.
2. **DESIGN.md overstates schema-dump's timeout.** It says schema-dump "gets the same timeout". Only its catalog walk inside `read_only` does. Its `pg_dump` child has only `lock_wait_timeout`, so a silently dropping host can still hang it. Reword this, and consider a time limit on the pg_dump child.
3. **DESIGN.md names `null` only for `memory_command`.** A null `run_server_command`, `destroy_command`, or `pii_columns` is `bad_config` too. Say so in the run-server and teardown sections.
4. **Silent packet drops can still hang the production connection.** A server-side `statement_timeout` doesn't fully cover a host that silently drops packets, because the error reply can be lost too, and libpq keeps waiting. Client-side TCP keepalives or `tcp_user_timeout` on the production connection would cover it. This came from the builder.

- **Depends on:** 20260924-24.
- **Came from:** The builder and review of 20260924-24, 2026-10-08.
- **Design:** inventory.
- **Status:** todo

### 20261008-31. Rewrite candidates: a regclass literal reveals that a relation exists. Done, see BACKLOG-COMPLETE.md.

### 20261008-32. Rewrite candidates: whether a function, type, collation, or operator exists is visible. Done, see BACKLOG-COMPLETE.md.

### 20261008-33. Load orders: minors from 20260924-9, and skipping a redundant rotated run.

The review of 20260924-9 found these:

1. **No spec checks that `self_references` leaves out keys to other tables.** Deleting `AND con.confrelid OPERATOR(pg_catalog.=) con.conrelid` from `SelfReferences::SQL` keeps every spec green. That isn't unsound, but it would quietly weaken the reverse and rotated orders. Add an assertion on `runner.self_references` for a table that has both a self-reference and a reference to another table.
2. **Three cases have no spec.** Add tests for a composite self-referencing key, a NULL parent key, and a self-referencing table that shows up in more than one run. The review's probes passed for all three, so this is coverage only.
3. **Cost.** The rotated order adds about 45% to the joins spec. When every run and every level has two rows or fewer, the rotated order is the same as reverse, and with one row it's the same as forward. Skip the rotated load when its order matches one already run.

- **Depends on:** 20260924-9.
- **Came from:** The review of 20260924-9, 2026-10-08.
- **Design:** fixture-compare.
- **Status:** todo

### 20261008-34. Statistics a non-owner production role can't see: extended statistics, expression indexes, and row security. Done, see BACKLOG-COMPLETE.md.

### 20261008-35. Reg literals in candidates: minors from 20261008-31.

The first review of 20261008-31 found these minor issues:

1. **The driver's note for `unsupported_reg_literal` misdescribes a refused candidate.** The note in `FixedNotes` says "The query has a regproc, regprocedure, regoper, or regoperator constant ... can't tune this query." For a refused rewrite candidate, that's wrong. Check whether candidate refusals ever reach that note. If they do, give the candidate case its own rule or words.
2. **Index DDL predicates weren't checked for the same reg-literal leak.** Check whether an LLM-proposed index predicate, such as `WHERE x = 'hid.t'::regclass`, or its planning, can reveal that a relation exists.

- **Depends on:** 20261008-31.
- **Came from:** The first review of 20261008-31, 2026-10-08.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261008-36. Cast placeholders in literals: minors from 20260924-28.

The review of 20260924-28 found these minor issues:

1. **Older entries.** No test covers a statistics entry stored before `column_types` existed.
2. **DateStyle.** A picked date or timestamp value goes through its cast as text, in the DateStyle that was active when statistics read it. A replay session with another DateStyle could misread the value or fail to bind it. Pin the DateStyle, for example to ISO, wherever the statistics are read and replayed.
3. **Shadowed type names.** A bare cast like `$1::timestamptz` matches the pg_catalog type by name only, so a type of the same name earlier on the search_path would match too. The worst case is a bind error, not a leak.

- **Depends on:** 20260924-28.
- **Came from:** The review of 20260924-28, 2026-10-08.
- **Design:** literals.
- **Status:** todo

### 20261008-37. Plan table check: RLS policies that read other tables.

The review of 20260924-3 found this. A table whose RLS policy queries another table, such as a membership lookup for multi-tenancy, gets that table's scan added to the plan, so qualify refuses it as `plan_table_mismatch`. That refusal is wrong. List RLS policies that reference other tables as unsupported in v1 in DESIGN.md, or refuse them earlier with a clearer rule.

- **Depends on:** 20260924-3.
- **Came from:** The review of 20260924-3, 2026-10-08.
- **Design:** input.
- **Status:** todo

### 20261008-38. Tablespace check: narrow it to the query's tables.

The review of 20260924-29 found these:

1. **The check covers more than the query needs.** Inventory records every tablespace any relation uses, so `run_server_tablespace_mismatch` can refuse over a tablespace none of the query's tables use. Two realistic cases hit this: a run server restored with `pg_dump --no-tablespaces`, and an RDS production with a custom tablespace that holds only unrelated tables. Record each relation's tablespace, and check only the query's tables and their indexes, after qualify.
2. **The operator can't tell which tablespace failed.** The fixed note doesn't say, by design. Have it say how to compare `pg_tablespace` on both servers.
3. **The missing-tablespace path has no mutation coverage.** Add a test where a tablespace is missing by name.

- **Depends on:** 20260924-29.
- **Came from:** The review of 20260924-29, 2026-10-08.
- **Design:** inventory and run-server.
- **Status:** todo

### 20261008-39. Reg-literal check: "any" arguments and OID probes, from 20261008-31.

The second review of 20261008-31 found these:

1. **"any" arguments are over-refused.** `untyped_literal` refuses calls whose arguments have type "any", such as `concat('a', name)` and `json_build_object('a', id)`, because a literal turned into an untyped `$k` has no type Postgres can work out. `json_build_object` turns up in real rewrites. Bind such arguments as text.
2. **OID probes.** `WHERE pg_get_indexdef(16384) IS NULL` is accepted, and the fixture-compare verdict can show whether an object with that OID exists. The same goes for `pg_get_viewdef(oid)`, `pg_get_constraintdef`, and similar functions. This reveals an OID's existence, not a guessed name. Consider adding the OID-taking catalog functions to the deny-list.

- **Depends on:** 20261008-31.
- **Came from:** The second review of 20261008-31, 2026-10-08.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261008-41. Candidate name lockdown: keyword operators and the failure for a pinned name.

The review of 20261008-32 found these minor issues:

1. **Keyword operators can resolve to a user overload.** `LIKE`, `IN`, `IS DISTINCT FROM`, and `NULLIF` stay unpinned and resolve through the search path. A user overload in a role-named schema could be picked, or its existence shown. Pin them, for example by rewriting `x LIKE y` to `x OPERATOR(pg_catalog.~~) y`, or list them as unsupported in v1 in DESIGN.md.
2. **A pinned name that doesn't exist gives a vague failure.** It fails later as `failed_to_plan`, not with a clean refusal. That doesn't leak, but the failure is less clear than it could be.

3. **Kind separation isn't tested, from the second review.** The `k == kind` match in `Names` has no test. Removing it keeps every test green. Add a test where the original uses the type `public.hstore` and the candidate calls a bare `hstore(...)`.
4. **The fix test uses stand-ins.** It could use real pg_trgm `similarity()` and `%`, since the test image has the extension.

- **Depends on:** 20261008-32.
- **Came from:** The review of 20261008-32, 2026-10-08.
- **Design:** What goes into the enclave.
- **Status:** todo

### 20261008-42. Hidden statistics: minors from 20261008-34.

The review of 20261008-34 found these minor issues:

1. **The empty-columns guard in `Hidden.check_row_security!` is untested.** Turning `return unless entry["columns"].empty?` into a no-op leaves every test green. Test it or remove it.
2. **Egress checks only the shape of the hidden indexes.** It never checks that each name in `hidden_statistics.indexes` is a stored index. Only `Steps::HiddenStatistics` enforces that. Add the membership check at egress too, the way it should be done for `ExistingIndexes`.

- **Depends on:** 20261008-34.
- **Came from:** The review of 20261008-34, 2026-10-08.
- **Design:** statistics, report.
- **Status:** todo

### 20261008-43. Error-detail scrub misses keys that encode unreserved characters.

The review of 20261001-5 found this gap. It was already on main. `APIErrorDetail`'s `char_pattern` never treats `A-Za-z0-9_.~-` as encodable, so a key echoed with one of those characters percent-encoded, such as `sk%2D...`, passes through unscrubbed. Now that the JSON fallback lets more of the raw body into the detail, the gap has a little more exposure. Match `%XX` for every character of a secret, and add a sentinel test.

- **Depends on:** 20261001-5.
- **Came from:** The review of 20261001-5, 2026-10-08.
- **Design:** LLM client.
- **Status:** todo

### 20261008-44. Qualifying overloaded names: keyword forms (part 2 of 20261007-21).

Split from 20261007-21. IN, BETWEEN and NOT BETWEEN, LIKE and ILIKE, IS DISTINCT FROM, NULLIF, simple CASE, and USING and NATURAL joins have no qualified spelling. When several schemas on the path define the operator they use, rewrite each one into an equivalent explicit form that can be qualified, or refuse it cleanly, and list it as unsupported in v1. See also 20261008-41 item 1.

- **Depends on:** 20261007-21.
- **Came from:** The split of 20261007-21, 2026-10-08.
- **Design:** qualify.
- **Status:** todo

### 20261008-45. Qualifying overloaded names: reg literals (part 3 of 20261007-21).

Split from 20261007-21. `regproc`, `regprocedure`, `regoper`, and `regoperator` literals in the original are still refused as `unsupported_reg_literal`. Resolve and qualify them, or keep refusing them, and document the choice.

- **Depends on:** 20261007-21.
- **Came from:** The split of 20261007-21, 2026-10-08.
- **Design:** qualify.
- **Status:** todo

### 20261008-46. Probing to qualify overloaded names: minors from 20261007-21 part 1.

The review of 20261007-21 part 1 found these minor issues:

1. **Constant folding can name the wrong winning schema.** With GENERIC_PLAN, two overloads that fold to the same constant give the same plan. The outcome is harmless, since the plan is the same, but the chosen schema can be the wrong one in name.
2. **Planning runs user code on production.** It evaluates immutable functions on constants, and the probes can evaluate overloads the real query never calls. A read-only transaction stops writes, but not side effects outside the database, such as dblink. Document this in DESIGN.md as a known risk.
3. **No test covers a probe that errors.** Nothing tests a probe that errors while the baseline plans, or the error-swallowing in general.

- **Depends on:** 20261007-21.
- **Came from:** The review of 20261007-21 part 1, 2026-10-08.
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

### 20261009-23. Suggested drops miss partial indexes on varchar columns. Done, see BACKLOG-COMPLETE.md.
