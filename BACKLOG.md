# QUAACK backlog.

This is the working backlog for QUAACK. It breaks README.md into tasks we can pick up one at a time.

## How this file works.

- Each task has an ID made of the date it was added and a number: `YYYYMMDD-N`. IDs never change and never get reused, even if a task is dropped.
- New tasks get the date they're added. Tasks from reviews, test findings, or new ideas go at the end of the section they belong to, or under "Added later" if no section fits.
- **Depends on** lists tasks that must be done first. "None" means the task can start any time.
- **README** points to the section the task comes from.
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

### 20260922-65. Full pipeline.

Wire every step together in the driver, from intake through the report and teardown. Run it end to end against the test harness.
- **Decided:** The end-to-end test uses a scripted fake LLM, so it runs free in rake. The scripts must be realistic, drawn from a large corpus of responses. **Before building, ask the user questions:** they'll collect responses from several different LLMs to seed the corpus.
- **Landed (part one):** The prompt pack generator, `script/prompt_pack/run.rb`, and a partial pack in `spec/fixtures/llm_corpus/`. Rerun it after 20260926-37 and keyset support land, to capture the 10a and step 11 prompts.
- **Note (2026-09-26):** The user is having another LLM build a large end-to-end query corpus: for each test, the schema, the inserts, the slow query, and the changes that make it fast. Build -65's end-to-end tests on that corpus when it arrives. Don't spend cycles writing our own fixture queries beyond the small prompt pack.
- **Decided (corpus):** Split into two parts. First, a builder generates a prompt pack: it runs the pipeline on harness fixtures and captures every real LLM prompt (5a-5, 5a-6, 6a, step 7, 10a) to files. The user pastes each prompt into 3 LLMs, 3 replies each, and saves the replies next to the prompts. The fake LLM then replays them. Queries to cover: an ORM-style join (equality plus range, ORDER BY, LIMIT), aggregates with GROUP BY/HAVING, a correlated EXISTS or IN subquery, and keyset pagination (row comparisons are unsupported in v1, so that one tests the refusal path unless it's written without a row comparison).

- **Depends on:** 20260922-36, 20260922-39, 20260922-42, 20260922-49, 20260922-52, 20260922-64, 20260926-1, 20260926-2.
- **README:** All.
- **Status:** todo
- **Note (from 20260922-66):** The enclave's `quaacks teardown --run <id>` exists. The driver has to:
  - Call it at the end of every run: on success, on abort, on exception, and on signals where possible.
  - Require the `teardown` line followed by the done line.
  - Treat `store: "already_gone"` as success.
  - On `bad_run`, `bad_store_base`, or `teardown_failed`, tell the operator to check or remove `~/.quaack/runs/<id>` by hand. The enclave never sends the path.
  - Turn `next_step: "destroy_run_server"` into a plain operator message. Nothing destroys the run server automatically.
  - Add `--keep` to the run command. It skips teardown and prints the run ID and the exact teardown command for later.

### 20260922-66. Run teardown. Done, see BACKLOG-COMPLETE.md.

## Added later.

### 20260923-1. Postgres 17 parser under Postgres 18.

The newest pg_query (6.2.3) ships the Postgres 17 parser, and no Postgres 18 version exists yet. The user accepted the Postgres 17 grammar for now. When pg_query fails to parse something, abort with a message that names the parser's Postgres version, so a Postgres 18-only construct is easy to spot. When pg_query ships Postgres 18 support, upgrade it and drop the special message.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Anywhere pg_query parses SQL, including 3a, 5a-1, step 9, and the inbound checks.
- **Status:** todo
- **Decided:** Step 3b doesn't parse the schema dump. It finds the subset tables and their FK parents from `pg_catalog`, and gets the subset from `pg_dump --table` for each one (see 20260922-18). So pg_query only parses queries and inbound SQL, and Postgres 18-only syntax in a dump doesn't matter.

### 20260923-2. Enclave deploys by gem install only.

The repo has one Gemfile and one lockfile for all three gems. So `bundle install` from a checkout on the jump server would install the driver gem, its LLM SDK once 20260922-6 adds it, and the dev tools. The enclave has to deploy by building and installing the `quaacks` gem on its own. Document that, and make the wrong way hard or impossible, for example by having the enclave executable refuse to run under a bundle that includes the driver.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Where QUAACK runs.
- **Status:** todo
- **Note (from 20260922-5):** The driver runs a bare `quaacks` over non-interactive ssh (`ssh -T -o BatchMode=yes -- host 'quaacks ...'`), so `quaacks` must be on PATH for a non-interactive session. The remote login shell must also be POSIX-compatible (bash, sh, or zsh). fish and csh break the Shellwords quoting.
- **Decided:** The driver builds the `quaacks` and `quaack-protocol` gems locally, copies them to the jump server over ssh, and installs them into a user gem directory there. It checks the installed version before each run. There's no gem server.

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

### 20260923-17. Index shape loose ends.

Minor findings from the second review of 20260923-14:
- **Untested requires.** The three `require_relative` lines added to `enclave/lib/quaack/enclave.rb` have no test. Deleting them keeps every suite green. Add a `"quaack/enclave"` use to `standalone_require_spec.rb` that reaches `IndexCandidate`.
- **Shadowed built-in names.** The built-in aggregate and window name check refuses an unqualified call to a user function that shares a built-in's name, such as `public.lead(int)`. Postgres accepts it, and `pg_get_indexdef` prints it unqualified. So `from_ddl` returns nil for such an existing index. It's rare and harmless, since the index just can't be represented. Document it. Also add a test that a column named like a built-in, such as `lag > 0`, is accepted.
- **Proportion.** The aggregate and window check guards input the mechanical generators can't produce, because a valid query's WHERE clause can't hold those calls. It also misses set-returning functions, `DEFAULT`, and `merge_action()`. Decide whether to keep it, trim it, or finish it when 5a-5 extends the shape.
- **Redundant check.** The `!sql.strip.empty?` check in `index_candidate.rb` duplicates the parse error.

- **Depends on:** 20260923-14.
- **Came from:** Second review of 20260923-14.
- **README:** 5a.
- **Status:** todo

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
- **README:** 5a-1.
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
- **README:** 3c.
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
- **README:** 5a-2.
- **Landed (2026-09-26):** tests pinning `PlanNode#inner`, the NaN removed fraction, and the multi-statement ANALYZE check. **Needs a decision:** whether to skip a partial when the column side is cast (varchar shows as `(col)::text`), and whether to treat a non-MCV literal as unknown when MCVs plus nulls cover about 1. Still open: boolean partials, InitPlan, COLLATE, deep plans, and the remaining test gaps.
- **Status:** todo

### 20260923-25. Static checker loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-26. Egress loose ends.

Minor findings from the second review of 20260922-7:
- **A String subclass as a Hash key isn't tested.** Changing `[String, Symbol].include?(key.class)` in `plain_hash` to `is_a?` checks stays green, and it's a real leak: `rule: { Class.new(String) { def to_s = "SENTINEL" }.new("a") => 1 }` then sends the sentinel. Add it to the table of values that must raise.
- **A Hash-like message isn't tested.** Changing `message.is_a?(Hash)` to `message.respond_to?(:each_key)` stays green. Add an object with `each_key` and `[]`, or `ENV`, to the "sends nothing" table.
- **Deep nesting and cycles raise `SystemStackError`.** Fixed by 20260923-32 through the shared `PlainData.check`. Drop this item. A 100,000-deep Array or a self-containing Array recurses in `plain` before JSON's nesting limit applies. Nothing leaks, but the contract says `Egress::Error`, and `SystemStackError` isn't a `StandardError`. Add a depth cap in `plain`.
- **Error filtering (20260922-8) must catch `Egress::Error`, and must never print the cause chain of the errors it filters.**

- **Depends on:** 20260922-7.
- **Came from:** Both reviews of 20260922-7.
- **README:** Trust boundary.
- **Status:** todo

### 20260923-27. Qualify relations loose ends.

Findings from both reviews and the builder of 20260922-14:
- **Other names depend on search_path too.** Unqualified functions, types in casts and column definitions, operators, collations, and text search configurations all resolve through `search_path`. So do relation names in string literals, such as `'t'::regclass`, `nextval('seq')`, and `to_regclass('t')`. None of them are rewritten. This matters for 3d, which looks functions up in `pg_catalog`, and for replaying the query on the racetrack.
- **`SELECT ... INTO new_table` aborts** because its target resolves nowhere. That's a safe abort, but intake (20260922-13) or the inbound check should reject it with a clear rule.
- **A multi-statement input is accepted,** and every statement gets qualified. Intake (20260922-13) should accept exactly one statement.
- **The role used to resolve names.** `"$user"` and the USAGE check use the role QUAACK connects as. If the operator's plan session ran as a different role, resolution could differ. Document this in the operator docs, or take the role as an input.
- **An empty search_path written by hand** as `""` or all whitespace aborts with "has an empty entry", but Postgres treats it as an empty path. EXPLAIN never writes that form.
- **The abort message** joins schemas with ", ", so a schema named `weird, schema` looks like two schemas.
- **Deparse drops formatting.** The output is pg_query's deparse even when nothing changed, so comments and layout are lost.

- **Depends on:** 20260922-14.
- **Came from:** Both reviews of 20260922-14, and its builder's notes.
- **README:** Step 1.
- **Status:** todo
- **Note (from the review of 20260922-17):** RelationQualifier ignores the implicit `pg_temp` at the front of the search path. So a temp view named `orders` in the plan's session would resolve to `public.orders`. The enclave session has no temp relations, so this only matters if the plan's own session had one shadowing a real relation.

### 20260923-28. Canonical plan loose ends.

Minor findings from the second review of 20260922-15:
- **`Integer()` reads a leading zero as octal.** A real index named `"<09>fake"` raises `ArgumentError`, and `"<010>fake"` is read as oid 8. Use `Integer(..., 10)`.
- **A real index whose name starts with `<digits>` is treated as hypothetical.** Without a map, a real `"<123>orders_pkey"` compares equal to `orders_pkey`. It's unlikely, so document it.
- **Surviving mutants:**
  - An empty map treated like no map. `hypothetical_indexes: {}` with a `<oid>` index should make the plan not comparable.
  - The `\A` anchor dropped from `HYPOTHETICAL_INDEX`.
  - An Array of pairs accepted as the map.
- **The "two sessions" Postgres spec never gets two oids,** because `hypopg_reset()` runs after the extra index is made. Fix the setup or the comment.
- **The digest covers a partial predicate's literal.** A short literal could be guessed from the hash. It stays in the enclave today, but any step that sends a canonical form out must know this.
- **Merge `PlanExpression`'s parse helper with `CanonicalPlan`'s own parse step.**

- **Depends on:** 20260922-15.
- **Came from:** Second review of 20260922-15, and its builder's notes.
- **README:** Step 1.
- **Status:** todo

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
- **README:** Step 9 and 9c.
- **Checked (2026-09-26):** the deparse guard and qualification items are already done. **Needs a decision:** NATURAL JOIN atoms (compute the common columns, or emit a marker that can't be replaced). The rest are notes.
- **Status:** todo

### 20260923-31. Finish 5a-3 dedupe and filter. Done, see BACKLOG-COMPLETE.md.

### 20260923-32. Finish the governed store. Done, see BACKLOG-COMPLETE.md.

### 20260923-33. Fail closed on unsupported SQL constructs. Done, see BACKLOG-COMPLETE.md.

### 20260923-34. Governed store loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260923-35. Volatility check loose ends.

Findings from the reviews of 20260922-20:
- **Domain CHECK constraints aren't checked.** A domain whose CHECK calls a volatile function passes. That's realistic, because a validator function is VOLATILE unless someone marks it otherwise.
- **Attribute notation isn't checked.** `t.f` is a plain ColumnRef, so it's still missed. The review of 20260922-10 confirmed it: with `bumpo(public.orders)` VOLATILE, `SELECT o.bumpo FROM orders o` is accepted. The allowlist refuses `(t).f`.
- **One volatile cast to a common type poisons every cast to it.** For example, `CREATE CAST (x AS int)` with a volatile function makes every `::int` abort. None of the catalogs checked have one.
- **TABLESAMPLE is moot now.** The allowlist (20260923-33) refuses it before the volatility check runs.
- **Mislabeled STABLE functions get through.** The check trusts `provolatile`, so a function declared STABLE whose body calls `nextval` is accepted, and the sequence advance survives ROLLBACK. That's a labeling error in the production schema, but it breaks what the arena runner relies on. Record it as a known limitation, or look into checking the bodies of SQL functions.
- **STABLE functions that read other tables are accepted.** Examples are `table_to_xml` and a STABLE SQL function reading an unrelated table. The review of 20260922-10 judged this fine for version 1, since the rows stay in the enclave. Note it in the module doc.
- **Surviving mutants:**
  - Three `quote_ident` columns aren't pinned: `OPERATOR_SQL` `f.proname`, and `CAST_SQL` `named.nspname` and `fn.nspname`.
  - `count == 1 ?` can become `>= 1` without any test failing. Under that change, `a.pair(1, 2)` would falsely abort.
- **The hypothetical-set test** should assert its fixture is non-variadic (`provariadic = 0`, `pronargs = 2`) so it can't go vacuous without anyone noticing.
- **The parse can't see things Postgres adds on its own:** implicit casts, the source type's output function in I/O casts, the default-opclass operators behind DISTINCT, GROUP BY, and ORDER BY, and column defaults. The reviewer judged these exotic.
- **Index DDL too (from the first review of 20260922-11):** `IndexDdlCheck` reuses this check, so the attribute-notation and domain CHECK gaps reach index DDL. With `evil3(public.orders)` a VOLATILE SQL function, `CREATE INDEX ON public.orders ((orders.evil3))` is accepted, and HypoPG and a real CREATE INDEX both build it, because Postgres inlines the SQL body before its IMMUTABLE check. Postgres still refuses a body with side effects, or a non-SQL function. Fix these gaps here, and list them in the "what it doesn't catch" part of `IndexDdlCheck`'s header.

- **Depends on:** 20260922-20.
- **Came from:** Both reviews of 20260922-20, and the tests-only review.
- **README:** 3d.
- **Status:** todo

### 20260923-36. 5a-3 loose ends.

Findings from the reviews of 20260922-32 and 20260923-31:
- **Some existing indexes never count as covering.** `IndexCandidate.from_ddl` returns nil for every index on a partitioned table's parent (`ON ONLY`), for any index `WITH (fillfactor=...)` or `WITH (deduplicate_items=off)`, and for unique indexes with `NULLS NOT DISTINCT`. So a candidate identical to one of them is proposed and tested as if it were new, and 15a won't report it as a duplicate. None of these options changes which queries the index can serve.
- **`IndexCandidate` accepts a predicate whose deparse doesn't parse again.** For example, `'x'::mytype(lower('bob'))` is stored as `'x'::mytype()`. Dedupe drops it, but other consumers would raise. `IndexSql.normalize_predicate` should re-parse its output.
- **Array bounds on a cast aren't checked,** as in `status::text[12345] IS NULL`. It's the same class as the integer typmods the user accepted, but the doc comment doesn't say so.
- **Dead or defensive code:** `left = unwrap(node.lexpr)` in `column_comparison?` is redundant, and the `A_Const` check in `plain_type?` can't be reached through Dedupe.
- **README 5a-3 says GIN and GiST,** but HypoPG also refuses SP-GiST, and SP-GiST is set aside too. Say "any method HypoPG can't model."
- **Open question for the user:** the rule drops every partial that uses a column that isn't low-cardinality, including partials with no literal at all, like `WHERE deleted_at IS NULL`. Those carry no PII risk and are common. Should they get an exception?
- **Decided:** Yes. Allow partial indexes whose predicate holds no literal: IS NULL, IS NOT NULL, or a bare boolean column.

- **Depends on:** 20260923-31.
- **Came from:** The reviews of 20260922-32 and 20260923-31, and the builder's notes.
- **README:** 5a-3.
- **Landed (2026-09-26):** the Decided item (partials with literal-free predicates are allowed; a sentinel test covers it) and the README note. Still open: the `from_ddl` nil cases (`ON ONLY`, `WITH (...)`, `NULLS NOT DISTINCT`), `normalize_predicate` re-parsing, the array-bounds doc note, and the dead-code cleanup.
- **Status:** todo

### 20260923-37. Arena runner loose ends.

Minor findings from the second review of 20260922-46:
- **Every 57014 is reported as `statement_timeout`,** including a self-cancel or an operator cancel. Name the rule `statement_canceled`, or document it.
- **A non-StandardError from the block, followed by a failed rollback, loses the primary error.** Changing `rescue Exception` to `rescue StandardError` in `in_transaction` stays green. Add a test that uses an Interrupt.
- **Which error wins changes with check order.** Moving `check_fixture` after `refuse_unless_idle` stays green. It only changes which error wins when bad rows meet a busy connection.
- **pg_query uses the PG17 grammar and the server is PG18,** so PG18-only SQL fails as `statement_unparsable`. That's fail-closed.

- **Depends on:** 20260922-46.
- **Came from:** Second review of 20260922-46.
- **README:** Step 9.
- **Status:** todo

### 20260923-38. Error filtering loose ends.

Findings from both reviews of 20260922-8:
- **A signal that arrives while `guard` is already reporting an error gets swallowed.** The `rescue Exception` clauses in `write`, `ask`, and `to_egress` catch an asynchronous SignalException, so `guard` returns 70 and a caller's loop carries on. Re-raise SignalException in those clauses too.
- **Nothing tests that `write` flushes.** Deleting `out.flush` stays green.
- **No spec combines `silence_stderr!` with a re-raised signal.**
- **Most enclave error classes have no `rule` method,** so they go out as `internal_error`. Add rules to `RelationQualifier::Error` and `Store::Error`, and to the ArgumentErrors that stand in for a rule, such as those in PredicateAtoms and IndexCandidate.
- **Decided:** No. Keep the identifier pattern for rule names, not a closed list. (The original question was whether rule names should be a closed list in the protocol gem, so every new rule is a reviewed change like the whitelist? Today any identifier-shaped word passes, so an error class that copied a one-word value into `rule` would send it.
- **Operators get no detail beyond the rule.** A rule-to-text table on the driver side would give them a readable message without changing the whitelist.

- **Depends on:** 20260922-8.
- **Came from:** Both reviews of 20260922-8.
- **README:** Trust boundary.
- **Status:** todo

### 20260923-39. Finish 5a-4 single-candidate testing. Done, see BACKLOG-COMPLETE.md.

### 20260923-40. Allowlist loose ends.

Minor findings from the reviews of 20260923-33:
- **EXTRACT's field match uses Unicode `downcase`,** so `'weeK'` with a Kelvin sign is kept, and Postgres rejects that field. Use `downcase(:ascii)` and print the field lowercased, so quoted mixed case such as `'EpOcH'` doesn't pass through verbatim.
- **Tests don't pin `EXTRACT_FIELDS`.** Removing a name only over-redacts, but nothing pins the list.
- **Two doc-comment lines in `generator_one.rb` run long.**
- **Question for the user:** keyset pagination, `WHERE (created_at, id) < ($1, $2)`, is refused because row comparisons aren't on the list. ORMs use it a lot. Should it be supported in v1, or wait for 20260923-48?

- **Depends on:** 20260923-33.
- **Came from:** The reviews of 20260923-33.
- **README:** Step 1.
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
- **README:** What goes into the enclave.
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
- **README:** Where QUAACK runs.
- **Status:** todo

### 20260924-1. 5a-4 loose ends.

Minor findings from the second review of 20260923-56:
- **A result type map breaks the hidden-index check.** With `conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)`, `getvalue` returns Integer `0`, so `0 != "0"` refuses every run as `indexes_hidden`, and EXPLAIN's json comes back already parsed. Pin a plain type map for the run, or compare with `.to_s`, and add a test.
- **Empty `literal_sets` is accepted.** Every candidate comes back unused with no error. README says there are always three literal sets, so refuse `{}` as `bad_literal`.
- **Tests that are missing:**
  - Changing `guarded(:cleanup_failed) { deallocate }` to another rule stays green.
  - The exact-cost assertions use single-node plans only. Add one on a join.
- **`CanonicalPlan` treats any `"<N>…"` index name as hypothetical.** That's in the landed `canonical_plan.rb`, related to 20260923-28. A real index named that way is canonicalized wrong.
- **The runner depends on step 4 matching production settings.** See the note on 20260922-25.

- **`to_ddl` can stop the whole run.** Now that the round-trip guard is on `main`, `SingleCandidateTest#create` re-raises a `Deparse::Error` from `candidate.to_ddl`, which stops the whole run. Make it a refusal for that one candidate. It takes a name over 63 bytes, so it's nearly unreachable.

- **Depends on:** 20260923-56.
- **Came from:** Second review of 20260923-56.
- **README:** 5a-4.
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
- **README step 1** doesn't list `query_has_parameters` or the `--captured-at` bounds. It also says a refused construct's name is reported, but the `error` whitelist type can't carry it. That's a question for the user: change the README, or add a shape-only detail field?

- **Depends on:** 20260922-13.
- **Came from:** Both reviews of 20260922-13.
- **README:** Step 1.
- **Status:** todo

### 20260924-4. Parenthesize what pg_query deparses wrong. Done, see BACKLOG-COMPLETE.md.

### 20260924-5. Rerun 9d comparisons with the fixture loaded in reverse. Done, see BACKLOG-COMPLETE.md.

### 20260924-6. Narrow the 9d fail-closed rule for top-N queries.

Any `ORDER BY ... LIMIT` whose output includes a type left out of the tiebreaker (json, jsonb, xml, citext, hstore, PostGIS, interval, numeric[], and composites of those) is refused, even when the sort key is unique. That refuses every candidate for common top-N queries over such tables, and those are prime rewrite targets. Options: rerun both queries without their LIMIT and OFFSET, and refuse only on a real hidden tie. Or add `::text` sort keys for left-out columns.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **README:** 9d.
- **Status:** todo

### 20260924-7. 9d comparator loose ends.

- **Range over a nondeterministic collation passes the collation check.** A custom range type over text with a nondeterministic collation isn't caught, because the check doesn't read `pg_range.rngcollation`. Add `OR c.oid IN (SELECT rngcollation FROM pg_range)`.
- **A precise check for ties at a cut.** The rows before the tied group must match exactly, and the rest must come from the group. That would recover top-N originals that are refused today.
- **Interval compare by value, and lower-level nondeterminism.** Intervals could compare by value in the comparator. For nondeterminism below the top level (a subquery LIMIT, DISTINCT, or GROUP BY), see 20260924-5.
- **README 9d** should describe the two-run tiebreaker and the fail-closed rules.

- **Depends on:** 20260922-47.
- **Came from:** The reviews of 20260922-47 and 20260923-54.
- **README:** 9d.
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
- **README:** 15b.
- **Status:** todo

### 20260924-9. Load-order loose ends.

Findings from both reviews of 20260924-5:
- **A surviving mutant hides a relabeling bug.** Changing `raise unless positions && e.rule == :fixture_load_failed` to `raise unless positions` stays green. With that change, a query failure in the reverse run would be relabeled `reverse_load_failed` and given the wrong index. Add a test where only the reverse run hits `query_failed`, and check that the rule stays `query_failed`.
- **A symmetric middle pick survives.** In an odd-sized tie group with the pick exactly in the middle (`OFFSET 1 LIMIT 1` over three ties), the pick is the same in both orders. So is a rare top-N heapsort pick. A third order, such as rotating each table's run by one, would catch both.
- **Self-referencing foreign keys always fail the reverse load**, as `reverse_load_failed`. That fails closed, but it discards every candidate for fixtures with tree-shaped tables. Keep such tables in forward order, or reverse them level by level, using a catalog lookup of self-referencing FKs.
- **Partitioned tables are scanned in a fixed partition order**, so the reverse load only flips rows within each partition. 3a (20260922-17) refuses partitioned tables, so today this is moot. Revisit it if 3a starts allowing them.
- **README 9d wording:** name the hash-order and heap-sort gaps, and soften "a small sort keeps its input order for ties."
- **Deferrable constraints** would allow any load order, but production FKs usually aren't deferrable. This is only a note.

- **Depends on:** 20260924-5.
- **Came from:** Both reviews of 20260924-5.
- **README:** 9d.
- **Status:** todo

### 20260924-10. 5a-7 loose ends.

Findings from the reviews of 20260922-35:
- **Duplicate candidates in `results`** can make `top` list the same index twice. 5a-3 dedupes within a search, so this can't happen in 5a-7's own flow. Step 8's caller should dedupe first.
- **`rank` checks the literal-set names against the baseline, but not the values.** It's a documented precondition, but a caller who passes different values under the same names would compare against the wrong baseline.
- **The greedy search never drops an index once added.** A smarter search could find `[a, c]` where the greedy keeps `[b, a]`. It follows the README's greedy rule, so change it only if someone wants that.

- **Depends on:** 20260922-35.
- **Came from:** The reviews of 20260922-35.
- **README:** 5a-7.
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
- **The recorded "production values" are the operator's session values.** They include `PGOPTIONS` and `ALTER ROLE ... SET`. Fix the README wording, or connect with `options: ""`. Step 4 (20260922-25) decided: the run server is compared with production's own recorded values.
- **Qualify `current_setting` and `json_array_elements_text` with `pg_catalog.`,** so a role's search_path can't shadow them.
- **`"memory_command": null` counts as not configured,** but the README says that's `bad_config`.
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
- **README:** Step 2.
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
- **README:** 3g.
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
- **README:** 3c.
- **Status:** todo

### 20260924-27. 3f classification loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260924-28. 3e literal set loose ends.

Findings from the build and reviews of 20260922-21:
- **Django date filters get no worst-case or typical value.** psycopg2 writes datetimes and dates as `'...'::timestamptz` and `'...'::date`, and arrays as `'{..}'::bigint[]`. 3g turns these into `$n::type` cast placeholders, and 3e always falls back on those. Handle a cast placeholder whose cast matches the column's type.
- **3g doesn't store the redacted SQL,** so whatever wires 3e in (step 5 or step 9 orchestration) has to pass it in or store it.
- **The boolean `t`/`f` check at `literal_set.rb:326` survives mutation.** pg_stats always emits `t` or `f`, so either pin it with a planted bad value or drop it.

- **Depends on:** 20260922-21.
- **Came from:** The build and reviews of 20260922-21.
- **README:** 3e.
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
- **README:** Steps 2 and 4.
- **Status:** todo

### 20260924-30. Include extensions in the 3b schema dump. Done, see BACKLOG-COMPLETE.md.

### 20260924-31. Keyset pagination with row comparisons. Done, see BACKLOG-COMPLETE.md.

### 20260925-1. Index DDL check loose ends.

Findings from the second review of 20260922-11:
- **The unparsable sentinel test doesn't exercise the leak path.** In `enclave/spec/index_ddl_check_spec.rb`, the `"unparsable"` case in "a sentinel in the DDL" ends in a trailing AND. So pg_query's message is "syntax error at end of input", which never quotes the sentinel. Plant the syntax error on a sentinel token, such as `... WHERE status = '<sentinel>' '<sentinel>'`. The exact-message test still catches a leak today.
- **The README doesn't list the index DDL rules.** README "What goes into the enclave" says only "exactly one `CREATE INDEX` statement on a table the query uses". Add the refusals (CONCURRENTLY, UNIQUE, NULLS NOT DISTINCT, TABLESPACE, ON ONLY, an unqualified table, volatile functions, parameters, subqueries, and aggregates). Also say that the index name is dropped and that STABLE is left to Postgres.

- **Depends on:** 20260922-11.
- **Came from:** The second review of 20260922-11.
- **README:** What goes into the enclave.
- **Status:** todo

### 20260925-2. Insert check loose ends.

Minor findings from the first review of 20260922-12:
- **The variadic arity branch is untested.** Dropping `OR p.provariadic <> 0` in `insert_values.rb` MUTABLE_SQL stays green. Add a test that `concat('a','b')` is refused as `not_immutable`.
- **The `attisdropped` clause in COLUMNS_SQL is unproven.** Removing it stays green, because dropped columns get unmatchable names. Keep it or drop it.
- **Implicit coercion is unchecked.** An uncast literal into a column whose type has a volatile input function, or a domain `CHECK` that calls one, runs that function at insert time. The function comes from the production schema, not the LLM. Document this in the README, or check column-type input functions and domain checks.
- **Values aren't pinned to be deterministic.** TimeZone-dependent timestamptz literals and `'now'`, `'today'` are accepted. Set a fixed TimeZone in the arena session, or refuse the special date and time inputs, or note it in the README.

- **Depends on:** 20260922-12.
- **Came from:** The first review of 20260922-12.
- **README:** What goes into the enclave.
- **Status:** todo

### 20260925-3. Plan gate loose ends.

Minor findings from the first review of 20260922-28:
- **The `Redaction.binding` call in `plan_gate.rb` is untested.** Deleting it stays green. Add a test that SQL which doesn't bind to the stored map (an extra `$n`, or unredacted SQL) raises `Redaction::Error`.
- **The guards in `CanonicalPlan#unqualify_type` are untested.** Removing the anchor-only guard or the `names.size > 1` guard stays green. Test them, or drop the guards if stripping `pg_catalog` from every cast is fine.

- **Depends on:** 20260922-28.
- **Came from:** The first review of 20260922-28.
- **README:** Step 5.
- **Status:** todo

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
- **`"$user"` is the operator's role.** It resolves to the operator's role, not the role of the application that made the plan. Say so in the README, or refuse a `$user` path entry that matches an existing schema other than the operator's own.
- **The step spec covers one join only.** Add step-level cases for a CTE, a subquery, quoted identifiers, and already-qualified names.

- **Depends on:** 20260925-8.
- **Came from:** The first review of 20260925-8.
- **README:** Step 1, 3a.
- **Status:** todo

### 20260925-19. Schema-dump loose ends.

Minor findings from the first review of 20260925-9:
- **A failure after the writes.** The connection stays idle in transaction through both pg_dump runs. If production's `idle_in_transaction_session_timeout` ends the session, the ROLLBACK in `Inventory::Production.read_only` raises `production_read_failed` after `schema_dump` and `schema_subset` are already stored. Reproduce it with `ALTER ROLE ... SET idle_in_transaction_session_timeout = '1s'` and a fake pg_dump that sleeps 2 seconds. Fix: do the catalog reads, commit, then run pg_dump and write; or delete both entries on a later error.
- **The transaction test only proves that some transaction is open, not that it's read-only.** Note this, or find a way to check `transaction_read_only`.

- **Depends on:** 20260925-9.
- **Came from:** The first review of 20260925-9.
- **README:** 3b.
- **Status:** todo

### 20260925-20. Statistics step: test the read failure. Done, see BACKLOG-COMPLETE.md.

### 20260925-21. Name the function in a 3d refusal. Done, see BACKLOG-COMPLETE.md.

### 20260925-22. Name the missing input when a step's store entry is absent. Done, see BACKLOG-COMPLETE.md.

### 20260925-23. Anchor step loose ends.

- **`clock_replacements` can't go straight back into `restore`.** It's stored as string-keyed hashes, but `ClockAnchoring.restore` calls `.anchored` and `.original` on objects. Add a loader (`ClockAnchoring.load_replacements(store)` or similar) that rebuilds them, with a test that round-trips the stored form through `restore`. Step 15 needs this.
- **The step spec doesn't cover `now() - interval $n`.** Add a case.

- **Depends on:** 20260925-15.
- **Came from:** The first review of 20260925-15.
- **README:** 3h.
- **Status:** todo

### 20260925-24. Index-search loose ends.

- `Dedupe.restore` doesn't check that `considered` matches the lists, so a corrupt entry restores silently.
- `index_search.rb` finds proposals with `==`, which relies on `IndexCandidate#==` ignoring sources. If SingleCandidateTest ever normalizes a candidate, the lookup gives nil and crashes.

- **Depends on:** 20260925-6.
- **Came from:** The reviews of 20260925-6.
- **README:** 5a-3, 5a-4.
- **Status:** todo

### 20260926-1. Driver finds the jump server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-2. Build and record the run server with a configured command. Done, see BACKLOG-COMPLETE.md.

### 20260926-3. Generator three follow-ups.

- Record the 5a-5 burndown: LLM candidates, plus any replacements asked for dropped ones, with the 5a-3 and 5a-4 reasons (README step 15b table).
- `CandidateDdlRedaction` masks `col = ANY (ARRAY[...])` completely, allowed MCVs included, because `operands` handles only `AEXPR_OP` and `AEXPR_IN`. Postgres prints IN lists this way, so partial-predicate values from plan filters get lost. Allow the same per-column MCV rule there.

- **Depends on:** 20260925-4.
- **Came from:** The build and second review of 20260925-4.
- **README:** 5a-5, 15b.
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
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-42. Support SELECT INTO and locking clauses.

`SELECT ... INTO` and `FOR UPDATE`, `FOR SHARE`, and similar. Job-queue queries often use `FOR UPDATE SKIP LOCKED`. README refuses locking clauses in rewrite candidates, so decide how the original and its candidates are compared. RelationQualifier's locking-clause skip was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-43. Support TABLESAMPLE.

The `system` and `bernoulli` methods are volatile, so results aren't repeatable. The TABLESAMPLE handling in FunctionCalls and PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-44. Support richer functions in FROM.

`ROWS FROM(...)` over several functions, column definition lists, and non-FuncCall items in a function's place. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-45. Support JSON_TABLE and SQL/JSON.

JSON_TABLE (`JsonTable`) and the SQL/JSON constructors and functions: JSON_OBJECT, JSON_ARRAY, JSON_VALUE, JSON_QUERY, JSON_EXISTS, IS JSON, JSON(), JSON_SCALAR, JSON_SERIALIZE, and the JSON aggregates. The JSON_TABLE path swap in PredicateAtoms was last present in 6507105. The pg_query deparser segfaults on some forms, so test in child processes. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-46. Support XMLTABLE and XML functions.

XMLTABLE (`RangeTableFunc`), XmlExpr (including IS DOCUMENT and XMLROOT), and XmlSerialize. XMLROOT keyword handling in PredicateAtoms was last present in 6507105. Some XML deparse output is invalid SQL. See 20260923-30. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-47. Support CTE CYCLE and SEARCH.

The CYCLE mark redaction in PredicateAtoms, including typed marks, was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-48. Support row constructors and row comparisons.

`ROW(...)`, `(a, b) = (c, d)`, and keyset pagination like `(created_at, id) < ($1, $2)`. See the question in 20260923-40. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-49. Support GROUPING SETS, ROLLUP, and CUBE.

GroupingSet, `GROUP BY ()`, and GROUPING(). The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-50. Support SIMILAR TO.

The SIMILAR TO reader in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-51. Support field selection.

`(t).x`, `(f(x)).y`, `(t).*`, and mixed forms. The volatility check has to see functions called through attribute notation. See 20260923-35. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
- **Status:** todo

### 20260923-52. Support other SQL-syntax functions.

normalize, IS NORMALIZED, SYSTEM_USER, and COLLATION FOR. The normal-form keyword handling in PredicateAtoms was last present in 6507105. The allowlist (20260923-33) refuses this family in version 1. Supporting it means adding it to `SupportedSql` and handling it in every walker that 20260923-33 lists.

- **Depends on:** 20260923-33.
- **Came from:** The user's decision that refused constructs become after-v1 tasks.
- **README:** What goes into the enclave, and step 1.
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
- **README:** Step 10; CLAUDE.md Development.
- **Status:** todo

### 20260926-30. Result comparison loose ends. Done, see BACKLOG-COMPLETE.md.

### 20260926-31. Minimax and operator rewrite loose ends. Done, see BACKLOG-COMPLETE.md.


### 20260926-32. Measurement test gaps.

- No real-Postgres test produces an unstable literal. Making block counts move between runs deterministically, inside a read-only transaction, was hard, so only the `summarize` unit test covers that path.
- The `rewrites.empty?` check in `Pipeline`'s `generate` has no observable effect, because `OperatorCandidates#run` already returns early. Remove it as a cleanup.

- **Depends on:** 20260926-27, 20260926-31.
- **Came from:** Their build.
- **README:** Step 13.
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
- **README:** Step 15.
- **Status:** todo

### 20260926-43. Payload fidelity loose ends.

- Nothing tests the fallback when PREPARE fails (empty `parameter_types`, so the payload falls back to the 3g type class).
- The rewrite payload spec only checks that it agrees with the index payload, not that the types are correct.

- **Depends on:** 20260926-39.
- **Came from:** 20260926-39 build and review.
- **README:** 5a-5, 6a.
- **Status:** todo

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
- **README:** Where QUAACK runs, LLM client.
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
- **README:** 3b, 3h, step 1.
- **Status:** todo

### 20260926-50. FROM functions: non-FuncCall items crash. Done, see BACKLOG-COMPLETE.md.

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty. Done, see BACKLOG-COMPLETE.md.

### 20260926-52. Anchor the clock in rewrite candidates too. Done, see BACKLOG-COMPLETE.md.


### 20260926-53. Candidate clock anchoring loose ends.

- Step 9 (counterexamples) and steps 13 and 14 use the anchored candidate SQL, but only 14c has its own end-to-end clock test.
- `RewriteEntry.run_sql` falls back to `"sql"` for entries without `anchored_sql`. Only hand-written spec fixtures and stores from before the change hit that path. Consider requiring `anchored_sql` and updating the fixtures (about 30 writes).

- **Depends on:** 20260926-52.
- **Came from:** 20260926-52 build and review.
- **README:** 3h.
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
- **README:** none (CLAUDE.md Development).
- **Status:** todo

### 20260926-55. Keyset and expression-unique leftovers.

- The realistic-schema step 9 spec has no keyset query, so tie rows aren't tested against the prompt-pack schema's unique keys and FKs. Add one.
- No pools for `=` or `<>` row comparisons, or rows built on expressions (listed as a v1 limit).
- Perturb-and-retry for colliding expression keys.
- A generated column counts as NULL when an expression key is worked out.

- **Depends on:** 20260926-40, -44.
- **Came from:** Their build and review.
- **README:** Step 9.
- **Status:** todo
