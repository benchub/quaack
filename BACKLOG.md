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

### 20260922-3. Governed store.

Build the per-run store directory on the jump server: its layout, a run ID, and reads and writes of every intermediate result. Also build the teardown that deletes the run's directory when the run ends.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs (the storage table), and the note about destroying state after each run.
- **Status:** todo
- **Decided:**
  - Each stored result is a JSON file in the run's directory.
  - The run directory is mode 0700 and its files are 0600, in the operator's home directory. Encryption at rest comes from the jump server's disk encryption. There's no encryption in the app.

### 20260922-4. Enclave command-line script.

Build the stateless enclave script: a subcommand dispatcher that reads from the governed store, does one step's work, writes new state back, and prints its result. Nothing stays in memory between calls. All output goes through the egress function.

- **Depends on:** 20260922-3, 20260922-7, 20260922-8.
- **README:** Where QUAACK runs.
- **Status:** todo

### 20260922-5. Driver transport.

Build the driver side of the link: call enclave subcommands over ssh, pass arguments and untrusted inputs, and parse the results. Include a local transport so tests can run the enclave script without ssh.

- **Depends on:** 20260922-4.
- **README:** Where QUAACK runs.
- **Status:** todo
- **Decided:** Larger inputs go to the enclave script as a JSON document on stdin, piped into `ssh <jump server> quaacks <subcommand>`. The local test transport pipes the same JSON.

### 20260922-6. LLM client.

Build the driver's LLM client, with a test double so tests never make real LLM calls. Count every call by step for the 15b burndown.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs, 15b.
- **Status:** todo
- **Decided:**
  - Use the Anthropic API through the official `anthropic` Ruby gem. The key comes from `ANTHROPIC_API_KEY` on the laptop. The default model is `claude-opus-5-5`, and config can override it.
  - Don't build a provider abstraction yet, but don't make one hard to add later. The user may want other providers, or several models working in parallel, someday.

## Trust boundary.

### 20260922-7. Egress function and whitelist.

Build the single egress function. It only accepts fields on a whitelist, and it drops anything else entirely rather than scrubbing it. The whitelist lives in one place so every change to it gets reviewed.

- **Depends on:** 20260922-1.
- **README:** Trust boundary.
- **Status:** todo
- **Decided:**
  - The whitelist is one file in the protocol gem that maps each output type to its allowed field names, such as `column_stats: [table, column, n_distinct, null_frac, correlation, mcv_freqs, low_card_values]` and `error: [step, rule, sqlstate]`. It lists the fields of QUAACK's own output messages, not database columns, so it changes only when QUAACK changes what a step outputs.
  - The egress function drops any field not on its type's list, and drops any output of an unknown type. There are no field types.
  - Changes to the whitelist get reviewed through the normal git diff. There's no snapshot test and no CODEOWNERS.

### 20260922-8. Error filtering.

Send every enclave error through the egress function, including Postgres errors and stack traces. A unique-violation message, for example, can contain a real key value. Errors should still say which step and which rule failed.

- **Depends on:** 20260922-7.
- **README:** Where QUAACK runs.
- **Status:** todo

### 20260922-9. Leak tests.

Build a reusable test helper that runs a step on data with known sentinel values and fails if any sentinel shows up in enclave output. Every later enclave task should use it.

- **Depends on:** 20260922-7, 20260922-2.
- **README:** Trust boundary.
- **Status:** todo

### 20260922-10. Inbound check for rewrite candidates.

Parse each rewrite candidate with pg_query. Accept exactly one `SELECT`. Reject data-modifying CTEs, `SELECT INTO`, and locking clauses. Run the 3d volatility check on it. Each rejection names the rule it broke.

- **Depends on:** 20260922-1, 20260922-20.
- **README:** What goes into the enclave.
- **Status:** todo

### 20260922-11. Inbound check for index DDL.

Accept exactly one `CREATE INDEX` statement on a table the query uses. Reject anything else, naming the rule it broke.

- **Depends on:** 20260922-1, 20260922-17.
- **README:** What goes into the enclave.
- **Status:** todo
- **Decided:**
  - Reject `CONCURRENTLY`, `TABLESPACE`, and `UNIQUE`.
  - Don't reject any index method. The user sees real room for improvement in methods beyond btree.
- **Open questions:** How should later steps treat index methods other than btree? 5a-3 sets GIN and GiST candidates aside today.

### 20260922-12. Inbound check for step 10 inserts.

Accept only plain `INSERT` statements into tables in the 3b subset schema. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, and anything else that isn't a plain insert.

- **Depends on:** 20260922-1, 20260922-18.
- **README:** What goes into the enclave.
- **Status:** todo
- **Decided:** A plain insert is `INSERT INTO <subset table> (<columns>) VALUES (...), ...`. The values can be constants, casts, `DEFAULT`, and calls to immutable functions that pass the 3d volatility check. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, `WITH`, `OVERRIDING`, and any function that isn't immutable.

## Step 1: Input.

### 20260922-13. Input intake.

Read the three operator inputs from the governed store (query text, `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` output, and server name) and check that they're well formed.

- **Depends on:** 20260922-3, 20260922-4.
- **README:** Step 1.
- **Status:** todo
- **Decided:** The operator runs a `quaacks` subcommand on the jump server, such as `quaacks intake --query q.sql --plan plan.json --server prod-db-3`. It checks the inputs, creates the run, and prints the run ID for the driver to use.

### 20260922-14. Fully qualify relations.

Rewrite the query AST so every relation is schema qualified and `search_path` never matters.

- **Depends on:** 20260922-13.
- **README:** Step 1.
- **Status:** todo
- **Decided:** The operator's query should already qualify every relation. If it doesn't, resolve the unqualified names with the `search_path` from the input plan's `SETTINGS`, since that's what the session used when the plan was made.
- **Open questions:** `SETTINGS` only lists values that differ from the built-in default, so a plan made under the default `"$user", public` won't show a `search_path`. Confirm that, then decide whether to assume that default or abort and ask for a qualified query.

### 20260922-15. Canonical plan form.

Define the canonical plan: keep node type, relation, index, join type, strategy, quals, and sort keys, and strip costs, row counts, buffers, and aliases. Build the comparison every later step uses.

- **Depends on:** 20260922-1.
- **README:** Step 1.
- **Status:** todo
- **Decided:** Parse each qual with pg_query, replace each alias with the relation it stands for, and compare the pg_query fingerprints, which ignore constants. Two plans that differ only in literal values or alias names compare equal.

## Step 2: Production inventory.

### 20260922-16. Production inventory.

Check the connection to the production server and record the version, extensions, memory, planner settings, parallel settings, non-default GUCs from the plan's `SETTINGS`, `pg_database` locale fields, and `default_text_search_config`.

- **Depends on:** 20260922-4, 20260922-13.
- **README:** Step 2.
- **Status:** todo
- **Decided:**
  - Connect with the operator's own libpq setup on the jump server: the host from the input, plus `PGUSER`, `~/.pgpass`, and `~/.pg_service.conf`. QUAACK stores no credentials, and it reads inside a read-only transaction.
  - A `quaacks` config value holds a one-line shell command for finding instance memory, with the hostname filled in. The enclave script runs it on the jump server. That leaves room for any cloud provider.
- **Open questions:** What does the memory command print (bytes, or a size like `64GB`)? What happens when it isn't configured, or when it fails?

## Step 3: Schema, statistics, and classification.

### 20260922-17. 3a relations.

List the query's relations with pg_query and check each `relkind`. Abort on views and materialized views.

- **Depends on:** 20260922-14.
- **README:** 3a.
- **Status:** todo
- **Decided:** Allow only plain tables (`relkind` `r`). Abort on views, materialized views, partitioned tables, and foreign tables, and name the relation and its kind in the message.

### 20260922-18. 3b schema dump and subset.

Run the full schema-only dump on every namespace the query touches, plus `public`. Build the subset: the query's tables and their FK parent tables.

- **Depends on:** 20260922-17.
- **README:** 3b.
- **Status:** todo
- **Decided:**
  - Include the whole FK chain up, not only direct parents, so arena can satisfy every FK.
  - Don't parse the dump. Find the subset tables and their FK ancestors from `pg_catalog`, and get the subset from `pg_dump --table` for each one. This came from 20260923-1.

### 20260922-19. 3c statistics.

Pull planner statistics (including extended statistics), index definitions, and index sizes for the query's tables. Keep them in the governed store as value-class data.

- **Depends on:** 20260922-17.
- **README:** 3c.
- **Status:** todo

### 20260922-20. 3d volatility check.

Check `provolatile` for every function in the query, including the select list. Abort and name any volatile function. Reusable for rewrite candidates.

- **Depends on:** 20260922-14.
- **README:** 3d.
- **Status:** todo
- **Decided:** Yes. Resolve each operator's `oprcode` and each cast's `castfunc` in `pg_catalog`, and abort if any of them is volatile.

### 20260922-21. 3e literal set.

Build the slow, worst-case, and typical literal sets and keep them in the governed store.

- **Depends on:** 20260922-14, 20260922-19.
- **README:** 3e.
- **Status:** todo
- **Decided:** Pick values by operator.
  - **Ranges:** the worst case is the histogram bound that selects the most rows, and the typical value is the middle bound.
  - **`IN` lists:** each element follows the equality rule, and the list keeps its length.
  - **`LIKE` and any other operator:** use the slow literal in all three sets.

### 20260922-22. 3f PII and low-cardinality classification.

Classify each column as PII or not, using a configured list and a high-cardinality text heuristic. Mark low-cardinality columns (fewer than 50 distinct values, not PII). Decide which derived scalars and MCV values may leave.

- **Depends on:** 20260922-19.
- **README:** 3f.
- **Status:** todo
- **Decided:** The PII list is a set of `schema.table.column` globs, such as `*.users.email`, in the `quaacks` config file on the jump server. A text column is high-cardinality when it has 50 or more distinct values, the same line 3f uses for low-cardinality. The config can change the threshold.

### 20260922-23. 3g redaction.

Replace literals with numbered, shape-preserving placeholders. Annotate each with estimated and actual rows from the consuming plan node. Strip literals from plan quals. Keep the placeholder map in the store. Bind real literals with `PREPARE` when running placeholder queries. Make the plan redaction reusable for racetrack plans.

- **Depends on:** 20260922-13, 20260922-15.
- **README:** 3g.
- **Status:** todo
- **Decided:** Match each literal in a racetrack plan to the placeholder map by value, after normalizing casts. Replace anything still unmatched with a generic `$?` marker, so no literal leaks, and count the masks for the 15b burndown.

### 20260922-24. 3h clock anchoring.

Replace the listed time functions with `quaack.clock_anchor()` in the AST. Keep a way to put the original functions back for the report.

- **Depends on:** 20260922-14.
- **README:** 3h.
- **Status:** todo
- **Decided:** `quaacks intake` takes an optional `--captured-at` flag, the time the production plan ran. Without it, the anchor is the time of intake. The run stores the anchor, and `clock_anchor()` returns it.

## Step 4: Run server.

### 20260922-25. Run server checks.

Verify the run server: same major version and extensions as production plus HypoPG, same planner GUCs and locale settings, superuser access, no other clients, no background jobs, and autovacuum off. Abort and name the failed check.

- **Depends on:** 20260922-16.
- **README:** Step 4.
- **Status:** todo
- **Decided:** Require that `pg_stat_activity` shows no other client backends. If pg_cron is installed, also require that no job in `cron.job` is active. Document that schedulers outside Postgres are the operator's responsibility.

### 20260922-26. 4a racetrack setup.

In the restored racetrack database, create `hypopg`, the `quaack` schema, and `clock_anchor()`.

- **Depends on:** 20260922-25, 20260922-24.
- **README:** 4a.
- **Status:** todo

### 20260922-27. 4b arena setup.

Create arena from `template0` with matching locale settings, load the full schema and extensions, create `clock_anchor()`, keep `VALID` constraints, and disable user triggers only.

- **Depends on:** 20260922-25, 20260922-18, 20260922-24.
- **README:** 4b.
- **Status:** todo

## Step 5: Plan gate and index candidates.

### 20260922-28. 5 plan gate.

`EXPLAIN` the original query on the racetrack with the slow literals and compare canonical forms with the step 1 plan. On mismatch, abort and name stale racetrack statistics as the likely cause.

- **Depends on:** 20260922-26, 20260922-15, 20260922-21, 20260922-23.
- **README:** Step 5.
- **Status:** todo

### 20260922-29. 5a-4 single-candidate testing.

For each candidate: reset HypoPG, create the hypothetical index, `EXPLAIN` the query once per literal set, and record index use, cost, canonical plan, and `hypopg_relation_size`. Keep results for unused candidates. Must work for the original query and for rewrite candidates.

- **Depends on:** 20260922-26, 20260922-21, 20260922-15, 20260922-23.
- **README:** 5a-4.
- **Status:** todo

### 20260922-30. 5a-1 generator one.

Build index candidates from the parse: ranked equality columns, one range column, matching `ORDER BY` columns, a capped key, `INCLUDE` columns, every leading prefix, and BRIN on a well-correlated range column of a large table.

- **Depends on:** 20260923-11 and 20260923-14. It takes a parsed, fully qualified query and the 20260923-11 statistics input, so it doesn't need 20260922-14 or 20260922-19 to exist. Those tasks must produce the same input later.
- **README:** 5a-1.
- **Status:** in progress
- **Decided:**
  - Cap the key at three columns.
  - Emit a BRIN candidate when the range column's absolute correlation is 0.9 or more and the table's `reltuples` is at least 1,000,000.
  - All three limits are configurable.
  - The user approved building this in parallel with 20260922-31 and the main line, once 20260923-11 lands. It's a pure function over its inputs, in new files in the enclave gem.
  - Join columns: build every table's keys twice, once with its join columns counted as equality columns and once without them, then drop duplicates. A parse alone can't tell which way the join runs. On the README example this gives both `(customer_id, status, created_at)` and `(status, created_at DESC)`.
  - A column filtered only by `IS NULL` is ranked by `null_frac`, not `equality_selectivity`.
  - When the range column and ORDER BY conflict, emit two keys: equality plus range, and equality plus ORDER BY.
- **Note:** Built, fixed once, and reviewed twice, but not landed. The work is on branch `gen1-20260922-30` at `f2a1408`. The second review found an `IS NULL` in an upper join's ON that still lands on a nullable table, plus four vacuous tests. So 20260923-20 finishes the task from that branch, and both land together.

### 20260922-31. 5a-2 generator two.

Build index candidates from problem patterns in a plan. Use the production plan for the original query and the racetrack plan for rewrites.

- **Depends on:** 20260923-11, 20260923-14, and 20260923-19. It takes the production plan JSON and the 20260923-11 statistics input, so it doesn't need 20260922-13 or 20260922-19 to exist.
- **README:** 5a-2.
- **Status:** todo
- **Decided:**
  - This task covers the production plan only. Rewrites move to 20260923-12.
  - Thresholds, all configurable:
    - **Most rows:** the filter removes at least 90% of the rows scanned.
    - **Many rows:** the filter removes at least 50% of the rows scanned, and at least 1,000 rows.
    - **Expensive inner side:** inner loops times actual rows is at least 10,000.
    - **Large inner build:** the Hash node has at least 100,000 rows, or more than one batch.
  - Tests use real Postgres 18 `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` output, captured once from Docker and committed as fixtures. Don't hand-write plan JSON.
  - A partial-index candidate holds a real literal, so it's value-class data until 5a-3 filters it. Nothing here sends it anywhere.
  - **Partial-index signal:** a `col = literal` conjunct removes most rows on its own when that literal's estimated frequency, from the MCV frequencies added in 20260923-19, is at most `1 - most_rows_removed`. The user chose this after the first review found the old per-column average only fired on columns 5a-3 drops.
  - The user approved building this in parallel with 20260922-30 and the main line, once 20260923-11 lands.
- **Notes from the 20260923-14 review:**
  - `EXPLAIN` without `VERBOSE` gives `"Relation Name"` and `"Alias"` but no schema. So this task has to map each plan relation to a `TableName` itself, and handle a table name that exists in more than one schema.
  - Plan filter strings can qualify columns by alias, like `(o.a = 1)`. Strip the qualifiers before building a predicate. Postgres rejects `o.a` in `CREATE INDEX`, and `t.lag > 0` and `lag > 0` count as different definitions.
  - To extend an existing index, use `existing.with(key: ..., unique: false, sources: [...])`, as the `IndexCandidate` docs say.

### 20260922-32. 5a-3 dedupe and filter.

Normalize definitions. Drop candidates covered by an existing index or by an earlier proposal in the same search, recording the source generators and the covering index. Drop partial indexes on columns that aren't low-cardinality. Set GIN and GiST aside, untested, for step 12. Scope must be per search, so each rewrite's search is independent.

- **Depends on:** 20260922-19, 20260922-22.
- **README:** 5a-3, step 8.
- **Status:** todo

### 20260922-33. 5a-5 generator three.

Build the shape-only payload, ask the LLM for up to five candidates it hasn't seen covered, filter them through 5a-3, ask once for replacements of dropped ones, tag partial indexes, and test survivors with 5a-4. Must work for the original query and for rewrites.

- **Depends on:** 20260922-6, 20260922-5, 20260922-11, 20260922-22, 20260922-23, 20260922-29, 20260922-32, 20260923-11.
- **README:** 5a-5.
- **Status:** todo
- **Note:** The `IndexCandidate` shape from 20260923-11 only holds plain column keys. 5a-5 asks the LLM for expression indexes and operator classes such as `text_pattern_ops` and trigram GIN. So this task has to extend the shape with expression keys, opclasses, and probably collations, and teach 5a-3's dedupe to handle them.

### 20260922-34. 5a-6 refinement round.

If any LLM candidate went unused or lost to a simpler mechanical candidate, send the LLM its own 5a-4 results and ask for one revision. Filter and test what comes back. Only one round.

- **Depends on:** 20260922-33.
- **README:** 5a-6.
- **Status:** todo
- **Open questions:** How do we decide "helped less than a simpler mechanical candidate"? Simpler by column count, size, or both?

### 20260922-35. 5a-7 combination and ranking.

Combine candidates greedily up to three indexes. Rank by worst-case cost reduction across literals, and break ties by size. Keep the top three plus the best combination if it wins. Each kept entry carries DDL, size, costs per literal, canonical plan, and partial-index tag.

- **Depends on:** 20260922-29.
- **README:** 5a-7.
- **Status:** todo

### 20260922-36. Step 5 orchestration.

Wire the plan gate and 5a-1 through 5a-7 together in the driver, in the order the README gives.

- **Depends on:** 20260922-28, 20260922-30, 20260922-31, 20260922-32, 20260922-33, 20260922-34, 20260922-35.
- **README:** 5a.
- **Status:** todo

## Steps 6 and 7: Rewrite candidates.

### 20260922-37. 6a rewrite generation.

Ask the LLM for rewrites of the redacted query, each stating its transformation and every assumption it relies on. Send candidates through the inbound check.

- **Depends on:** 20260922-6, 20260922-5, 20260922-10, 20260922-18, 20260922-23.
- **README:** 6a.
- **Status:** todo
- **Open questions:** How many rewrites per run? Assumptions need a structured format for 6b to check them. What's the vocabulary (`NOT NULL`, unique, FK, anything else)?

### 20260922-38. 6b assumption check.

Check each stated assumption against `pg_constraint` and `pg_index`, treating `NOT VALID` constraints as absent. Reject candidates with unmet assumptions.

- **Depends on:** 20260922-37.
- **README:** 6b.
- **Status:** todo
- **Open questions:** What happens to an assumption the checker can't express as a catalog check?

### 20260922-39. 7 operator candidates.

Let operators submit placeholder-based rewrites through the driver. Ask the LLM to infer their transformation and assumptions, marked as inferred. Unmet inferred assumptions only add a report warning.

- **Depends on:** 20260922-37, 20260922-38.
- **README:** Step 7.
- **Status:** todo
- **Open questions:** How do operators submit them: a file, a CLI flag, or a prompt?

## Step 8: Plan-based pruning.

### 20260922-40. 8 structural discards.

Discard candidates that fail to plan on the racetrack, or whose output column count or types differ from the original. Count inbound-check rejections here too, for the report.

- **Depends on:** 20260922-10, 20260922-23, 20260922-26.
- **README:** Step 8.
- **Status:** todo

### 20260922-41. 8 mechanical index search per candidate.

For each remaining candidate, run 5a-1, 5a-2, 5a-3, and 5a-4 on its own parse and racetrack plan. Save the 5a-4 results for step 11.

- **Depends on:** 20260922-40, 20260922-29, 20260922-30, 20260922-31, 20260922-32, 20260923-12.
- **README:** Step 8.
- **Status:** todo

### 20260922-42. 8 three-configuration pruning.

`EXPLAIN` each candidate with no hypothetical indexes, with the original's top three, and with its own top three. Discard it only if its canonical plan matches the original's in all three.

- **Depends on:** 20260922-41, 20260922-35, 20260922-15.
- **README:** Step 8.
- **Status:** todo
- **Open questions:** Match against the original's plan under the same index configuration, or against the original's bare plan?

## Step 9: Predicate-aware fixtures.

### 20260922-43. 9 predicate atom extraction.

Pull every predicate atom out of the parse: equality, range, `LIKE`, `IN`, `IS NULL`, and every join condition. Give each a redacted shape for reporting.

- **Depends on:** 20260922-14, 20260922-23.
- **README:** Step 9.
- **Status:** todo
- **Open questions:** How do we handle atoms under `OR`, `NOT`, `CASE`, or subqueries?

### 20260922-44. 9 value pools.

Build each atom's pool: a satisfying value, a failing value, boundary values, pattern and case variants, `NULL` for nullable columns, and type boundary values.

- **Depends on:** 20260922-43, 20260922-21, 20260922-19.
- **README:** Step 9.
- **Status:** todo

### 20260922-45. 9 scenario builder.

Build scenarios S0 through S6 from the pools, with hit rows, one near-miss row per atom, and join partners created or withheld. Every row satisfies every `VALID` constraint.

- **Depends on:** 20260922-44, 20260922-18.
- **README:** Step 9.
- **Status:** todo
- **Open questions:** This is likely the largest task in the backlog, so we'll probably split it when we pick it up. How do we satisfy `CHECK` constraints and required columns the query never mentions?

### 20260922-46. 9a, 9b, and 9e arena transaction runner.

Open a transaction on arena with `statement_timeout`, load a fixture, run queries, and always roll back.

- **Depends on:** 20260922-27.
- **README:** 9a, 9b, and 9e.
- **Status:** todo

### 20260922-47. 9d result comparator.

Compare results using the rules for no `ORDER BY`, a partial `ORDER BY` (add a tiebreaker), `LIMIT` without `ORDER BY` (subset check), and float tolerance.

- **Depends on:** 20260922-46.
- **README:** 9d.
- **Status:** todo
- **Open questions:** What float tolerance?

### 20260922-48. 9c vacuity guard.

On S1, run the original with and without each atom replaced by `TRUE`. Retry vacuous atoms up to three times with other pool values. Mark any that stay vacuous as untested, by redacted shape.

- **Depends on:** 20260922-43, 20260922-45, 20260922-46, 20260922-47.
- **README:** 9c.
- **Status:** todo

### 20260922-49. Step 9 orchestration.

Run every scenario through 9a to 9e for each candidate, and report pass or fail with the disproving scenario.

- **Depends on:** 20260922-45, 20260922-46, 20260922-47, 20260922-48.
- **README:** Step 9.
- **Status:** todo

## Step 10: Adversarial fixtures.

### 20260922-50. 10a counterexample generation.

Ask the LLM for constraint-satisfying inserts that make a candidate and the original return different results, aimed at any untested atoms. Send them through the inbound check. Fill FK gaps by adding parent rows.

- **Depends on:** 20260922-6, 20260922-5, 20260922-12, 20260922-48.
- **README:** 10a.
- **Status:** todo
- **Open questions:** Who writes the parent rows for FK gaps: the enclave script, or the LLM on a retry? The LLM only sees shapes, so how does it write inserts that hit the real literals?

### 20260922-51. 10b and 10c compare and roll back.

Load the inserts, run the 9d comparator, recheck untested atoms with the 9c test, and roll back. Up to three rounds per candidate.

- **Depends on:** 20260922-50, 20260922-47, 20260922-48.
- **README:** 10b and 10c.
- **Status:** todo
- **Open questions:** Does a round that finds no mismatch end the rounds early, or do all three always run?

## Step 11: Per-candidate index ranking.

### 20260922-52. 11 LLM index search per candidate.

For each candidate that survived steps 9 and 10, run 5a-5, 5a-3, 5a-4, 5a-6, and 5a-7 using the step 8 results, with the candidate's plan redacted through 3g.

- **Depends on:** 20260922-33, 20260922-34, 20260922-35, 20260922-41, 20260922-51.
- **README:** Step 11.
- **Status:** todo

## Steps 12 through 14: Measurement.

### 20260922-53. 12a build and hide indexes.

Build every distinct index from 5a and step 11 with raised maintenance settings. Record built sizes. Hide them with `indisvalid`, touching only proposed non-unique indexes, and confirm with `EXPLAIN` that the right set is hidden.

- **Depends on:** 20260922-35, 20260922-52.
- **README:** 12a.
- **Status:** todo
- **Open questions:** The README hides all built indexes. I assume each measurement then unhides only its own combination. Is that right? What about the GIN and GiST candidates set aside in 5a-3?

### 20260922-54. 12b run discipline.

Run every measurement statement in a `READ ONLY` transaction with `statement_timeout`, one at a time.

- **Depends on:** 20260922-26.
- **README:** 12b.
- **Status:** todo
- **Open questions:** What timeout? What happens when a measurement times out?

### 20260922-55. 13 baseline runs.

Run the original three times per literal set with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Record total blocks and the hit-versus-read split. Mark a literal unstable if the count moves, and record each run's plan.

- **Depends on:** 20260922-53, 20260922-54.
- **README:** Step 13.
- **Status:** todo

### 20260922-56. 13a index baselines.

Repeat the baseline runs for each index combination kept in 5a.

- **Depends on:** 20260922-55.
- **README:** 13a.
- **Status:** todo

### 20260922-57. 14 candidate runs.

Run each candidate with its index combinations, using the step 13 process.

- **Depends on:** 20260922-55.
- **README:** Step 14.
- **Status:** todo

### 20260922-58. 14a and 14b metric and minimax rule.

Compare on total blocks only, with a 5% threshold. A candidate must beat the original on the slow literal and be no worse on the rest. Break ties by smallest index footprint.

- **Depends on:** 20260922-56, 20260922-57.
- **README:** 14a and 14b.
- **Status:** todo
- **Open questions:** Does "no worse" allow any increase at all, or is it within the 5% threshold?

### 20260922-59. 14c production result comparison.

Run the original and each candidate as plain queries per literal and compare in the enclave with the 9d rules. Stream and use an order-independent hash with float rounding when results are large. Mark `LIMIT` without `ORDER BY` as partial if it times out. Report any divergence prominently.

- **Depends on:** 20260922-47, 20260922-57.
- **README:** 14c.
- **Status:** todo
- **Open questions:** Which hash? A plain sum of row hashes can mask duplicates in some cases, so we should pick one carefully.

### 20260922-60. 14d selection.

Keep the top three candidates by total blocks.

- **Depends on:** 20260922-58, 20260922-59.
- **README:** 14d.
- **Status:** todo

## Step 15: Report.

### 20260922-61. Burndown counters.

Record per-stage counts (in, added, dropped by reason, out) in the governed store as each enclave step runs, and in the driver for LLM calls. Every stage task should call into this as it's built.

- **Depends on:** 20260922-3, 20260922-7.
- **README:** 15b.
- **Status:** todo
- **Note:** This should be built early, right after the foundations, even though it lives in this section.

### 20260922-62. 15 main report.

Rank candidates per literal and overall with the minimax rule. List untested atoms and whether step 10 covered them. For each index, give built size, prefix coverage, and redundancy. Explain why the winner touches fewer blocks using only plans and selectivities. Show the query with the 3h functions put back.

- **Depends on:** 20260922-60, 20260922-24.
- **README:** Step 15.
- **Status:** todo
- **Open questions:** Output format (Markdown, HTML, JSON)? Is the explanation LLM-written or templated?

### 20260922-63. 15a negative result.

When nothing beats the original, explain which rewrites were disproved and by which scenario, which indexes the planner declined, and which proposed indexes already existed.

- **Depends on:** 20260922-62.
- **README:** 15a.
- **Status:** todo

### 20260922-64. 15b burndown tables.

Render the three burndown sections from the recorded counts.

- **Depends on:** 20260922-61, 20260922-62.
- **README:** 15b.
- **Status:** todo

## End to end.

### 20260922-65. Full pipeline.

Wire every step together in the driver, from intake through the report and teardown. Run it end to end against the test harness.

- **Depends on:** 20260922-36, 20260922-39, 20260922-42, 20260922-49, 20260922-52, 20260922-64.
- **README:** All.
- **Status:** todo

### 20260922-66. Run teardown.

At the end of a run, delete the governed store directory and tell the operator to destroy the run server.

- **Depends on:** 20260922-3.
- **README:** Where QUAACK runs.
- **Status:** todo
- **Decided:** Teardown runs when a run ends, whether it succeeded or aborted. A `--keep` flag leaves the run server and store directory in place for debugging, and `quaacks teardown <run>` removes them later.

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
- **Decided:** The driver builds the `quaacks` and `quaack-protocol` gems locally, copies them to the jump server over ssh, and installs them into a user gem directory there. It checks the installed version before each run. There's no gem server.

### 20260923-3. Rename the enclave gem to quaacks. Done, see BACKLOG-COMPLETE.md.

### 20260923-4. Harden the runtime boundary check. Done, see BACKLOG-COMPLETE.md.

### 20260923-5. Discover spec suites instead of listing them. Done, see BACKLOG-COMPLETE.md.

### 20260923-7. Simplify and relax the static boundary checker.

The static checker in `spec/support/boundary.rb` is about 220 lines, is still easy to get around, and flags ordinary code the next tasks need. It flags `public_send("cmd_#{sub}")` (the natural shape of the 20260922-4 dispatcher), `define_method("step_#{n}")`, `%i[save load]`, `{ require: true }`, and `JSON.load(x)`. It also applies every rule to the driver, where loading enclave code doesn't leak production data. Cut it back:
- For the driver, a plain require check that forbids `quaack/enclave` is enough.
- For the enclave, keep plain string requires plus the shebang rule. Review whether the send, lookup, symbol, eval, and `$LOAD_PATH` rules earn their cost once 20260923-4 lands.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, findings 5 and 6.
- **README:** Where QUAACK runs.
- **Status:** todo
- **Note:** Do this before 20260922-4, or the dispatcher will trip the checker.

### 20260923-11. Index candidate and statistics shapes. Done, see BACKLOG-COMPLETE.md.

### 20260923-12. 5a-2 on rewrite plans.

20260922-31 builds generator two from the production plan only. The task also wanted it to run on rewrites, with the racetrack plan. A racetrack plain `EXPLAIN` has no actual rows and no rows removed, so most of the patterns can't fire there. Decide how the patterns work on estimates, then build it.

- **Depends on:** 20260922-31, 20260922-26.
- **Came from:** Splitting 20260922-31, at the user's request to build it early.
- **README:** 5a-2, step 8.
- **Status:** todo
- **Open questions:** Do the patterns use estimated rows in place of actual rows, or only the patterns that don't need rows removed?

### 20260923-13. Tighten the runtime boundary checker tests. Done, see BACKLOG-COMPLETE.md.

### 20260923-14. Finish the index candidate and statistics shapes. Done, see BACKLOG-COMPLETE.md.

### 20260923-15. Finish the test database harness without ForkGuard. Done, see BACKLOG-COMPLETE.md.

### 20260923-16. Harness loose ends.

Minor findings from the second review of 20260922-2:
- **Untested branches.**
  - `rescue Errno::EPERM` in the owner-pid check could return false and nothing would notice.
  - "Never build the image" survives on a machine that already has it.
- **Child specs load the root spec_helper.** Harness child processes run from the repo root, so `.rspec` loads the root `spec_helper` and `TestPostgres.configure` runs twice. The children don't prove the documented setup works on its own.
- **Slow timeout test.** The readiness-timeout test takes about 4 s. A 1 s timeout would halve that.
- **Repeated backtrace.** A memoized launch failure repeats the first example's backtrace in every later failure.
- **Old images pile up.** Each Dockerfile edit leaves an old `quaack-test-postgres:<hash>` image of about 660 MB.
- **The admin connection outlives a fork elsewhere.** Only a drop resets a dead admin connection. If a spec forks in an example with no databases of its own, every later example fails with an empty `PG::ConnectionBad`. Reset the admin connection when it's dead, or check it before reuse.
- **`WITH (FORCE)` is untested.** Removing it keeps every test green, but a spec that holds a `connect` session open would then fail with `PG::ObjectInUse`.
- **Only the first drop error is reported.** If an example leaves `admin` inside `BEGIN`, every later example fails. The admin connection is reset only for `ConnectionBad`.
- **`ConnectionLost` always blames forking,** even when the container died or the backend was terminated.
- **Faster child specs.** The `IS_TEMPLATE` and `ConnectionLost` tests could run in-process with `pg_terminate_backend` and save about 3.5 s.
- **Arena template.** Arena's template comes from `template1`, not `template0` with locale settings matching production. The real arena setup in 20260922-27 should handle this, so check it there.

- **Depends on:** 20260923-15.
- **Came from:** Both reviews of 20260922-2, and the second review of 20260923-15.
- **README:** Steps 4 and 4b.
- **Status:** todo

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

### 20260923-18. Runtime checker test loose ends.

Findings from both reviews of 20260923-13, all outside its diff:
- **Dead plants in three older tests.** In `spec/runtime_boundary_checker_spec.rb`, three tests stay green with their planted `require` deleted: "flags the driver as forbidden even when the allowlist admits it", "flags an LLM SDK by what it loads as", and "flags any file from the installed driver gem". Each adds a dependency on a gem built from source, so the every-file run flags that gem's files anyway. They aren't vacuous, since each goes red when its named rule breaks, but the plant proves nothing. Restrict each assertion to the `--version` run, or assert the planted path.
- **Failing for the right reason.** The two bare-dependency tests fail with a `KeyError` from `gem_dirs.fetch` when their dependency is removed, not on their assertion. Assert that the gem is installed first.
- **Isolation code no test watches.** In `spec/support/isolated_install.rb`, nothing tests `"GEM_PATH" => @home`, `"RUBYOPT" => nil`, `Bundler.with_unbundled_env` in `run_ruby`, or `File.realpath` in `stdlib_dirs`. Test them, or say why they're belt and braces. This overlaps with 20260923-6.

- **Depends on:** 20260923-13.
- **Came from:** Both reviews of 20260923-13.
- **README:** None. This is test infrastructure.
- **Status:** todo

### 20260923-19. MCV frequencies in the statistics input.

5a-2 needs to know how often a specific literal occurs to decide whether `col = literal` removes most rows on its own. Add the column's most-common values and their frequencies to `ColumnStatistics`, plus a helper that estimates one literal's frequency the way Postgres does. If the literal is an MCV, use its frequency. Otherwise use `(1 - sum of MCV frequencies - null_frac) / (distinct count - number of MCVs)`.

- **Depends on:** 20260923-14.
- **Came from:** First review of 20260922-31. The user chose MCV frequencies over a low-cardinality rule.
- **README:** 3c, 3f, and 5a-2.
- **Status:** todo
- **Decided:**
  - The new fields are optional, so existing callers keep working. 5a-1 is being built against this shape right now.
  - MCV values are real data, so they're value-class. `inspect`, `to_s`, `pp`, pattern matching, and every error message must redact them, the way `IndexCandidate` redacts predicates. Add sentinel tests.
  - A literal is compared to MCV values by its text form, as `pg_stats` prints them. Document what that can't match.

### 20260923-20. Finish 5a-1 generator one.

Start from the unlanded 20260922-30 branch (`gen1-20260922-30`, `f2a1408`) and fix what its second review found:
- **`IS NULL` on a nullable table (correctness).** WHERE conjuncts on a nullable table are skipped, but ON conjuncts aren't checked against nullability from lower joins. `c LEFT JOIN o ON o.customer_id = c.id JOIN i ON i.id = c.id AND o.note IS NULL` still proposes `orders (note)`, and HypoPG shows it's never used. Replace the broad rule with a narrower one. Every predicate kind 5a-1 reads is strict except `IS NULL`, and Postgres turns an outer join into an inner join and pushes a strict qual down. So skip only an `IS NULL` conjunct, in WHERE or in any ON, when it touches a table made nullable by an outer join below the place the conjunct applies. Keep the rule for ON conjuncts that touch only the preserved side of an outer join. Check the result with HypoPG, including the `o.status = 1 AND o.region = 7` case, which should now propose `orders(region, status)` or `(status, region)`.
- **Vacuous tests.**
  - The three-column tie-break tests stay green without their position terms. Fold them into the 50-column tests or delete them.
  - The ordinal-after-star test only puts the star first. Add `SELECT id, *, created_at ... ORDER BY 3 DESC`.
  - The filter-plus-join test reads the filter before the join. Add a fixture with the join written first.
- **Untested code.**
  - `pinned?` survives as `kinds.first == :one`. Add a test that mixes predicate kinds on one column.
  - Two CTE scoping mutants survive: outer scope inside CTE bodies, and forward references under `WITH RECURSIVE`.
  - `cap.is_a?(Integer)` survives.

- **Depends on:** 20260922-30 (unlanded branch).
- **Came from:** Second review of 20260922-30, findings 1, 3, 4, and 5.
- **README:** 5a-1.
- **Status:** in progress

### 20260923-21. 5a-1 loose ends.

Minor findings from the reviews of 20260922-30:
- An ORDER BY on a nullable-side table's columns becomes a key, such as `LEFT JOIN o ... ORDER BY o.created_at`. The table can't be the outer side, so the index is wasted.
- `FOR UPDATE OF o` is falsely refused as an unqualified relation.
- `(o).*` isn't recognized as a star, for ordinals or INCLUDE.
- Column alias lists like `AS o(a, b)` aren't modeled.
- `col = NULL` yields a candidate.
- INCLUDE covers only the select list and GROUP BY, so index-only scans are rare.
- A prefix LIKE needs `text_pattern_ops` unless the collation is C.
- Incremental sort isn't handled.

- **Depends on:** 20260923-20.
- **Came from:** Both reviews of 20260922-30, and its builder's notes.
- **README:** 5a-1.
- **Status:** todo

## After version 1.

These tasks are worth doing, but they don't block version 1. Pick them up after the full pipeline (20260922-65) works.

### 20260923-6. Test the runtime check's environment scrubbing.

Removing `GEM_PATH` or `RUBYLIB` from the isolated environment in `spec/support/isolated_install.rb` stays green. Without `GEM_PATH`, RubyGems can see the user and Homebrew gem directories. Also consider `RUBYGEMS_GEMDEPS` and `HOME` (for `~/.gemrc`). Plant a leak for each and prove the check goes red. Also check that closure gems like `quaack-protocol` load from the installed copy, not the repo.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, finding 4.
- **README:** None. This is test infrastructure.
- **Status:** todo

### 20260923-8. Unit-test the RepoGems helper.

`spec/support/repo_gems.rb` finds each repo gem's gemspec for the boundary and runtime specs, but its lookups have no direct tests:
- **The one-gemspec guard is untested.** Loosening `paths.size == 1` to `>= 1` in `RepoGems.gemspec` keeps every spec green. Only `enclave/` has its own "exactly one gemspec" test. If `driver/` or `protocol/` gained a second gemspec, `paths.first` could quietly pick the wrong one. Test the guard with two gemspecs planted in a temp directory.
- **One test repeats another.** `spec/repo_gems_spec.rb` checks that the enclave gemspec is named `quaacks`, which `enclave/spec/gemspec_spec.rb` already checks. Replace it with direct tests of `RepoGems.gemspec` and `gemspec_path_of`.
- **Noisy failures.** `enclave/spec/gemspec_spec.rb` loads its gemspec with `Gem::Specification.load` instead of `RepoGems.load`. A broken gemspec makes most of its examples fail with a `NoMethodError` on nil instead of one clear message.

- **Depends on:** 20260923-3.
- **Came from:** Second review of 20260923-3, minor findings 1 through 3.
- **README:** None. This is test infrastructure.
- **Status:** todo

### 20260923-9. Close the test gaps in the spec task guards.

Task 20260923-5 made `rake spec` find the suites itself, run them all, and fail if the root suite didn't run. The second review found that the guards work today, but some mutants of them still pass every test:
- **The root guard is only tested by changing SPEC_SUITES.** The test in `spec/rakefile_spec.rb` swaps `SPEC_SUITES` for `%w[foo]`. So a guard that checks `SPEC_SUITES` instead of what actually ran also passes. Combined with a later `drop(1)` in the loop, full `rake` goes green with no root suite. Add a test where `SPEC_SUITES` still includes `"."` but the loop skips it.
- **Nothing tests a suite that can't start.** When `sh` can't start the command, `ok` is nil. Changing `unless ok` to `if ok == false` keeps every test green, and then a missing interpreter makes `rake spec` pass with zero examples run. Also, `ran` records a suite as run even when it never started. Test both.
- **Output is hard to use.** The echoed command has no shell quoting, so you can't paste it to rerun one suite. A suite that can't start is reported only as `Spec suites failed: x/spec`, with no reason or exit status.
- **The Rakefile comment oversells the guard.** It says the guard catches "a loop that skips a suite", but that holds only for the root suite.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, findings 1, 2, 4, 5, and 6.
- **README:** None. This is test infrastructure.
- **Status:** todo

### 20260923-10. Stop local RSpec options from filtering out boundary specs.

RSpec reads `.rspec-local`, `~/.rspec`, and `SPEC_OPTS`. None of them are in the repo, and `.rspec-local` isn't gitignored. A `.rspec-local` with `--exclude-pattern "**/boundary*_spec.rb"` made full `rake` pass with a planted enclave dependency on `quaack-driver`. The root suite ran 20 examples instead of 61. Local `rake` is the only check, so a personal options file can quietly turn off the trust-boundary checks. Make the spec task ignore local and personal RSpec options, or check that the boundary specs actually ran, and test it with a planted exclusion.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, finding 3.
- **README:** Where QUAACK runs.
- **Status:** todo
