# QUAACK: Query Upgrade Automation Assisted by Chaos and Knowledge

QUAACK takes a slow production query and works through it in stages. It proposes rewrites and indexes, throws out any rewrite that changes the query's results, and then ranks the rest by how many buffers they touch on a restored clone of production.

## Trust boundary.

QUAACK splits data into two classes. The code enforces the line between them. It doesn't rely on people following a convention.

**Values never leave the production enclave.** These values never reach an engineer's workstation:

- Literals from the query.
- `most_common_vals` and `histogram_bounds`.
- Fixture contents.
- Result rows.

**Shapes may leave.** These can leave the enclave and go to the engineer's machine and from there to an LLM:

- Relation and column names.
- Types.
- Constraint and index definitions.
- Plan structure, with literals stripped out.
- Derived scalars: `n_distinct`, `null_frac`, `correlation`, and MCV frequencies (without the values they belong to).
- MCV values for low-cardinality columns only, as defined in 3f. These are the one exception to "values never leave," and they exist so the LLM can write partial index predicates.

For version 1, we assume the schema dump and partial index predicates contain no PII, and we treat them as shape data. A schema-only dump can still hold literals in `CHECK` constraints, column defaults, comments, and function bodies. Revisit this assumption before using QUAACK on a schema where that isn't true. Partial index predicates are safer, because QUAACK only allows them on low-cardinality columns (see 5a-3).

Everything that leaves the enclave goes through one egress function, and that function only accepts fields on a whitelist. If a field isn't on the whitelist, it isn't sent at all. We don't scrub it and send it anyway. Adding a field to the whitelist is the single place where this policy gets reviewed.

### Where QUAACK runs.

QUAACK has two parts:

- **The driver** runs on a engineer's laptop, outside the production enclave. It runs the steps in order, makes every LLM call, and builds the report. It never holds a production value.
- **The enclave script** runs on the production enclave's jump server. It's a stateless command-line script, not a long-running service. It does everything that touches a database or a real value, and it only runs when and how the driver calls it.

The driver calls the enclave script over ssh, passing a subcommand for the step to run plus its arguments. The script reads what it needs from the governed store, does the work, writes any new state back to the store, and prints its result. Nothing stays in memory between calls.

Access control comes from ssh. Anyone who can ssh into the jump server already has production access, so they can run the enclave script too. There's no separate login or service to secure.

Everything the enclave script prints goes through the egress function, including error messages. Postgres errors can include real values, such as the key in a unique-violation message, so errors get filtered too. That's where the trust boundary is enforced. 

**What goes into the enclave**, from the driver to the enclave script:

- Requests to run a step.
- Rewrite candidates, written with placeholders instead of literals.
- Index DDL.
- The LLM-generated inserts from step 10.

All of this came from an LLM or a laptop, so the enclave script treats it as untrusted. Before running any of it, the script parses it with pg_query and rejects anything that isn't what it claims to be:

- **Rewrite candidates** must be exactly one `SELECT` statement. Reject data-modifying CTEs (`WITH ... DELETE`), `SELECT INTO`, and locking clauses like `FOR UPDATE`. A candidate that uses a construct outside the supported SQL list (see step 1) is refused too. Also run the volatility check from step 3d on the candidate, so it can't call a function with side effects.
- **Index DDL** must be exactly one `CREATE INDEX` statement on a table the query uses.
- **Step 10 inserts** must be plain `INSERT` statements into tables in the subset schema from step 3b.

A rejected input fails with a message that says which rule it broke. The script then runs the accepted input only in the ways the steps below describe.

**What comes out**, from the enclave script to the driver, is shape-class data only:

- The redacted query and redacted plans from step 3g.
- The subset schema from step 3b and the existing index definitions from step 3c.
- The derived scalars and low-cardinality MCV values from step 3f.
- Costs, estimated and built index sizes, block counts, and whether the planner used each index.
- Pass or fail results, with the scenario or predicate atom behind each failure.
- Which predicate atoms step 9c couldn't exercise, identified by their redacted shape.
- Counts of what each stage added and dropped, for the 15b burndown.
- Production's major version, and whether step 2 found its instance memory.

Result rows, fixture contents, and literals never come out.

**Which part runs each step:**

- **The enclave script** runs steps 1 through 4, step 5, 5a-1 through 5a-4, 5a-7, 6b, step 8, step 9, 10b, 10c, the re-ranking in step 11, and steps 12 through 14.
- **The driver** runs 5a-5, 5a-6, 6a, step 7, 10a, generator three in step 11, and step 15. These are the steps that talk to an LLM or an operator, plus the report.

Inside the enclave, the enclave script keeps its data in three places:

| Part | What it holds | Where it lives | Used in |
| --- | --- | --- | --- |
| Governed store | The step 1 inputs, the set of literals from step 3e, the placeholder map from 3g, the raw statistics from 3c, and every intermediate result between calls. | A directory on the jump server in the operator's home directory. | Every step. |
| Racetrack | A full restore of production, with everything production has. | The run server. | Steps 5, 5a, 8, and 11 for hypothetical-index planning. Steps 12 through 14 for measurement. |
| Arena | An empty copy of the schema in an independant db, loaded with generated fixtures inside transactions that get rolled back. | The run server. | Steps 9 and 10. |

All three hold production values, so treat them like production: same access controls, same encryption at rest, same auditing, and same retention limit.

When the run ends, destroy the run server and delete the run's governed store directory. Nothing in either is worth keeping as a cache. `quaacks teardown --run <run ID>` deletes the store directory and prints a reminder to destroy the run server, which the enclave can't do itself. Running it on a run that's already gone succeeds. It won't delete a run path that's a symlink or isn't a private run directory (a real directory, mode 0700, owned by the current user). If `~/.quaack` or `~/.quaack/runs` is a symlink, every `quaacks` step that uses the store refuses it with the rule `bad_store_base`, and nothing is made or deleted through it.

## 1. Input.

QUAACK takes three inputs:

- The query text.
- The full output of `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` for that query.
- The production server name the explain plan came from.

The operator finds the slow query and puts these inputs in the governed store on the jump server. They never pass through the laptop, because the query text and the plan both contain real literals. The driver only ever sees the redacted versions from 3g.

To do that, the operator saves the query and the plan as files on the jump server and runs `quaacks intake --query <file> --plan <file> --server <name>`. It checks that each input is well formed, starts a run in the governed store that holds them, and prints only the run's ID for the driver to use. An optional `--captured-at <time>` gives the time the production plan ran, as an ISO-8601 time with a zone, for 3h. Without it, the run anchors the clock at the time of intake. A refused input leaves no run behind, and its error names only the rule it broke.

The query can only use the SQL constructs QUAACK supports. A query that uses anything else is refused, with the rule `unsupported_construct`. For v1, the operator sees only that rule. The error line doesn't say which construct it was. The list lives in `SupportedSql` (`enclave/lib/quaack/enclave/supported_sql.rb`). It covers `SELECT` with joins, subqueries, CTEs (but not `CYCLE` or `SEARCH`), set operations, `CASE`, aggregates, window functions, the usual operators, casts, `IN`, `ANY`, `LIKE`, `BETWEEN`, and `IS NULL`. Every enclave step that walks the query's parse checks it against the list first, so each one only has to be right for what's on it. Today those are relation qualification in this step, the volatility check in 3d, generator one in 5a-1, and the predicate atoms in step 9. The plan's expressions and index predicates aren't the query, so they aren't checked against the list.

Fully qualify every relation in the query so `search_path` never matters.

This step also defines the **canonical plan form** that every later step uses to compare plans. A canonical plan keeps each node's type, relation, index, join type, strategy, quals, and sort keys. It strips costs, row counts, buffers, and aliases.

## 2. Production inventory.

Validate the connection to step 1's production server. Then record the following from it:

- Major version.
- Installed extensions.
- Instance memory.
- `shared_buffers`, `effective_cache_size`, `work_mem`, `random_page_cost`, and `jit`.
- `TimeZone`, `DateStyle`, `IntervalStyle`, and `default_statistics_target`, which change plans or how a literal is read, but which `SETTINGS` never lists.
- Every parallel setting.
- Every non-default planner GUC listed in the `SETTINGS` section of the input plan.
- From `pg_database`: `datcollate`, `datctype`, `datlocprovider`, `datlocale`, and `datcollversion`.
- `default_text_search_config`.

The driver runs `quaacks inventory --run <run ID>`. It connects to the server named at intake with the operator's own libpq setup on the jump server. The host comes from the run, and everything else comes from where libpq looks for it: `PGUSER` and the other `PG` environment variables, a service in `~/.pg_service.conf` named by `PGSERVICE`, and the password in `~/.pgpass`. QUAACK stores no credentials. It reads everything inside one read-only, repeatable read transaction, so it can't write to production. Production must run Postgres 17 or later, since older versions don't have `datlocale`.

For each setting the plan's `SETTINGS` lists, it records production's own current value, not the value in the plan, which came from the operator's session. It records settings the way `SHOW` prints them, such as `128MB`.

The instance memory comes from a command the operator configures, since Postgres can't report it and every cloud provider finds it differently. The command lives in the `quaacks` config file on the jump server, `~/.quaack/config.json`, under the key `memory_command`:

```json
{ "memory_command": "aws rds describe-db-instances ... {host} ..." }
```

It's one line of shell. Each `{host}` becomes the production host, quoted as one shell word, and `/bin/sh -c` runs it with no stdin, throwing its stderr away. It must print the memory as a whole number of bytes, or as a whole number and a unit: `kB`, `MB`, `GB`, `TB`, `KiB`, `MiB`, `GiB`, or `TiB`, in any case, with an optional space. Every unit is binary, as in Postgres, so `64GB` is 64 × 1024³ bytes. The command gets 30 seconds, and a timeout stops everything it started.

- With no config file, or no `memory_command` in it, the step records the memory as unknown and carries on. Later steps that need it refuse clearly.
- A command that fails aborts the step with `memory_command_failed`, one that runs too long with `memory_command_timed_out`, and one whose output isn't a size with `memory_command_bad_output`. The command's output never appears in any message.
- A config file that's a symlink, isn't a readable regular file, isn't a JSON object, or has a `memory_command` that isn't one non-blank line is refused as `bad_config`, before the step connects.

Failing to connect is `production_connection_failed`. A Postgres error while reading is `production_read_failed`, with its SQLSTATE. Neither error names the host, the user, or the server's message. Nothing is recorded unless the whole step succeeds.

The inventory stays in the governed store. The step prints only its shape: production's major version and whether the memory is known.

## 3. Schema, statistics, and classification.

### 3a. Relations.

Use pg_query to list the relations the query uses, and check the `relkind` of each one. For now, only plain tables (`relkind` `r`) are allowed. Abort if the query uses anything else, such as a view, a materialized view, a partitioned table, or a foreign table. The error's rule names the kind, such as `view_relation`. Don't handle partitioning until we need it.

The driver runs `quaacks qualify --run <run ID>`, which does step 1's qualification and this check together. It connects to the run's production server the way step 2 does, with the operator's own libpq setup, and reads only the catalog. It resolves each unqualified name through the `search_path` in the input plan's `SETTINGS`, or the default `"$user", public` without one. It stores the qualified query as the run's `qualified_query` entry, and the relations, each once and in the order the query first names them, as `relations`, a list of `{"schema", "name"}` objects. Later steps of 3 read both from there. It prints nothing but its done line, since the driver sees the schema only as 3b's subset. A refusal names only its rule, such as `view_relation`, `unknown_relation`, `unsupported_construct`, or `production_connection_failed`, and stores nothing.

### 3b. Schema dump.

Run `pg_dump --schema-only --no-owner --no-privileges` on every namespace the query touches. Always include `public` in the list of namespaces, even if the query doesn't reference it.

Separately, build a smaller subset: the query's tables plus their FK parent tables. This subset is the only schema that the LLM and the fixture generator ever see.

The driver runs `quaacks schema-dump --run <run ID>` after `quaacks qualify`. It reads the run's `server` and `relations` entries. It connects to the production server the way step 2 does and reads the catalog inside one read-only transaction. It runs the jump server's `pg_dump` from `PATH`, given only the run's host, so the port, user, database, and password come from the operator's own libpq setup. That `pg_dump` must be at least the server's major version. It stores the full dump as `schema_dump`, `{"namespaces", "ddl"}`, for 4a, and the subset as `schema_subset`, `{"tables", "ddl"}`, where `tables` lists each `[schema, name]`. It prints nothing but its done line: the subset reaches the LLM only in 5a-5's payload, which reads it from the store. A refusal names only its rule, such as `unknown_relation`, `pg_dump_missing`, `pg_dump_too_old`, `pg_dump_failed`, `production_connection_failed`, or `production_read_failed`, and stores nothing.

### 3c. Statistics.

Pull planner statistics for the query's tables and their indexes, including extended statistics. Also pull current index definitions and sizes, which the report uses for its redundancy check.

These statistics include real values in `most_common_vals` and `histogram_bounds`. That makes them value-class data under the trust boundary, so they stay in the governed store.

Leave out invalid indexes (`indisvalid` false), such as one left by a failed `CREATE INDEX CONCURRENTLY`, so step 5a-3 doesn't count one as covering. This step also records which columns have a text-like type, for step 3f's heuristic.

The driver runs `quaacks statistics --run <run ID>` after `quaacks qualify`. It reads the run's `server` and `relations` entries, so it covers the query's own tables, not 3b's FK parents. It connects to the production server the way step 2 does and reads the catalog and `pg_stats` inside one read-only transaction. It stores the result as the run's `statistics` entry, `{"tables"}`, one object per table in `relations` order with its row count, columns, text-like columns, `pg_stats` rows, valid indexes with their definitions and sizes, and extended statistics. Generators one and two, Dedupe, and 3f read it from there. It stores nothing until the transaction has closed, and prints nothing but its done line. A refusal names only its rule, such as `unknown_relation`, `inheritance_parent`, `production_connection_failed`, or `production_read_failed`, and stores nothing.

Unsupported in v1: a table with inheritance children is refused with `inheritance_parent`, because `pg_stats` keeps two rows for each of its columns and QUAACK doesn't choose between them. The element and range statistics in `pg_stats` and the statistics on expressions in `pg_stats_ext_exprs` aren't read.

### 3d. Function volatility.

Check `provolatile` for every function anywhere in the query, including the select list. If any function is volatile, abort and say which function caused it. A volatile function breaks both rewriting and result comparison.

The driver runs `quaacks volatility --run <run ID>` after `quaacks qualify`. It reads the run's `server`, `plan`, and `qualified_query` entries. It connects to the production server the way step 2 does and reads only the catalog, inside one read-only transaction, resolving unqualified function names through the `search_path` in the input plan's `SETTINGS`, or the default without one. This step is a gate, so all it stores is that the query passed: the run's `volatility` entry, `{"passed": true}`, which later steps can require before they run the query. It stores nothing until the transaction has closed, and prints nothing but its done line. A refusal names only its rule, such as `volatile_function`, `unsupported_construct`, `production_connection_failed`, or `production_read_failed`, and stores nothing. For v1 the operator's error line doesn't say which function it was, since error lines carry only the step, rule, and SQLSTATE.

### 3e. Literals.

Build the literal set that later steps test against. It has three literals:

- The **slow** literal(s), which is the set of literals in the input query itself.
- A **worst-case** literal, taken from the top MCV of each equality column.
- A **typical** literal, taken from a histogram bound.

This literal set is value-class data, so it stays in the governed store. QUAACK runs these values on the racetrack and in arena. No LLM ever sees them.

Each set is keyed by the 3g placeholder numbers, in the same form as the placeholder map, so any set binds the same way the slow values do. Values come from the step 3c statistics for the column each placeholder is compared with, picked by operator:

- **Equality (`=`):** the worst case is the top MCV, and the typical value is the middle histogram bound.
- **Ranges (`<`, `<=`, `>`, `>=`):** the worst case is the histogram bound that selects the most rows: the last bound for `<` and `<=`, and the first for `>` and `>=`. The typical value is the middle bound. For `BETWEEN`, the worst case is the first and last bounds, and the typical value is the middle bucket: the middle bound and the one after it. A lower bound (`>` or `>=`) and an upper bound (`<` or `<=`) on one column in the same `AND`, such as `created_at >= $1 AND created_at < $2`, are treated like `BETWEEN`, whichever side the column is written on. A range on its own keeps the single-bound rule.
- **`IN` lists and `= ANY`:** the list keeps its length. In the worst case, each element takes the next most common value. In the typical set, the elements take consecutive bounds around the middle.
- **`LIKE` and any other operator,** including `<>`, `NOT IN`, and `NOT BETWEEN`: the slow literal in all three sets.

A picked value keeps the placeholder's declared type. A number placeholder widens to `bigint` or `numeric` when the value needs it, such as `20` against a numeric column.

When a set can't get a value, the placeholder keeps its slow literal there, and the store records why. That happens when the column has no statistics, or lacks the MCV list or histogram the pick needs, or when a value doesn't read as the placeholder's type. Unsupported in v1, these also keep the slow literal in all three sets:

- A placeholder that isn't compared directly with a plain table column, such as one compared with an expression or function on the column (`lower(email) = $1`), a column of a subquery or CTE, or a join column reached through a subquery. A placeholder outside any predicate, such as a `LIMIT`, also falls in this group.
- A cast placeholder, such as `DATE '2026-01-01'`, which 3g keeps as `$1::date`.
- A placeholder that 3g shares between expressions, since it can feed more than one place.

The driver runs `quaacks literals --run <run ID>` after `quaacks redact`, since the sets are keyed by 3g's placeholders. It refuses with the rule `volatility_not_passed` unless the run's `volatility` entry shows that 3d passed. It reads the run's `placeholder_map`, `redacted_query`, and `statistics` entries, and doesn't connect to production. It stores one entry, `literal_sets`: the three sets and the fallbacks. It sends none of it and prints nothing but its done line. A missing entry fails with only its rule and stores nothing.

### 3f. PII classification.

Classify each column as PII or not PII. Use a configured list plus a heuristic that flags high-cardinality text columns.

- The configured list is `pii_columns` in the `quaacks` config: `schema.table.column` globs, such as `*.users.email`. A `*` matches within one name part and never crosses a dot. Matching ignores case, so a glob can only match more columns, never fewer.
- The heuristic flags a column whose type is text-like (text, varchar, char, name, citext, or a domain over one) and that has 50 or more distinct values. A text column whose distinct count is unknown, because it was never analyzed, counts as PII too.
- The config's `cardinality_threshold` moves the line of 50, here and for low-cardinality below.

This classification doesn't decide whether values get sent, because no values are ever sent. Instead, it controls which derived scalars go out:

- For a PII column, also withhold the MCV frequencies. A frequency vector plus a column name can be enough to re-identify values in a small domain.
- For every column, PII or not, still send `n_distinct`, `null_frac`, and `correlation`. A single number that summarizes a whole column reveals nothing about any one row.

This step also marks each column as **low-cardinality** or not. A column is low-cardinality when it has fewer than 50 distinct values, isn't classified as PII, and its `n_distinct` in `pg_stats` is positive. Count distinct values the same way as step 5a-1: if `n_distinct` is negative, take its absolute value times `reltuples`. ANALYZE stores a positive `n_distinct` only when the distinct values are at most about a tenth of the rows, so each value repeats. A negative, zero, or unknown `n_distinct` means the column isn't low-cardinality, even with few distinct values. A 40-row table of emails has fewer than 50 distinct values, but they don't repeat, so they aren't categories. For a low-cardinality column, also send its MCV values. A column with that few values, like a status or type column, holds categories, not facts about individual people. Columns with more distinct values are where PII starts to show up, so their values never go out. Histogram bounds never go out for any column.

The driver runs `quaacks classify --run <run ID>` after `quaacks statistics`. It reads the `quaacks` config and the run's `statistics` entry, and doesn't connect to production. It stores the run's `classification` entry, `{"columns", "outbound_statistics"}`: each column's schema, table, name, and whether it's PII and low-cardinality, plus the statistics that may go out. For each column, `outbound_statistics` holds `n_distinct`, `null_frac`, and `correlation`, plus the MCV frequencies (null for a PII column) and the MCV values (null unless the column is low-cardinality). Dedupe (5a-3) reads the low-cardinality columns from there. The step sends none of it and prints nothing but its done line. The 5a-5 payload step sends `outbound_statistics` as part of the payload, so the data leaves only when the LLM needs it. A missing `statistics` entry or a bad config fails, and stores nothing.

This step stores the classification and the statistics that may go out in the governed store. It doesn't send them. The 5a-5 payload step does.

### 3g. Redaction.

Produce a redacted query and a redacted production plan. These redacted versions are what the driver gets, and what every LLM call uses.

- Replace each literal with a numbered placeholder. The placeholder keeps the literal's shape, such as a leading versus trailing wildcard, or a numeric versus text type.
- Give each literal its own placeholder, except where Postgres requires two expressions to match. There, equal literals in the same places of the same expression share one placeholder, because Postgres compares the expressions after binding and won't treat `$1` and `$2` as equal. These are the places:
  - A GROUP BY expression and the same expression in the select list, HAVING, or ORDER BY.
  - DISTINCT ON and ORDER BY.
  - SELECT DISTINCT and ORDER BY.
  - An aggregate's DISTINCT arguments and its ORDER BY.

  A GROUP BY, DISTINCT ON, or ORDER BY key written by position or by alias, such as `GROUP BY 1`, stands for its select-list entry. A key that's a whole subquery shares the subquery's literals too. The search for the key's copies covers everything in the other clause, including aggregate arguments and FILTER. That can share a few more literals than Postgres needs, but they always hold equal values, so the query means the same. A key written differently from its copy, such as `status` against `o.status`, isn't found, and the query fails to prepare.

  A shared placeholder gets its row counts the same way as any other. When the quals of more than one node hold it, its row counts are marked ambiguous.
- Annotate each placeholder with two row counts from the step 1 plan, taken at the node that consumes it: the planner's estimated rows and the actual rows.
- Strip literal values out of the plan's quals the same way.

Keep a one-to-one placeholder map in the governed store. The map is value-class data too, so it never leaves. Any plan that leaves the enclave later, including plans from the racetrack, goes through this same redaction first.

Rewrite candidates arrive from the driver with placeholders. When the enclave script needs to turn one into a runnable query, use `PREPARE` and bind the real literals as parameters. Never splice strings.

The driver runs `quaacks redact --run <run ID>` after `quaacks classify`. It reads the run's `qualified_query` and `plan` entries, and doesn't connect to production. It stores four entries: `placeholder_map`, which holds the literals and never leaves; `placeholder_shapes`, each placeholder's shape and row counts; `redacted_query`, the qualified query with a placeholder in place of each literal; and `redacted_plan`, `{"explain", "masked", "dropped"}`, the step 1 plan with its literals stripped. The step sends none of them and prints nothing but its done line. The 5a-5 payload step sends the redacted query, plan, and shapes. It computes everything before it writes, so a missing entry or a query it can't redact, such as one with `$n` parameters of its own, fails with only its rule and stores nothing.

### 3h. Clock anchoring.

In the AST, replace each of these with a schema-qualified call to `quaack.clock_anchor()`:

- `now()`
- `transaction_timestamp()`
- `statement_timestamp()`
- `current_timestamp`
- `current_date`
- `localtimestamp`
- `localtime`

Leave all other stable functions alone. The step 15 report shows the query with the original functions put back.

The driver runs `quaacks anchor --run <run ID>` after `quaacks redact`. It reads the run's `redacted_query` entry and the `search_path` in its `plan` entry's settings, and doesn't connect to production. It stores two entries: `anchored_query`, the redacted query with its clock anchored, which the run server runs in step 4 and 5a-4; and `clock_replacements`, `{"replacements", "added_names"}`, each replaced function and each column name anchoring added, which the step 15 report uses to put the originals back. The literal sets and placeholder map hold values, not clock functions, so they don't change. The step sends none of it and prints nothing but its done line. It computes everything before it writes, so a missing entry or a query it can't anchor fails with only its rule and stores nothing.

## 4. Run server.

The operator builds one server for each run of QUAACK. It must meet all of these requirements:

- Running the same major version and extensions as production, plus HypoPG.
- Using the same planner GUCs and locale settings recorded in step 2.
- Superuser access.
- No clients other than QUAACK.
- No background jobs, and autovacuum turned off. A background `ANALYZE` would change the statistics partway through the run.

Verify every requirement. If any check fails, abort and name the check that failed.

The checks compare the run server with step 2's inventory. A planner setting is any setting `EXPLAIN`'s `SETTINGS` would list, any Query Tuning setting, and `TimeZone`, `DateStyle`, and `IntervalStyle`. Production's value of one is the value step 2 recorded, if it recorded one. Otherwise it's the built-in default, since `SETTINGS` lists every setting that differs from it. The database's name can differ from production's. For quiet, `pg_stat_activity` must show no client other than QUAACK, and if pg_cron is loaded, it must run its jobs from this database and have none active. Schedulers outside Postgres, such as a cron job on another host that connects later, are the operator's to turn off. The error names only the check, such as `run_server_guc_mismatch`.

Unsupported in v1: per-tablespace `random_page_cost` and `seq_page_cost` aren't compared, since step 2 doesn't record them.

The driver runs `quaacks run-server --run <run ID> --host <host> --port <port> --racetrack-db <name> --arena-db <name>`. It connects to the racetrack database with the operator's own libpq setup, as step 2 does for production: the user comes from `PGUSER` or a service in `~/.pg_service.conf`, and the password from `~/.pgpass`. QUAACK stores no credentials. It runs the checks there and nowhere else. Arena doesn't exist yet, since 4b makes it, and the quiet checks already see every database on the server. If every check passes, it records the host, the port, and both database names in the run, and later steps connect with them. It prints nothing but its done line.

It refuses rather than guesses. The host must be a hostname or an IPv4 address (`bad_run_server_host`), the port a whole number from 1 to 65535 (`bad_run_server_port`), and each database name a plain identifier of letters, digits, underscores, and hyphens, up to 63 characters (`bad_run_server_database`). The racetrack and arena must be different databases (`run_server_same_database`). A run with no step 2 inventory is refused with `run_server_no_inventory`, and failing to connect is `run_server_connection_failed`. None of these errors names the host, the user, or a database. Nothing is recorded unless the whole step succeeds. Unsupported in v1: Unix socket paths, IPv6 addresses, and other database names.

### 4a. Racetrack.

The racetrack is a clone of production, restored from a production backup at full size. QUAACK never generates its data. Synthetic data can't reproduce production's physical layout: row width, page density, index depth, and how closely heap order matches index order. That layout decides how many blocks a plan touches. Matching production byte for byte is the whole point of the racetrack.

The restore also brings production's statistics with it. That's why the racetrack can do the hypothetical-index planning too. No separate statistics-only database is needed.

In the racetrack database:

1. Create the `hypopg` extension.
2. Create a schema named `quaack` and a function `clock_anchor()`. The function returns `timestamptz`, is marked `STABLE`, and returns the capture time from 3h.

The driver runs `quaacks racetrack-setup --run <run ID>` after `quaacks run-server`. It refuses a run with no recorded run server, then connects to the recorded racetrack database and does both steps above, with the run's `clock_anchor` entry. A `quaack` schema that already holds anything else fails the step and changes nothing. Only when setup succeeds does it store `racetrack_setup`, a marker that later racetrack steps require. It prints nothing but its done line, and a failure names only its rule.

The racetrack holds real production data, including PII. Nothing read from it ever leaves the enclave without going through 3g redaction first.

### 4b. Arena.

Arena is a second database on the same server. Set it up like this:

1. Create it from `template0`. Set `LOCALE_PROVIDER`, `LC_COLLATE`, `LC_CTYPE`, and `ICU_LOCALE` to match step 2. Do this before you load the schema dump.
2. Load the full schema and the extensions from 3b.
3. Create the `quaack` schema and `clock_anchor()` function, the same way as in the racetrack.
4. Keep all `VALID` constraints.
5. Disable user triggers only, so FK triggers still fire.

Arena's job is to disprove rewrites, not to measure them. Step 9 generates its fixtures from the query's predicate structure. Every fixture load happens inside a transaction that gets rolled back, so arena stays empty between tests.

Arena shares the server with the racetrack, and its activity can change what's in the cache. That only affects the hit-versus-read split, which is a secondary measure. Total blocks don't depend on the cache.

## 5. Plan gate.

`EXPLAIN` the original query on the racetrack with the slow literal(s). Compare its canonical form with the step 1 plan. If they differ, abort.

A mismatch usually means the racetrack's statistics don't match production's. For example, the backup might be older than the statistics from 3c. The abort message should name that as the likely cause.

This gate stops QUAACK from confidently optimizing against a racetrack that doesn't behave like production.

### 5a. Index candidates.

This step uses HypoPG to find index candidates for the original query on the racetrack. Everything here is based on estimates, because HypoPG only works during plain `EXPLAIN`, not `EXPLAIN ANALYZE`. Every literal used here comes from the set of literals defined in step 3e.

Three different generators propose candidate index definitions. The steps run in this order:

1. The two mechanical generators, 5a-1 and 5a-2, propose candidates.
2. The 5a-3 filter removes duplicates and anything already covered.
3. 5a-4 tests each surviving mechanical candidate on its own.
4. The LLM generator, 5a-5, sees those test results and proposes candidates that the mechanical generators missed. Its candidates go through the same filter and the same testing.
5. If any LLM candidate fell short, 5a-6 gives the LLM one chance to revise.
6. 5a-7 combines and ranks every candidate that survived, whichever generator it came from.

#### 5a-1. Generator one: from the parse.

For each table in the query:

1. Use pg_query to collect the columns that appear in equality predicates, range predicates, join conditions, `ORDER BY`, `GROUP BY`, and the select list.
2. Rank the equality columns by selectivity using `pg_stats`. Watch out: a negative `n_distinct` means it's a fraction of the row count. Convert it by taking the absolute value times `reltuples`, then discount by `null_frac`.
3. Build the index key in this order:
   - Equality columns, most selective first.
   - At most one range column.
   - The `ORDER BY` columns, but only if they come after the equality columns and their sort directions match. That lets the planner drop the sort.
4. Cap the key at three or four columns.
5. Add the rest of the select-list columns as `INCLUDE` columns so an index-only scan becomes possible.
6. Also emit every leading prefix of the key as a separate candidate.
7. If the range column's `pg_stats` correlation is close to 1 or -1 and the table is large, also emit a BRIN candidate on that column.

#### 5a-2. Generator two: from the plan.

Use the production plan from step 1, not a plain `EXPLAIN` from the racetrack. The production plan has actual row counts and rows removed. A plain `EXPLAIN` only has estimates.

Each problem pattern in the plan points to a potentially-helpful index:

- **Seq Scan whose filter removes most rows:** a btree on the filter's equality columns. If the filter includes a constant predicate that removes most rows on its own, also try a partial index.
- **Index Scan or Bitmap Heap Scan with a Filter or Recheck that removes many rows:** extend the index in use with the filtering columns, or add them as `INCLUDE` columns.
- **Sort, especially an external merge or a Sort under a Limit:** an index whose key has the sort keys after the equality columns, so the scan comes out already sorted.
- **Nested Loop with an expensive inner side:** an index on the inner table's join key plus its filter columns.
- **Hash Join with a large inner build:** an index on the join key, so a nested loop or merge join becomes an option.
- **BitmapAnd or BitmapOr combining several single-column indexes:** one composite index on those columns.
- **Sort or Hash feeding an aggregate:** an index on the `GROUP BY` keys.
- **Heap Fetches on an Index Only Scan:** this isn't an index problem, so skip it.

#### 5a-3. Dedupe and filter.

This filter runs on each generator's output as soon as the generator produces it, not once at the end.

Normalize every definition. Drop any candidate whose key columns and `INCLUDE` columns are a leading prefix of an existing index. Also drop any candidate that matches one an earlier generator already proposed, but add the later generator to its list of sources.

A dropped duplicate isn't lost work. If generator one's ideal key already exists, the query isn't slow for lack of that index, and that's worth knowing. Record every duplicate and the index that covers it, so step 15a can report it.

Drop any partial index candidate whose predicate uses a column that isn't low-cardinality, as defined in 3f. This applies to every generator, including generator two's partial indexes. A predicate on a column with 50 or more distinct values risks putting PII into the DDL.

HypoPG can't model GIN or GiST indexes, so set aside any of those that survive this filter. Carry them forward to step 12 untested, and note that they weren't tested.

#### 5a-4. Single-candidate testing.

Test each candidate on its own in the racetrack:

1. Run `hypopg_reset`, then `hypopg_create_index`.
2. For each literal in the set of literals from step 3e, run `EXPLAIN (format json)` of the original query.
3. Record whether the plan uses the hypothetical index, the total cost, the canonical plan, and `hypopg_relation_size`.

Discard any candidate the planner never uses, but keep its results. The LLM learns from what the planner ignored as much as from what it used.

This step runs twice: once on the mechanical candidates before 5a-5, and again on the LLM's candidates after it.

#### 5a-5. Generator three: the LLM.

The LLM has no database connection. The driver builds a payload from what the enclave script has sent it, and the LLM returns index DDL as text. The driver then sends that DDL to the enclave script, which tests it on the racetrack. Everything the LLM needs is shape-class data:

```json
{
  "query": "SELECT ... FROM orders o JOIN customers c ON c.id = o.customer_id
            WHERE o.status = $1 AND o.created_at > $2 AND c.name LIKE $3
            ORDER BY o.created_at DESC LIMIT 50",
  "placeholders": {
    "$1": {"type": "text",        "shape": "exact",            "est_rows": 480000, "actual_rows": 512300},
    "$2": {"type": "timestamptz", "shape": "range_lower",      "est_rows": 12000,  "actual_rows": 340},
    "$3": {"type": "text",        "shape": "trailing_wildcard","est_rows": 10000,  "actual_rows": 3}
  },
  "plan": "<step 1 plan, quals carrying placeholder ids instead of literals>",
  "schema": "<step 3b subset, with existing index definitions>",
  "mechanical_results": "<5a-4 results for every generator one and two candidate: DDL, whether the planner used it, cost per literal, estimated size, and canonical plan redacted through 3g>",
  "stats": {
    "orders.status":     {"n_distinct": 6,     "null_frac": 0.00, "correlation": 0.21,
                          "mcv_freqs": [0.71, 0.12, 0.09, 0.04, 0.03, 0.01],
                          "mcv_vals":  ["delivered", "shipped", "pending", "cancelled", "returned", "failed"]},
    "orders.created_at": {"n_distinct": -0.94, "null_frac": 0.00, "correlation": 0.99},
    "customers.name":    {"n_distinct": -1.00, "null_frac": 0.02, "correlation": 0.01,
                          "mcv_freqs": null, "withheld": "pii"}
  }
}
```

That payload is enough for every recommendation this stage is meant to make:

- 71% of `status` rows are `'delivered'`, so a partial index on the other values is worth testing. `status` has six distinct values and isn't PII, so it's low-cardinality, and the LLM gets the values it needs to write that predicate.
- `created_at` has a correlation of 0.99, so BRIN is a candidate.
- `$3` is a trailing wildcard on a nearly unique column. The planner estimated 10,000 rows, and it returned three. That points to `text_pattern_ops`, and it shows the estimate is off by three orders of magnitude.

Only the `status` partial index needed real values, and those came from a low-cardinality column. The PII lives in the literals, and the literals are the one thing the recommendation doesn't depend on. What matters about `$3` is that it's a trailing wildcard estimated about 3,000 times too high. It doesn't matter that it was `'smith%'`.

Ask the LLM for:

- Partial indexes.
- Expression indexes.
- BRIN indexes, where correlation supports them.
- Operator class choices, such as `text_pattern_ops` for prefix `LIKE` or trigram GIN for infix `LIKE`.

Ask for up to five candidates. Tell the LLM that the existing indexes and the candidates in `mechanical_results` are already covered, so it should only propose indexes that aren't on either list. The mechanical generators handle the obvious btree keys well. The LLM's job is to find what they miss.

The `mechanical_results` field shows the LLM where to aim. It can see which mechanical indexes the planner used, how much each one helped for each literal, and what's still expensive in the best plan. It doesn't have to guess at those.

The enclave script runs the LLM's output through 5a-3 right away. If any candidates get dropped, the driver tells the LLM which ones and why, such as "already covered by `orders_status_created_at_idx`," and asks for replacements. Do this once. After that, go ahead with whatever survived, if anything.

Only ask for partial indexes whose predicates use low-cardinality columns. Tag every partial index candidate with a note: it only works if the predicate's literal is a constant in the application's SQL. A generic plan for a bind parameter can't use a partial index. That tag stays with the candidate all the way into the report.

Then run 5a-4 on the LLM's surviving candidates.

#### 5a-6. Refinement round.

The results from 5a-4 up front make the LLM's first pass much better. But they can't teach it about its own kinds of candidates. Partial, expression, and operator-class indexes fail in ways btree results don't reveal. A partial index predicate might not match the query closely enough for the planner to use it. An operator class might not fit the column's collation. An expression index might not match the query's expression exactly.

Run this round only if at least one LLM candidate fell short in 5a-4:

- The planner never used it.
- It helped less than a simpler mechanical candidate did.

If every LLM candidate was used and helped, skip this round.

Otherwise, send the LLM the 5a-4 results for its own candidates:

- Whether the planner used each one.
- Cost before and after, per literal.
- Estimated size.
- The resulting canonical plan, redacted through 3g like every other plan.

Then ask it to revise. A model that sees the planner ignored its partial index, or that its four-column key lost to a two-column prefix, can usually fix the problem on a second try.

This is the feedback loop people want when they talk about giving an LLM database access. It doesn't need a connection. The enclave script runs `EXPLAIN` and hands the driver the redacted result. Run 5a-3 and 5a-4 on whatever comes back. Do only one round.

#### 5a-7. Combination and ranking.

Combine candidates from all three generators greedily. Start with the best single candidate. Test it paired with each remaining candidate. Keep adding candidates as long as each addition lowers the cost further, up to three indexes total.

Rank by the **worst-case** cost reduction across the set of literals. That way, an index that only helps the slow literal(s) ranks below one that helps across the board. Use estimated size to break ties.

Keep the top three by that ranking. Also keep the best combination if it beats the best single candidate. Each entry you keep carries:

- Its DDL.
- Its estimated size.
- Cost before and after, per literal.
- Its canonical plan.
- Its partial-index tag, if it has one.

## 6. Rewrite generation.

### 6a. Candidate generation.

Give the LLM the redacted query and annotated plan from step 3g, plus the schema subset from step 3b. Require each rewrite candidate to state two things:

- The transformation it applied.
- Every assumption it relies on, such as a column being `NOT NULL` or a key being unique.

Attach these statements to each candidate. Later steps use them to guide adversarial testing.

### 6b. Assumption check.

Check every stated assumption mechanically against `pg_constraint` and `pg_index`. Treat `NOT VALID` constraints as if they don't exist. Reject any candidate with an unmet assumption before running anything.

## 7. Operator candidates.

Operators can submit their own rewrites through the driver as plain SQL. They write them with the 3g placeholders in place of literals, because the laptop never holds real values. For each one, ask the LLM to compare it with the redacted original query and infer the transformation and the assumptions it seems to rely on. Mark these as inferred.

Run the 6b constraint check on operator candidates too. But an unmet inferred assumption only adds a warning to the report. It doesn't reject the candidate, because the operator may know something the schema doesn't capture. The candidate still has to survive steps 8 through 10 like any other.

## 8. Plan-based pruning.

A rewrite can need completely different indexes than the original query. So each rewrite candidate gets its own index search, using the same sub-steps as 5a but run on the candidate's own parse and plan. That search is split into two halves:

- **Step 8** does the cheaper mechanical half now, using no LLM calls. It tries to drop candidates we have a high confidence will not be able to run better than the original query, before they progress to more expensive parts of the pipeline.
- **Step 11** uses LLM-suggested indices later, and only for candidates that survived steps 9 and 10. It's a more expensive operation, so we want to apply it after removing as many candidates as we can.

Within one candidate's search, the 5a-3 filter compares only against existing indexes and against that candidate's own earlier proposals. An index that the original query's search also found still gets tested here, because it may behave differently with the rewrite.

First, discard three kinds of candidates:

- Candidates that aren't a single `SELECT` without side effects. The enclave script actually rejects these as soon as they arrive from the driver, using the checks listed under "What goes into the enclave." They're listed here so the report counts them with the other discarded candidates.
- Candidates that fail to plan on racetrack.
- Candidates whose output column count or types differ from the original.

For each remaining candidate, run the mechanical half of its index search:

1. **5a-1 and 5a-2:** Run generator one on the candidate's parse and generator two on its plan. Generator two uses the candidate's plain `EXPLAIN` plan from the racetrack, because a rewrite has no production `EXPLAIN ANALYZE`.
2. **5a-3:** Filter the results.
3. **5a-4:** Test each surviving index on its own, running the candidate query instead of the original.

Then `EXPLAIN` the candidate on the racetrack in three configurations:

1. With no hypothetical indexes.
2. With the original query's top three indexes from 5a-7.
3. With the candidate's own top three mechanical indexes, ranked the same way 5a-7 ranks them.

Discard the candidate only if its canonical plan matches the original's in all three configurations. A candidate like that can't run any better than the original.

Save each remaining candidate's 5a-4 results. Step 11 picks up from there.

## 9. Predicate-aware fixtures.

The enclave script runs all of step 9. The fixtures are built around the real literals, so they never leave the enclave. The driver only gets back which candidates passed, and which scenario or atom disproved the other candidates.

From the pg_query parse, pull out every predicate atom:

- Column-versus-literal equality.
- Range and `LIKE` predicates.
- `IN` lists.
- `IS NULL` tests.
- Every join condition.

For each atom, build a pool of interesting values. Include one value that satisfies the atom, one that fails it, and the boundary values where they exist. Boundary values include the literal itself, one unit on either side of it, a matching and a non-matching pattern, and case variants for text. Add `NULL` for nullable columns, and add the type's boundary values for every column.

Build every non-empty scenario from these pools:

- Each table gets at least one **hit row** that satisfies all of its predicates.
- Each table also gets one **near-miss row** per atom. A near-miss row fails only that one atom.
- Each scenario either creates or withholds join partners.
- Every row satisfies every `VALID` constraint.

The scenarios are:

- **S0:** All tables empty.
- **S1:** Hit and near-miss rows only, FK-consistent, with no `NULL`s.
- **S2:** `NULL`s in every nullable join key and every nullable predicate column.
- **S3:** Duplicates on join keys that have no unique constraint, so joins fan out.
- **S4:** Orphan rows on each side of every join that has no FK.
- **S5:** Type boundary values substituted into the hit rows.
- **S6:** One group with one row, one group with many rows, and one empty group.

Run steps 9a through 9e for each scenario.

### 9a. Open the transaction.

Begin a transaction on arena with `statement_timeout` set.

### 9b. Load the fixture.

Load the scenario's rows.

### 9c. Vacuity guard.

This guard checks that the fixture actually tests every atom. Without it, a candidate can pass just because the fixture never exercised the part of the query it changed.

Run the guard on S1 only. S1 is the scenario built to exercise every atom both ways. The other scenarios leave things empty on purpose. S0 has no rows at all, S4 withholds join partners, and S6 has an empty group. So they're extra coverage for edge cases, not full coverage.

For each atom, run the original query twice:

1. As written.
2. With that one atom replaced by `TRUE`.

If the two results differ, the atom's near-miss row did its job, and the atom counts as exercised. If they're the same, the atom is **vacuous**: nothing in the fixture depends on it.

Don't use `EXPLAIN ANALYZE` row counts for this. "Rows Removed by Filter" is one total for all of a node's conditions, not a count for each atom. Conditions used as an Index Cond, and hash or merge join conditions, don't report removed rows at all.

When an atom is vacuous:

1. **Retry.** Roll back, rebuild that atom's hit and near-miss rows from other values in its pool, and check again. Most vacuous atoms come from an unlucky value, such as a near-miss value that a `CHECK` constraint forces back into range. Try up to three times.
2. **If it's still vacuous, keep going.** Mark the atom as untested. Every candidate that passes step 9 carries a note saying which atoms were never exercised, and that note goes into the report.
3. **Hand it to step 10.** Pass the untested atoms to 10a so the LLM can aim its counterexamples at them.

The enclave script tells the driver which atoms are untested by their redacted shape, such as `o.status = $1`, never by their values.

### 9d. Compare results.

Run the original and every remaining candidate through the result comparator. The comparator follows these rules:

- **No `ORDER BY`:** compare results as multisets.
- **`ORDER BY` that doesn't give a total order:** for this run only, add a tiebreaker to both queries. Use the driving table's PK, or all output columns. Keep the `LIMIT`.
- **`LIMIT` with no `ORDER BY`:** run the original once without the `LIMIT`. The candidate's rows must be a subset of those rows, with the expected row count.
- **Float aggregates:** compare with a tolerance.
- **Built queries must round-trip.** Dropping the `LIMIT` or adding a tiebreaker means deparsing a changed tree. That SQL must parse back to the same tree, or the comparison refuses with `deparse_mismatch`. That's unsupported in v1.

Each comparison runs twice, each time in its own transaction that rolls back. The first run loads the fixture forward. The second loads it in reverse. Fixtures load in id order, and a small sort keeps its input order for ties, so a rewrite can match one load by luck. Examples are a subquery that drops a secondary sort key before its `LIMIT`, or a `DISTINCT` that keeps `'24 hours'` where the original returns the equal `'1 day'`. The reverse load flips the order rows reach those steps in.

- **Index scans are off.** Both runs turn off index, index-only, and bitmap scans for the transaction. Arena has the production indexes, and an index on `(grp, id)` returns the `grp` ties in `id` order however the rows were loaded. 9d compares only results, so the plan doesn't matter.
- **Rows reverse within each table.** Only each run of consecutive rows for one table is reversed. Rows of different tables keep their order, so parents still load before their children. A table whose foreign key references itself can't be reversed this way, and its reverse load fails with its own error, so the fixture isn't blamed for it.
- **Step 10's raw inserts don't reverse.** One `INSERT` can hold many rows, and reordering them would mean rewriting it. They load in their own order, after the rows, in both runs.
- **Both runs must match.** A mismatch in either run disproves the candidate, and the verdict says which load order did it. If either run refuses to compare, the whole comparison refuses.

Any mismatch disproves the candidate.

### 9e. Roll back.

Roll back the transaction.

## 10. Adversarial fixtures.

Run up to three rounds of 10a through 10c for each surviving candidate.

### 10a. Generate counterexamples.

Give the LLM:

- The candidate's stated transformation and assumptions from 6a, or the inferred ones from step 7.
- The subset schema.
- The constraint list.
- Any atoms that 9c marked as untested. Ask the LLM to make sure its counterexamples exercise these, since step 9 couldn't.

Ask it for inserts that satisfy every constraint but make the two queries return different results. The driver sends them to the enclave script, which loads them into arena inside a transaction. If there are FK gaps, fix them by adding parent rows. Never bypass constraints.

### 10b. Compare results.

Run the comparator from 9d. Any mismatch disproves the candidate.

For each atom that 9c marked as untested, also run the 9c test on this fixture. If the atom counts as exercised, record that step 10 covered it.

### 10c. Roll back.

Roll back the transaction.

## 11. Per-candidate index ranking.

For each candidate that survived steps 9 and 10, run the LLM half of the index search that step 8 started:

1. **5a-5:** Run generator three on the candidate. The payload uses the candidate's redacted query and plan in place of the original's, and its `mechanical_results` are the 5a-4 results that step 8 saved.
2. **5a-3 and 5a-4:** Filter the LLM's proposals and test each survivor on its own, running the candidate query.
3. **5a-6:** If any LLM proposal fell short, give the LLM its one refinement round.
4. **5a-7:** Combine and rank all of the candidate's indexes, mechanical and LLM, and keep what 5a-7 keeps.

The candidate's plan came from the racetrack, so its quals contain real literals. The enclave script redacts it through 3g before sending it to the driver. The placeholder rules apply to candidate plans exactly as they apply to the production plan.

Each candidate's winning indexes may differ from the original query's.

## 12. Measurement setup.

Steps 12 through 14 measure real block counts on the racetrack.

### 12a. Indexes.

Build every distinct index from 5a and step 11, with `maintenance_work_mem` and `max_parallel_maintenance_workers` raised. Record each index's built size for the report.

Hide all of them by setting `indisvalid` to false in `pg_index`. Only ever flip proposed non-unique indexes. Never touch existing constraints. Before measuring, confirm with a plain `EXPLAIN` that the right set of indexes is hidden.

### 12b. Run discipline.

Run every statement in a `READ ONLY` transaction with `statement_timeout` set. Run one at a time, never in parallel.

## 13. Baseline runs.

For each set of literals from the step 3e, run the original query with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Record total blocks, which is the sum of:

- Shared hit and read.
- Local hit and read.
- Temp read and written.

For a fixed plan, total blocks is nearly deterministic and doesn't depend on what's in the cache. So you need three runs, not the large sample you'd need for timing. The runs are there to confirm that the plan didn't change and the count didn't move. They aren't there to average out noise. If the count does move between runs, record the plan for each run and mark that literal as unstable in the report.

Also record the split between hits and reads. It's secondary, since it depends on whatever happened to be cached. But it's what tells you whether a candidate avoids I/O or just avoids work that was already in memory.

### 13a. Index baselines.

Repeat the baseline runs for each index combination kept in 5a.

## 14. Candidate runs.

Run each candidate and its index combinations using the same process as step 13.

### 14a. Metric.

Use total blocks, and nothing else. The rewrite worth shipping is the one that touches fewer blocks. Buffer counts stay stable across runs and across machines, and wall-clock time doesn't.

"Better" means more than 5% fewer total blocks. That threshold is about whether a gain matters, not about filtering out noise. A 2% buffer win is real, but it isn't worth adding an index for.

### 14b. Minimax rule.

A candidate must beat the original on the slow literal, and it must be no worse than the original on every other literal. When candidates tie, discard the one with the largest index footprint. Ties happen often when you rank on a single, nearly deterministic metric, so this tiebreaker matters.

### 14c. Result comparison.

This is the last correctness check. Steps 9 and 10 tested each candidate on small generated fixtures. This step tests it on full production data with the real literals.

The measurement runs in steps 13 and 14 use `EXPLAIN ANALYZE`, which runs the query but throws away its rows. So for each literal, run the original and each candidate once more, as plain queries, to get their results.

The enclave script compares the results itself, using the 9d comparator and its rules. Rows never leave the enclave. Only pass or fail goes to the driver.

Production-size results may be too big to hold in memory. In that case, stream the rows and compare hashes. Use a hash that ignores row order, such as hashing each row and adding up the row hashes, so that two queries returning the same rows in a different order still match. Where 9d adds a tiebreaker to an `ORDER BY`, add the same tiebreaker here before hashing. A hash can't apply 9d's float tolerance, so round float columns to that tolerance before hashing them.

The one exception is 9d's rule for `LIMIT` with no `ORDER BY`, which runs the original without its `LIMIT`. At production size, that query could return millions of rows. Try it under `statement_timeout`. If it times out, check only that the candidate returns the expected number of rows, and mark the comparison as partial in the report.

A real difference here means a bug slipped past steps 9 and 10. Report it prominently and discard the candidate.

### 14d. Selection.

Keep the top three candidates by total blocks.

## 15. Report.

The driver builds the report from the results the enclave script sent back. Everything it needs is shape-class data.

Rank the candidates against the original, per literal and overall, using the minimax rule. For each candidate, list any atoms that 9c marked as untested, and say whether step 10 exercised them.

For each proposed index, include:

- Its built size from step 12a.
- Whether an existing index already covers it as a prefix.
- Whether it would make an existing index redundant.

Explain why the winning candidate touches fewer blocks and what that means for cache pressure. Use only plans and selectivities in that explanation. Never use literal values.

### 15a. Negative result.

If nothing beats the original, explain why. Include which rewrites were disproved and by which scenario, which indexes the planner declined to use and why, and which proposed indexes already existed.

### 15b. Burndown.

Every report ends with a burndown: how much work QUAACK did, and where candidates dropped out. It appears whether or not anything beat the original.

For each stage, show how many items came in, how many the stage added, how many it dropped, and how many went on. Break every drop count down by reason.

**Index candidates for the original query:**

| Stage | Adds | Drops, by reason |
| --- | --- | --- |
| 5a-1 and 5a-2 | Candidates from generator one and from generator two, counted separately. | None. |
| 5a-3 | None. | Already covered by an existing index, duplicate of an earlier proposal, or a partial index on a column that isn't low-cardinality. GIN and GiST candidates set aside untested are counted separately. |
| 5a-4 | None. | The planner never used it. |
| 5a-5 | LLM candidates, plus any replacements requested for dropped ones. | Same 5a-3 and 5a-4 reasons. |
| 5a-6 | Revised candidates, if the round ran. Say whether it ran and why. | Same 5a-3 and 5a-4 reasons. |
| 5a-7 | Combinations tested. | Candidates and combinations that didn't make the cut. |

**Rewrite candidates:**

| Stage | Adds | Drops, by reason |
| --- | --- | --- |
| 6a and step 7 | LLM rewrites and operator rewrites, counted separately. | Failed the input checks under "What goes into the enclave." |
| 6b | None. | Unmet assumption. Also count the step 7 warnings, which don't drop anything. |
| Step 8 | None. | Failed to plan, output columns didn't match, or couldn't run any differently from the original. |
| Step 9 | None. | Disproved, broken down by scenario, S0 through S6. Also count untested atoms and 9c retries. |
| Step 10 | None. | Disproved, broken down by round. Also count untested atoms that step 10 covered. |
| Steps 8 and 11 | Each candidate's own index search, totaled across candidates using the same breakdown as the table above. | Same 5a-3, 5a-4, and 5a-7 reasons. |
| Step 14 | None. | Failed the minimax rule, lost a footprint tiebreak, diverged in 14c, or fell outside the top three. Count partial 14c comparisons too. |

**Work totals:**

- LLM calls, by step.
- Hypothetical-index `EXPLAIN`s on the racetrack.
- Real indexes built in 12a.
- Measurement runs in steps 13 and 14, including literals marked unstable.
- Fixture loads in arena.

The enclave script records its counts in the governed store as it goes, and the driver records its own, such as LLM calls. Counts are shape-class data, so they can leave the enclave through the egress function like any other result.
