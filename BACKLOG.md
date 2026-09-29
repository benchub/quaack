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

Minor findings from the reviews of 20260922-30:
- **Missed `IS NULL` candidates after join reduction.** 5a-1 decides nullability from the syntax alone. Once a strict counted conjunct on a table rejects its nulls, Postgres turns the outer join inner, or turns FULL into LEFT or RIGHT. Then an `IS NULL` on that table is pushed down too, but 5a-1 still skips it. HypoPG examples: `c LEFT JOIN o ... WHERE o.region = 3 AND o.note IS NULL` misses `orders(note, region)` (cost 67 against 4440), and the FULL JOIN version misses the same index. `IS NOT NULL` counts as strict here too. Count an `IS NULL` on a table once a strict counted conjunct on that table rejects its nulls at or above the outer join.
- **ON conjuncts dropped before join reduction.** `Join#keeps?` drops FULL JOIN ON conjuncts that touch one side, and LEFT/RIGHT ON conjuncts that touch only the preserved side. Once a strict WHERE qual reduces the join, Postgres pushes those down. HypoPG examples: `c LEFT JOIN o ON o.customer_id = c.id AND c.region = 5 WHERE o.status = 1` uses `customers(region)`, and a FULL JOIN case uses `orders(customer_id, region, status)` at cost 4.08 against 12.10. This is the same syntax-only family as the IS NULL item above.
- **BRIN on prefix-LIKE columns.** BRIN can't serve LIKE, and HypoPG shows it unused. Restrict BRIN to comparison ranges.
- **Tests to add:** nullability at depth for RIGHT and FULL joins (the mutants `JOIN_RIGHT then left.last(1)` and `JOIN_FULL then left.last(1) + right.last(1)` survive); "USING always counts" for outer joins; "LIKE with ESCAPE doesn't count"; and the error sentinel test should also check `full_message` and the cause.
- **Comment:** "a join to one still counts for the table on the other side" isn't true for an outer join to a derived table. It's harmless, but say so.
- **Alias matching isn't pinned as case-sensitive.** A case-insensitive alias match passes every test, but `SELECT created_at AS "ID" ... ORDER BY id` sorts by the table's `id` in Postgres. Add a test.
- An ORDER BY on a nullable-side table's columns becomes a key, such as `LEFT JOIN o ... ORDER BY o.created_at`. The table can't be the outer side, so the index is wasted.
- `FOR UPDATE OF o` is falsely refused as an unqualified relation.
- `(o).*` isn't recognized as a star, for ordinals or INCLUDE.
- Column alias lists like `AS o(a, b)` aren't modeled.
- `col = NULL` yields a candidate.
- INCLUDE covers only the select list and GROUP BY, so index-only scans are rare.
- A prefix LIKE needs `text_pattern_ops` unless the collation is C.
- Incremental sort isn't handled.

- **Depends on:** 20260923-20.
- **Came from:** Both reviews of 20260922-30, both reviews of 20260923-20, and the 20260922-30 builder's notes.
- **Design:** 5a-1.
- **Landed (2026-09-26):** BRIN only from comparison ranges, `col = NULL` not a constant, and tests for LIKE ESCAPE and alias case. Still open: join reduction for IS NULL and ON conjuncts, RIGHT and FULL nullability tests, the USING test, the error sentinel check, the comment fix, and the ORDER BY, FOR UPDATE OF, `(o).*`, alias list, INCLUDE, `text_pattern_ops` and incremental sort items.
- **Status:** todo

### 20260923-22. MCV statistics loose ends.

Minor findings from the second review of 20260923-19:
- **The boolean guard is only half pinned.** The only negative case is `%w[t f x]`. The mutants `size <= 2`, `include?(most_common_vals.last)`, and `!include?("x")` all survive. Add a two-value non-boolean case such as `%w[1 0]` or `%w[x t]`.
- **A text column with only `t` and `f` as MCVs** maps `true` and `1` onto them. The doc could name `varchar`, `"char"`, and `char(1)`, and say that the harm is limited to literals that match no rows.
- **An invalid-UTF-8 literal on a t/f column** raises `Encoding::CompatibilityError` from `strip`. It doesn't leak.
- **`TableStatistics#finite` quotes a rejected `reltuples`,** unlike `in_range`. Drop the value for consistency.
- **Optional:** add a real-Postgres test that pins `= false` on a nullable boolean to `freq(f)`.

- **Depends on:** 20260923-19.
- **Came from:** Second review of 20260923-19.
- **Design:** 3c.
- **Landed (2026-09-26):** two-value tests, `finite` no longer quoting reltuples, and doc updates. Still open: the invalid-UTF-8 `strip` error and an optional real-Postgres `= false` test.
- **Status:** todo

### 20260923-23. Dedupe repeated ORDER BY columns in 5a-1. Done, see BACKLOG-COMPLETE.md.

### 20260923-24. 5a-2 loose ends.

Findings from the reviews of 20260922-31:
- **Common values spelled differently get a partial (wasted candidates).** When a literal's text doesn't match its `pg_stats` spelling and the MCVs cover the column, `value_frequency` returns 0.0, so a common value looks rare. HypoPG examples: `n = 1.5` on a numeric printed as `1.50` (33% of rows), `c = 'cd'::bpchar` on `char(4)` (90%), and `(i)::numeric = 7.0` on an int column (80%). Give no partial when the column side is cast to another type. Also consider treating a literal that isn't an MCV as unknown when `sum(most_common_freqs) + null_frac` is about 1.
- **Booleans never reach the partial path.** Postgres prints `b = true` as `b` and `b = false` as `(NOT b)`, so a rare-flag partial like `WHERE NOT deleted` is never proposed.
- **Test gaps:**
  - Putting back a blanket `rescue ArgumentError` stays green.
  - `check_analyze` using `any?` survives, since there's no multi-element EXPLAIN array.
  - Sort equality columns from deeper scans aren't tested.
  - Column refs inside function arguments aren't tested.
  - `removed_fraction` for a node that read no rows isn't tested.
  - `PlanNode#inner` as `children.last` survives.
  - "Skips a relation with no statistics" is weak.
- **`(InitPlan 1).col1` conditions** are dropped whole, since pg_query can't parse them.
- **Other:**
  - `COLLATE` filters propose nothing.
  - A 3,000-deep plan raises SystemStackError. The caller's `JSON.parse` fails first at about depth 49 anyway, so whoever parses stored plans should pass `max_nesting: false`.
  - Fix the grammar slip "a Actual Rows".
  - Leave `inner.size == 1`, Merge Append sort keys, the weak INCLUDE and BitmapOr variants, and exposing the private helpers for 20260923-12.

- **Depends on:** 20260922-31.
- **Came from:** Both reviews of 20260922-31.
- **Design:** 5a-2.
- **Landed (2026-09-26):** tests pinning `PlanNode#inner`, the NaN removed fraction, and the multi-statement ANALYZE check. **Needs a decision:** whether to skip a partial when the column side is cast (varchar shows as `(col)::text`), and whether to treat a non-MCV literal as unknown when MCVs plus nulls cover about 1. Still open: boolean partials, InitPlan, COLLATE, deep plans, and the remaining test gaps.
- **Status:** todo

### 20260923-25. Static checker loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-26. Egress loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-27. Qualify relations loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-28. Canonical plan loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-29. Finish predicate atom extraction. Done, see BACKLOG-COMPLETE.md.

### 20260923-30. Predicate atom loose ends.

Findings from both reviews of 20260922-43 that don't block it:
- **pg_query deparse bugs make `with_true` wrong for a whole query.**
  - `IS NOT DISTINCT FROM (a AND b)` loses its parentheses, which changes the meaning.
  - `XMLTABLE ... PASSING CAST(x AS xml)` deparses to invalid SQL.
  - A typed CYCLE mark deparses as `TO '2020-01-01'::date`, which Postgres rejects. That makes `with_true` invalid for every atom in such a query, and the shape doesn't parse either.
  - `xmlexists('//a' PASSING BY REF (x::xml))` loses its parentheses.
  - `(ARRAY(SELECT 1))[1]` deparses as `ARRAY(SELECT 1)[1]`, which is a syntax error.
  - Add a round-trip guard: after deparsing, reparse and compare the tree with the expected one, and raise if they differ. Use every case above as a test.
- **NATURAL JOIN gives no atoms.** When both sides are plain tables, compute the common columns, or at least emit a marker that can't be replaced, so the report counts it.
- **USING atoms can't be replaced.** 9c (20260922-48) has to mark them untested, not skip them silently.
- **Column resolution is conservative.**
  - A merged USING column, `(o).status`, and a LATERAL item that sees later FROM items are left unplaced where Postgres resolves them.
  - It loses precision, but it never places a column wrong.
- **`with_true` on a recursive CTE's stop condition loops forever.** 9a's `statement_timeout` covers it, but 9c should expect it.
- **A simple CASE rewritten as searched** evaluates its argument once per WHEN. That's only a problem when the argument is volatile.
- **Typmods keep their literals,** such as `::foo('x')`. That's the documented choice, but 3g should know.
- **Wire in qualification.** `extract` assumes a qualified query. Its caller should run `RelationQualifier` (20260922-14) first.

- **Depends on:** 20260923-29.
- **Came from:** Both reviews of 20260922-43, the second review of 20260923-29, and the builder's notes.
- **Design:** Step 9 and 9c.
- **Checked (2026-09-26):** the deparse guard and qualification items are already done. **Needs a decision:** NATURAL JOIN atoms (compute the common columns, or emit a marker that can't be replaced). The rest are notes.
- **Status:** todo

### 20260923-31. Finish 5a-3 dedupe and filter. Done, see BACKLOG-COMPLETE.md.

### 20260923-32. Finish the governed store. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-34. Governed store loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-36. 5a-3 loose ends.

Findings from the reviews of 20260922-32 and 20260923-31:
- **Some existing indexes never count as covering.** `IndexCandidate.from_ddl` returns nil for every index on a partitioned table's parent (`ON ONLY`), for any index `WITH (fillfactor=...)` or `WITH (deduplicate_items=off)`, and for unique indexes with `NULLS NOT DISTINCT`. So a candidate identical to one of them is proposed and tested as if it were new, and 15a won't report it as a duplicate. None of these options changes which queries the index can serve.
- **`IndexCandidate` accepts a predicate whose deparse doesn't parse again.** For example, `'x'::mytype(lower('bob'))` is stored as `'x'::mytype()`. Dedupe drops it, but other consumers would raise. `IndexSql.normalize_predicate` should re-parse its output.
- **Array bounds on a cast aren't checked,** as in `status::text[12345] IS NULL`. It's the same class as the integer typmods the user accepted, but the doc comment doesn't say so.
- **Dead or defensive code:** `left = unwrap(node.lexpr)` in `column_comparison?` is redundant, and the `A_Const` check in `plain_type?` can't be reached through Dedupe.
- **DESIGN.md 5a-3 says GIN and GiST,** but HypoPG also refuses SP-GiST, and SP-GiST is set aside too. Say "any method HypoPG can't model."
- **Open question for the user:** the rule drops every partial that uses a column that isn't low-cardinality, including partials with no literal at all, like `WHERE deleted_at IS NULL`. Those carry no PII risk and are common. Should they get an exception?
- **Decided:** Yes. Allow partial indexes whose predicate holds no literal: IS NULL, IS NOT NULL, or a bare boolean column.

- **Depends on:** 20260923-31.
- **Came from:** The reviews of 20260922-32 and 20260923-31, and the builder's notes.
- **Design:** 5a-3.
- **Landed (2026-09-26):** the Decided item (partials with literal-free predicates are allowed; a sentinel test covers it) and DESIGN.md note. Still open: the `from_ddl` nil cases (`ON ONLY`, `WITH (...)`, `NULLS NOT DISTINCT`), `normalize_predicate` re-parsing, the array-bounds doc note, and the dead-code cleanup.
- **Status:** todo

### 20260923-37. Arena runner loose ends.

Minor findings from the second review of 20260922-46:
- **Every 57014 is reported as `statement_timeout`,** including a self-cancel or an operator cancel. Name the rule `statement_canceled`, or document it.
- **A non-StandardError from the block, followed by a failed rollback, loses the primary error.** Changing `rescue Exception` to `rescue StandardError` in `in_transaction` stays green. Add a test that uses an Interrupt.
- **Which error wins changes with check order.** Moving `check_fixture` after `refuse_unless_idle` stays green. It only changes which error wins when bad rows meet a busy connection.
- **pg_query uses the PG17 grammar and the server is PG18,** so PG18-only SQL fails as `statement_unparsable`. That's fail-closed.

- **Depends on:** 20260922-46.
- **Came from:** Second review of 20260922-46.
- **Design:** Step 9.
- **Status:** todo

### 20260923-38. Error filtering loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-39. Finish 5a-4 single-candidate testing. Done, see BACKLOG-COMPLETE.md.

### 20260923-40. Allowlist loose ends.

Minor findings from the reviews of 20260923-33:
- **EXTRACT's field match uses Unicode `downcase`,** so `'weeK'` with a Kelvin sign is kept, and Postgres rejects that field. Use `downcase(:ascii)` and print the field lowercased, so quoted mixed case such as `'EpOcH'` doesn't pass through verbatim.
- **Tests don't pin `EXTRACT_FIELDS`.** Removing a name only over-redacts, but nothing pins the list.
- **Two doc-comment lines in `generator_one.rb` run long.**
- **Keyset pagination question:** answered by 20260924-31, which supports row comparisons in v1.

- **Depends on:** 20260923-33.
- **Came from:** The reviews of 20260923-33.
- **Design:** Step 1.
- **Status:** todo

### 20260923-53. Finish the enclave CLI. Done, see BACKLOG-COMPLETE.md.

### 20260923-54. Finish the 9d result comparator. Done, see BACKLOG-COMPLETE.md.

### 20260923-55. Round-trip guard for deparsed SQL. Done, see BACKLOG-COMPLETE.md.

### 20260923-56. Finish 5a-4, second pass. Done, see BACKLOG-COMPLETE.md.

### 20260923-57. Rewrite candidate check loose ends.

Minor findings from the reviews of 20260922-10:
- **Only-the-last mutants survive.** `used.last(1).each` in the relkind loop and `.last(1).find` in the placeholder check both stay green, because every test puts the bad item last. Add a view-before-table case and a bad-before-good placeholder case.
- **The reparse of the qualified SQL can raise a raw `PgQuery::ParseError`.** An example is `(ARRAY(SELECT ...))[1]`. It fails closed as `internal_error`, but it should be the check's own error. 20260923-55 covers this.
- **Partitioned tables are refused.** A candidate against relkind `p` is refused, consistent with 3a (20260922-17). Revisit that if 3a starts allowing them.

- **Depends on:** 20260922-10.
- **Came from:** The reviews of 20260922-10.
- **Design:** What goes into the enclave.
- **Landed (2026-09-26):** tests killing the `.last(1)` mutants. Still open: moving to `Relations.check`.
- **Status:** todo
- **Note (from 20260922-17):** Switch to `Relations.check` in place of this check's own qualify and `plain_table!`, so its non-table rules become per-kind. Its spec expectations change with it.

### 20260923-58. Enclave CLI loose ends.

Findings from the reviews of 20260922-4 and 20260923-53:
- **JSON.parse itself uses 50 to 135 times the input size on dense arrays.** A 64 MB `{"a":[{},{},...]}` peaked at 8.6 GB, and `[0,0,...]` at 3.2 GB. The double parse (`UniqueKeys`, then plain) adds to the peak. Lower `Input::MAX_BYTES`, or cap the element count before parsing.
- **The scan is slow on dense quotes or backslashes,** about 8 to 10 s for 64 MB. It's linear, and fine at realistic sizes.
- **Anything printed or warned while `require "quaack/enclave"` loads** goes out before `silence_stderr!` and `claim_stdout!`, and so does a LoadError backtrace. Silence first in `exe/quaacks`, before the require.
- **`Store#parse` relies on `max_nesting` alone,** and json 3.0.2 doesn't count an empty innermost container. Run `PlainData.check` there too, as `Input` does.
- **Cancel on SIGTERM:** consider `conn.cancel` or a `statement_timeout` when SIGTERM arrives mid-query. This belongs with 20260922-16.

- **Depends on:** 20260923-53.
- **Came from:** The reviews of 20260922-4 and 20260923-53.
- **Design:** Where QUAACK runs.
- **Landed (2026-09-26):** stdout is claimed and stderr silenced before `require`, and `Store#parse` runs `PlainData.check`. Still open: `Input::MAX_BYTES` and element caps (a sizing choice), the slow scan, and cancel on SIGTERM.
- **Status:** todo

### 20260924-1. 5a-4 loose ends.

Minor findings from the second review of 20260923-56:
- **A result type map breaks the hidden-index check.** With `conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)`, `getvalue` returns Integer `0`, so `0 != "0"` refuses every run as `indexes_hidden`, and EXPLAIN's json comes back already parsed. Pin a plain type map for the run, or compare with `.to_s`, and add a test.
- **Empty `literal_sets` is accepted.** Every candidate comes back unused with no error. DESIGN.md says there are always three literal sets, so refuse `{}` as `bad_literal`.
- **Tests that are missing:**
  - Changing `guarded(:cleanup_failed) { deallocate }` to another rule stays green.
  - The exact-cost assertions use single-node plans only. Add one on a join.
- **`CanonicalPlan` treats any `"<N>…"` index name as hypothetical.** That's in the landed `canonical_plan.rb`, related to 20260923-28. A real index named that way is canonicalized wrong.
- **The runner depends on step 4 matching production settings.** See the note on 20260922-25.

- **`to_ddl` can stop the whole run.** Now that the round-trip guard is on `main`, `SingleCandidateTest#create` re-raises a `Deparse::Error` from `candidate.to_ddl`, which stops the whole run. Make it a refusal for that one candidate. It takes a name over 63 bytes, so it's nearly unreachable.

- **Depends on:** 20260923-56.
- **Came from:** Second review of 20260923-56.
- **Design:** 5a-4.
- **Landed (2026-09-26):** empty literal_sets refused, the string type map, and the `unrenderable` refusal. Still open: a `cleanup_failed` guard test, and an exact-cost test on a join.
- **Status:** todo

### 20260924-2. Pin hidden_differences? for every row in a tie group. Done, see BACKLOG-COMPLETE.md.

### 20260924-3. Intake loose ends.

Findings from the reviews of 20260922-13:
- **A hard kill leaves an orphaned partial run.** SIGKILL, an OOM kill, or SIGXFSZ can leave a partial 0700 run directory behind, holding production literals, and print no run ID. Add a sweeper, for example `quaacks teardown --orphans`, or have intake sweep runs older than a day with no finished marker. It fits with 20260922-66.
- **There are tiny signal windows.** One is between `Store.create` returning and the `begin`. Another is after `with_new_run` returns and before exit, where `done` is printed, then an error line, and the run is kept. The driver treats that run as failed, so it's orphaned.
- **The query isn't checked against the plan.** A SELECT query with an UPDATE's plan is accepted. Compare the relations and statement type once 3a has a connection.
- **NOFOLLOW covers only the last path component.** That's acceptable under the threat model. Say so in the doc.
- **Surviving mutant:** `time > now + FUTURE_SLACK` → `>=`. Add a unit test at exactly `now + 86_400` through `ClockAnchor.from(now:)`.
- **`Step required:` doesn't check that each required name is a declared option.**
- **DESIGN.md step 1** doesn't list `query_has_parameters` or the `--captured-at` bounds. It also says a refused construct's name is reported, but the `error` whitelist type can't carry it. That's a question for the user: change DESIGN.md, or add a shape-only detail field?

- **Depends on:** 20260922-13.
- **Came from:** Both reviews of 20260922-13.
- **Design:** Step 1.
- **Landed (2026-09-26):** the `FUTURE_SLACK` boundary test, the undeclared-option check in `CLI::Step`, the DESIGN.md step 1 text, and the NOFOLLOW doc. Still open: an orphan-run sweeper and the signal windows (see 20260922-66), and checking the query against the plan.
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

- **Range over a nondeterministic collation passes the collation check.** A custom range type over text with a nondeterministic collation isn't caught, because the check doesn't read `pg_range.rngcollation`. Add `OR c.oid IN (SELECT rngcollation FROM pg_range)`.
- **A precise check for ties at a cut.** The rows before the tied group must match exactly, and the rest must come from the group. That would recover top-N originals that are refused today.
- **Interval compare by value, and lower-level nondeterminism.** Intervals could compare by value in the comparator. For nondeterminism below the top level (a subquery LIMIT, DISTINCT, or GROUP BY), see 20260924-5.
- **DESIGN.md 9d** should describe the two-run tiebreaker and the fail-closed rules.

- **Depends on:** 20260922-47.
- **Came from:** The reviews of 20260922-47 and 20260923-54.
- **Design:** 9d.
- **Landed (2026-09-26):** the range-collation check and DESIGN.md tiebreaker text. **Needs a decision:** an exact check for ties at a cut, and comparing intervals by value.
- **Status:** todo

### 20260924-8. Burndown loose ends.

Findings from the second review of 20260922-61:
- **`Protocol::Burndown.valid?` raises ArgumentError instead of returning false** on a record that mixes String and Symbol keys, because `record.keys.sort` can't compare them. It fails closed, but it breaks egress's contract of raising `Egress::Error`. Check that every key is a String before sorting.
- **Integer counts have no upper bound.** A 16-digit number could go out as a count if an Integer from the database were passed in. Consider a sanity cap, such as counts below 10**12.
- **Misuse double-counts instead of being refused.** Calling `record_dedupe` twice on the same Dedupe, or passing a stale or wrong-search `since`, is accepted. Consider deriving `since` from the stored burndown for each search.
- **`since` and the Dedupe live only in memory.** 5a-5 needs a separate enclave call after the driver's LLM call, so the next process has to rebuild both. Add a note for 20260922-33.
- **`record_single_candidate_test` doesn't tie its report to the Dedupe's proposals.**
- **Decided:** No. Keep the pattern for drop reasons and total names. (The original question was whether they should be closed lists in the protocol gem, like `STAGES`.) Today any lowercase word passes, so a one-word value could be stored as a reason.

- **Depends on:** 20260922-61.
- **Came from:** Both reviews of 20260922-61.
- **Design:** 15b.
- **Landed (2026-09-26):** mixed keys return false, and counts are capped at 10**12. **Needs a decision:** refusing misuse such as a double `record_dedupe` or a stale `since`, deriving `since` from the stored burndown, and tying `record_single_candidate_test` to the Dedupe's proposals. Also, 5a-4's new `unrenderable` refusal is counted as `hypopg_refused`.
- **Status:** todo

### 20260924-9. Load-order loose ends.

Findings from both reviews of 20260924-5:
- **A surviving mutant hides a relabeling bug.** Changing `raise unless positions && e.rule == :fixture_load_failed` to `raise unless positions` stays green. With that change, a query failure in the reverse run would be relabeled `reverse_load_failed` and given the wrong index. Add a test where only the reverse run hits `query_failed`, and check that the rule stays `query_failed`.
- **A symmetric middle pick survives.** In an odd-sized tie group with the pick exactly in the middle (`OFFSET 1 LIMIT 1` over three ties), the pick is the same in both orders. So is a rare top-N heapsort pick. A third order, such as rotating each table's run by one, would catch both.
- **Self-referencing foreign keys always fail the reverse load**, as `reverse_load_failed`. That fails closed, but it discards every candidate for fixtures with tree-shaped tables. Keep such tables in forward order, or reverse them level by level, using a catalog lookup of self-referencing FKs.
- **Partitioned tables are scanned in a fixed partition order**, so the reverse load only flips rows within each partition. 3a (20260922-17) refuses partitioned tables, so today this is moot. Revisit it if 3a starts allowing them.
- **DESIGN.md 9d wording:** name the hash-order and heap-sort gaps, and soften "a small sort keeps its input order for ties."
- **Deferrable constraints** would allow any load order, but production FKs usually aren't deferrable. This is only a note.

- **Depends on:** 20260924-5.
- **Came from:** Both reviews of 20260924-5.
- **Design:** 9d.
- **Landed (2026-09-26):** the reverse-only query_failed test and DESIGN.md gaps text. **Needs a decision:** a third load order, and keeping self-referencing FK tables in forward order.
- **Status:** todo

### 20260924-10. 5a-7 loose ends.

Findings from the reviews of 20260922-35:
- **Duplicate candidates in `results`** can make `top` list the same index twice. 5a-3 dedupes within a search, so this can't happen in 5a-7's own flow. Step 8's caller should dedupe first.
- **`rank` checks the literal-set names against the baseline, but not the values.** It's a documented precondition, but a caller who passes different values under the same names would compare against the wrong baseline.
- **The greedy search never drops an index once added.** A smarter search could find `[a, c]` where the greedy keeps `[b, a]`. It follows DESIGN.md's greedy rule, so change it only if someone wants that.

- **Depends on:** 20260922-35.
- **Came from:** The reviews of 20260922-35.
- **Design:** 5a-7.
- **Checked (2026-09-26):** the duplicate-candidates item is stale. **Needs a decision:** checking literal-set values means the baseline must store the values it was measured with. Store them, or keep this a documented precondition.
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

Findings from the build and reviews of 20260922-16:
- **No connect_timeout or statement_timeout on the production connection.** A host that silently drops packets hangs the step. The SIGTERM and cancel note in 20260923-58 applies too.
- **The recorded "production values" are the operator's session values.** They include `PGOPTIONS` and `ALTER ROLE ... SET`. Fix DESIGN.md wording, or connect with `options: ""`. Step 4 (20260922-25) decided: the run server is compared with production's own recorded values.
- **Qualify `current_setting` and `json_array_elements_text` with `pg_catalog.`,** so a role's search_path can't shadow them.
- **`"memory_command": null` counts as not configured,** but DESIGN.md says that's `bad_config`.
- **There's no upper bound on the memory size.**
- **A background child that holds stdout makes the memory command wait out the full timeout,** and a `setsid` child escapes the process-group kill.
- **`pg` now loads for every `quaacks` subcommand.**
- **Spec noise:** `ProductionServer` prints NOTICE lines into the rake output.
- **Surviving mutants:**
  - config: invalid UTF-8 handling
  - memory: a double space before the unit, `reap`, the TIMEOUT and MAX_OUTPUT values, and a spawn failure
  - inventory: closing the connection
  - the step: a hardcoded `major_version`
- **3a's `Relations.check`** could use `Inventory::Production.connect` and `read_only`.

- **Depends on:** 20260922-16.
- **Came from:** The build and reviews of 20260922-16.
- **Design:** Step 2.
- **Status:** todo

### 20260924-25. 3g redaction loose ends.

Findings from the builds and reviews of 20260922-23, 20260924-11, and 20260924-16:
- **Placeholders of different types can collide on one plan literal.** With `$1 = 101` and `$2 = B'101'`, the plan shows `$1`, and `X'05'` matches integer 101. No value leaks, but `$n` and the row annotation can be wrong. Prefer the candidate whose type matches the literal's cast.
- **Expressions Postgres treats as equal but that are written differently** (`status || '-x'` against `o.status || '-x'`, or `'-x'::text` against `'-x'`) still get separate placeholders. They fail closed as `prepare_failed` 42803 or 42P10.
- **Date and timestamp normalization for row annotations,** through the racetrack.
- **Masks on planner-made TRUE and FALSE inflate the masked count.**
- **The broad typmod rule.**
- **Egress max_nesting:** plans more than about 48 levels deep can't go out. Decide whether to flatten them, raise the limit, or refuse with a clear rule.
- **Decided:** Refuse with a clear rule, and list it as unsupported in v1.
- **The 42P18 retry depends on English `lc_messages`.**
- **Preparing in a failed transaction gives 3B001, not 25P02.**
- **PredicateAtoms should use 3g's numbering.**
- **SingleCandidateTest and ArenaRunner should adopt Binding,** so types get declared through PREPARE.
- **Three `Cast` survivors in `expression.rb`** can't be reached from a real PG18 plan: the WITH line, `after_word?`, and the `break` on `","`.
- **The huge-exponent test's `Timeout`** is now a subprocess. Keep it that way.

- **Depends on:** 20260924-16.
- **Came from:** The reviews of 20260922-23, 20260924-11, and 20260924-16.
- **Design:** 3g.
- **Status:** todo

### 20260924-26. 3c statistics loose ends.

Findings from the build and reviews of 20260922-19:
- **pg_stats and pg_stats_ext silently hide columns the operator can't SELECT,** so a role with limited privileges gets missing statistics with no error. Detect this and refuse it, or record it.
- **Values and names aren't converted to UTF-8,** unlike SchemaDump. A non-UTF-8 database with non-ASCII values may be refused at the store write.
- **Resolved:** 20260922-22 removed `few_distinct`, and replaced it with `PiiClassification#low_cardinality`.
- **The pg_stats inherited-filter mutant is killed only by luck:** without the filter, row order decides which duplicate wins.
- **A column type with a delimiter other than a comma (such as `box`)** would make PgArray raise and abort 3c. That's rare, so list it as unsupported in v1 or skip it.

- **Depends on:** 20260922-19.
- **Came from:** The build and reviews of 20260922-19.
- **Design:** 3c.
- **Status:** todo

### 20260924-27. 3f classification loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-28. 3e literal set loose ends.

Findings from the build and reviews of 20260922-21:
- **Django date filters get no worst-case or typical value.** psycopg2 writes datetimes and dates as `'...'::timestamptz` and `'...'::date`, and arrays as `'{..}'::bigint[]`. 3g turns these into `$n::type` cast placeholders, and 3e always falls back on those. Handle a cast placeholder whose cast matches the column's type.
- **3g doesn't store the redacted SQL,** so whatever wires 3e in (step 5 or step 9 orchestration) has to pass it in or store it.
- **The boolean `t`/`f` check at `literal_set.rb:326` survives mutation.** pg_stats always emits `t` or `f`, so either pin it with a planted bad value or drop it.

- **Depends on:** 20260922-21.
- **Came from:** The build and reviews of 20260922-21.
- **Design:** 3e.
- **Status:** todo

### 20260924-29. Run server check loose ends.

Findings from the build and reviews of 20260922-25:
- **Per-tablespace `random_page_cost` and `seq_page_cost` aren't checked.** The inventory doesn't record production's tablespace spcoptions. Record them in step 2, then compare them here.
- **`shared_preload_libraries` that change plans, such as pg_hint_plan, aren't compared.** Only pg_extension is.
- **PGTZ and PGDATESTYLE in the operator's libpq environment** change the session's TimeZone and DateStyle on both connections, so the check compares session values, not server values.
- **The debug_parallel_query test goes through the recorded-value path,** not the boot_val path its name suggests.
- **The required superuser bypasses row-level security.** The step 5 plan gate catches that for the original query.

- **Depends on:** 20260922-25.
- **Came from:** The build and reviews of 20260922-25.
- **Design:** Steps 2 and 4.
- **Status:** todo

### 20260924-30. Include extensions in the 3b schema dump. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20260925-1. Index DDL check loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260925-2. Insert check loose ends.

Minor findings from the first review of 20260922-12:
- **The variadic arity branch is untested.** Dropping `OR p.provariadic <> 0` in `insert_values.rb` MUTABLE_SQL stays green. Add a test that `concat('a','b')` is refused as `not_immutable`.
- **The `attisdropped` clause in COLUMNS_SQL is unproven.** Removing it stays green, because dropped columns get unmatchable names. Keep it or drop it.
- **Implicit coercion is unchecked.** An uncast literal into a column whose type has a volatile input function, or a domain `CHECK` that calls one, runs that function at insert time. The function comes from the production schema, not the LLM. Document this in DESIGN.md, or check column-type input functions and domain checks.
- **Values aren't pinned to be deterministic.** TimeZone-dependent timestamptz literals and `'now'`, `'today'` are accepted. Set a fixed TimeZone in the arena session, or refuse the special date and time inputs, or note it in DESIGN.md.

- **Depends on:** 20260922-12.
- **Came from:** The first review of 20260922-12.
- **Design:** What goes into the enclave.
- **Landed (2026-09-26):** the variadic test and DESIGN.md notes on unchecked coercions. **Needs a decision:** fix the arena TimeZone, or refuse special date inputs, instead of just documenting them.
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

Minor findings from the first review of 20260925-8:
- **No read-only transaction.** `steps/qualify.rb` reads production outside a read-only transaction, unlike inventory. Every statement is a fixed catalog SELECT today. Wrap `Relations.check` in `Inventory::Production.read_only`, both for defense in depth and for one snapshot across the lookups.
- **`"$user"` is the operator's role.** It resolves to the operator's role, not the role of the application that made the plan. Say so in DESIGN.md, or refuse a `$user` path entry that matches an existing schema other than the operator's own.
- **The step spec covers one join only.** Add step-level cases for a CTE, a subquery, quoted identifiers, and already-qualified names.

- **Depends on:** 20260925-8.
- **Came from:** The first review of 20260925-8.
- **Design:** Step 1, 3a.
- **Landed (2026-09-26):** the qualify step case and the `$user` DESIGN.md note. **Needs a decision:** add the `Production.read_only` wrapper to qualify without a failing test first, since no test can observe it. Still open: refusing a `$user` entry that matches another schema.
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

### 20260928-6. LLM provider seam loose ends, part two.

These are minor findings from the second review of 20260928-3:
- The spec for the CLI's default client builder (`cli_run_spec.rb`, "builds the client from the block's settings") only checks `api_key_env`. A builder that drops the block's model or base_url stays green. Move the builder into a small method that takes a transport, so a spec can pass FakeLLM and assert the model and URL in `fake.asks`.
- The same spec sets `QUAACK_ALLOW_REAL_LLM=1`, which turns off the `NoNetwork` guard. Its only remaining guard is `ANTHROPIC_BASE_URL=http://127.0.0.1:9`, so a future explicit base URL could send its sentinel key to the real API from `rake`. Keep a refusal at the gem's requester in that example.
- `AnthropicAdapter` claims a given `api_key:` wins over `api_key_env`, but no spec checks it. Add one, or drop the claim.
- `quaack run` now reads driver.json. A file that exists but can't be read (EACCES) raises `Errno::EACCES` out of `DriverConfig.read`, uncaught, so the run dies with a stack trace. Rescue `SystemCallError` there as `Bad`, or as a "can't read" usage error. `start` has the same gap.

- **Depends on:** 20260928-3.
- **Came from:** Second review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** todo

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

## After version 1.

These tasks are worth doing, but they don't block version 1. Pick them up after the full pipeline (20260922-65) works.
- **Progress:** Piece one landed on `main` after a build and a first review with nothing blocking. `IndexDdlCheck` now refuses `WITH (...)` (rule `storage_options`). An enclave `GeneratorThree.filter` runs the inbound check, `from_ddl` and Dedupe, and returns an outcome for each DDL. There's a new whitelist type `index_outcome`, and a driver `GeneratorThree` loop with a callable `index_test`. Left: the `index-payload` and `index-test` subcommands, saving the LLM results and partial tags in the store, running 5a-4 on the survivors, the 5a-5 burndown record, and running it for rewrites. Those need 20260925-6 first. The review's minor findings went to 20260925-5.

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
- The `rewrites.empty?` check in `Pipeline`'s `generate` has no observable effect, because `OperatorCandidates#run` already returns early. Remove it as a cleanup.

- **Depends on:** 20260926-27, 20260926-31.
- **Came from:** Their build.
- **Design:** Step 13.
- **Landed (2026-09-26):** removed the dead `rewrites.empty?` check. Still open: a real-Postgres test that produces an unstable literal.
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
- The `knocked_out` test has no case where the stored `rewrite_survived` says `"survived" => false` (changing `== true` to `!= false` stays green).
- LLM call counts on a resumed run include only calls from the current process.

- **Depends on:** 20260926-34, -38.
- **Came from:** Their build and review.
- **Design:** Step 15.
- **Landed (2026-09-26):** the knocked_out missing-entry test. Still open: the StepNine dropped count, per-round covered shapes, schema-less plan nodes, and LLM counts on resume.
- **Status:** todo

### 20260926-43. Payload fidelity loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-44. Expression-unique loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-45. Driver, LLM client and harness items left from 20260924-13, -14, -20.

These were skipped as needing a design choice or a larger rework:
- **Remote quaacks on timeout:** when the driver's timeout fires, the remote `quaacks` keeps running. **Landed:** The enclave exits on hangup. `quaacks` notices when its stdin/stdout close (ssh dropping), cancels any running query, and stops.
- **Lazy-load `anthropic`:** it adds about 0.5s to every CLI start. Loading it lazily touches load order and the boundary checks.
- **Pump/Child rework:** covers a child that closes stdout and then reads stdin, and a grandchild that holds stdout open.
- **Per-example timeout for driver specs:** needs tuning so it doesn't cause flakes.
- **Shared `NoNetwork`:** share the prepend with the root suite.
- **Error-message tests:** pin exact error-message text in the LLM client specs.
- **JSON harness column:** add a JSON column to the harness schema (a fixture design change).
- **Streaming:** add LLM streaming, only if ever needed.

- **Depends on:** 20260924-13, -14, -20.
- **Came from:** The build of those tasks.
- **Design:** Where QUAACK runs, LLM client.
- **Landed (2026-09-27):** NoNetwork is shared with the root suite, and the LLM error text is pinned. **Needs a decision:** lazy-loading `anthropic` breaks `runtime_boundary_spec` (it expects every driver file to load the gem). Change that spec to build a client first, or keep the eager load. Still open: the Pump/Child rework, per-example timeouts, the JSON harness column, and streaming.
- **Status:** todo

### 20260926-46. Driver crashes on the first counterexample round. Done, see BACKLOG-COMPLETE.md.

### 20260926-47. Refuse user-defined set-returning functions in FROM. Done, see BACKLOG-COMPLETE.md.

### 20260926-48. Anchor clock-reading date literals. Done, see BACKLOG-COMPLETE.md.

### 20260926-49. Schema dump, clock anchoring and deparse items left over.

- A dbname like `app:prod` is refused as `secret_in_conninfo`. That's rare, but a false refusal.
- Restore LLM candidates by their anchored form, not by position. This is a large redesign.
- The subset DDL doesn't restore into an empty arena on its own (schemas, types, extensions), and a partitioned query table needs its parent in the dump.
- The schema-dump paths for lock-wait timeout, signal kill and empty conninfo are untested.
- Table sort order for EUC_JP and WIN1252 databases.
- Pin the four surviving `parentheses.rb` mutants. The deparse matrix adds about 20s to the suite.

- **Depends on:** 20260924-15, -22, -23.
- **Came from:** Build and review of those tasks.
- **Design:** 3b, 3h, step 1.
- **Landed (2026-09-27):** the `app:prod` false refusal is fixed (libpq's exact rule), and the parentheses mutants are pinned. The lock-wait and signal tests already existed. Still open: empty conninfo (no defined behavior), candidates restored by anchored form, subset DDL restore, and EUC_JP/WIN1252 sort order.
- **Status:** todo

### 20260926-50. FROM functions: non-FuncCall items crash. Done, see BACKLOG-COMPLETE.md.

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty. Done, see BACKLOG-COMPLETE.md.

### 20260926-52. Anchor the clock in rewrite candidates too. Done, see BACKLOG-COMPLETE.md.


### 20260926-53. Candidate clock anchoring loose ends.

- Step 9 (counterexamples) and steps 13 and 14 use the anchored candidate SQL, but only 14c has its own end-to-end clock test.
- `RewriteEntry.run_sql` falls back to `"sql"` for entries without `anchored_sql`. Only hand-written spec fixtures and stores from before the change hit that path. Consider requiring `anchored_sql` and updating the fixtures (about 30 writes).

- **Depends on:** 20260926-52.
- **Came from:** 20260926-52 build and review.
- **Design:** 3h.
- **Landed (2026-09-26):** end-to-end clock tests for step 9 and candidate-runs. Still open: dropping the `anchored_sql` fallback.
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

- The realistic-schema step 9 spec has no keyset query, so tie rows aren't tested against the prompt-pack schema's unique keys and FKs. Add one.
- No pools for `=` or `<>` row comparisons, or rows built on expressions (listed as a v1 limit).
- Perturb-and-retry for colliding expression keys.
- A generated column counts as NULL when an expression key is worked out.

- **Depends on:** 20260926-40, -44.
- **Came from:** Their build and review.
- **Design:** Step 9.
- **Landed (2026-09-26):** a realistic-schema keyset test (expanded form and dropped keyset). Still open: `=`/`<>` pools, perturb-and-retry, the generated-column item, and the tie-breaker gap (see 20260926-59).
- **Status:** todo

### 20260926-56. Items left from 20260923-27, -28, -35, -38.

- **Qualify only relations? (needs a decision):** functions, types, operators, and names inside string literals aren't qualified. Rewrite them, or refuse them?
- **Comments and layout:** deparse drops comments and layout.
- **Shared parse helper:** merge PlanExpression's parse helper with CanonicalPlan's parse step. This is a refactor only, and it changes a shared signature.
- **ArgumentError rules:** give rules to the ArgumentErrors raised in PredicateAtoms and IndexCandidate. For IndexCandidate, the question is whether to change the error class that callers rescue.
- **Operator messages:** a driver-side table mapping rules to text for operators. The texts need deciding.
- **The `"any"` attribute match:** a column named exactly like a volatile `"any"` function (`pg_restore_*_stats`) still aborts. This was kept on purpose.
- **Known volatility limits:** a volatile cast to a common type makes every cast to it abort; provolatile is trusted; STABLE functions that read other tables pass.

- **Depends on:** 20260923-27, -28, -35, -38.
- **Came from:** Their build and reviews.
- **Design:** 3a, 3d, step 1.
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
- The deploy spec never installs pg_query or pg from rubygems, and never compiles them. It never runs over real ssh or on a real Linux jump server. Check these on the first real `quaack deploy`.

- **Depends on:** 20260923-2.
- **Came from:** Reviews of 20260923-2.
- **Design:** Where QUAACK runs.
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

### 20260929-7. Say which clients `run_server_other_clients` saw. Done, see BACKLOG-COMPLETE.md.

### 20260929-8. `run_server_other_clients` may count QUAACK's own session.

`RunServerCheck` tells its own sessions apart from other clients by libpq's `backend_pid`. That's the pid the server sent at connect time. Behind a pooler or proxy, such as PgBouncer, it can be a pid the pooler made up, not the server backend running QUAACK's queries. Then QUAACK's own session counts as another client, and step 4 fails with `run_server_other_clients` on a quiet server.

- Get each own pid from the server with `SELECT pg_backend_pid()` on that connection, not from libpq.
- Decide whether step 4 supports a pooler in front of the run server at all. With transaction pooling, consecutive statements can land on different backends, so the quiet check and later steps can't rely on one session. If it isn't supported, say so in DESIGN.md as unsupported in v1.
- First confirm with 20260929-7's output whether this is what happened in the 2026-09-29 failure, where the run server was on port 5431.

- **Depends on:** 20260929-7.
- **Came from:** The user, 2026-09-29, who doubted the run server really had other clients.
- **Design:** Step 4.
- **Status:** todo

### 20260929-9. The full check fails on a Mac whose pg_dump is older than 18. Done, see BACKLOG-COMPLETE.md.

### 20260929-10. The leak check sees BUNDLER_VERSION in a script's environment.

`enclave/spec/leak_check_spec.rb:374` ("runs a script the same way, with no Bundler in its environment") fails on unchanged main (a762d73) on 2026-09-29. It expected no Bundler variables and got `BUNDLER_VERSION`. A likely cause is Ruby 3.4's bundled bundler re-execing into the lockfile's bundler 4.0.15, which sets `BUNDLER_VERSION`. Find the cause, and scrub the variable, or fix the check, so a script runs with no Bundler in its environment.

- **Depends on:** nothing open.
- **Came from:** The full check run for 20260929-7.
- **Design:** Where QUAACK runs.
- **Status:** todo

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

### 20260929-13. Build the prompt-pack database once per spec process.

`PromptPack.databases` builds each replay's production database from scratch: it creates it from template0, loads `script/prompt_pack/schema.sql` and `data.sql`, and runs ANALYZE. The data script generates about 420,000 rows, which takes about 3 seconds, and the pipeline replay spec does that for each of its 39 runs. The data is the same for every query. Copying a database with `CREATE DATABASE ... TEMPLATE` takes about 0.07 seconds.

- Build the loaded, analyzed database once per spec process, on the first run that needs it, and create each run's production database as a copy of it. The racetrack database is already a copy of production, so it stays as it is.
- Every copy must hold the same schema, data, extensions, and statistics as a fresh build. A spec should prove a copy matches.
- The template database must have no connections left open when it's copied, and no replay run may change it.
- `script/prompt_pack/run.rb` uses the same helper, so it gets the same speedup.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after timing the full check.
- **Design:** none. This is test harness speed only.
- **Status:** todo

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
