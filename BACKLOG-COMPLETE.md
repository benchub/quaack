# QUAACK completed backlog.

Finished tasks move here from BACKLOG.md with their full entries. Don't reopen them. If one needs more work, add a new task to BACKLOG.md that points back to it.

## Foundations.

### 20260922-1. Project skeleton.

Set up the repo: package layout with separate driver and enclave packages, dependency management, test runner, and linting. The two packages must not import each other's internals, since they run on different machines.

- **Depends on:** None.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:**
  - Ruby 3.4, with the pg_query gem. Ruby is already on the jump servers, and adding pg_query is simple. Locally, Ruby 3.4 is Homebrew's keg-only `ruby@3.4`.
  - Postgres 18 only.
  - Separate gems in one repo: a driver gem, an enclave gem, and a small shared gem for the protocol between them. The enclave gem never depends on the driver gem or the LLM SDK.
  - RSpec for tests. No hosted CI: the user has no use for GitHub CI, so the local `bundle exec rake` is the whole check.
  - The jump servers are ARM (`aarch64-linux`). Nothing needs x86_64.
- **Landed:** Merged into `main` after two reviews. The first review's findings were fixed in the builder's one fix round. The second review found no blockers, and its findings became 20260923-4 through 20260923-7. At landing, the main session removed the GitHub Actions workflow and the x86_64 lockfile platform, and corrected docs that overstated the runtime boundary check.

## Added later.

### 20260923-3. Rename the enclave gem to quaacks.

Rename the `quaack-enclave` gem and its executable to `quaacks`. The "s" stands for server, which pairs it with the driver's `quaack`. Update every reference, including the gemspec, the executable, the boundary and runtime specs, the allowlists, `CLAUDE.md`, and the backlog.

- **Depends on:** 20260922-1.
- **Came from:** The user, during 20260922-1.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:**
  - The gem and executable are named `quaacks`.
  - Internal names stay as "enclave," such as the `enclave/` directory and the `Quaack::Enclave` module, to match the README's "enclave script." The README doesn't change.
- **Landed:** Merged into `main` after two reviews. The builder found that a check keyed on the literal `quaack-enclave` would have gone vacuous after the rename. Checks now read gem names from the gemspecs through a new `RepoGems` test helper. The first review found one vacuous test, which the fix round replaced. The second review found no blockers, and its minor findings became 20260923-8.

### 20260923-5. Discover spec suites instead of listing them.

Removing the root suite from `SPEC_SUITES` in the `Rakefile` turns off every boundary check, and `rake` stays green. That's because the spec that pins `SPEC_SUITES` lives in the root suite itself. Derive the suites from the directories that have a `spec/` folder, so there's nothing to forget.

- **Depends on:** 20260922-1.
- **Came from:** Second review of 20260922-1, finding 3.
- **README:** None. This is test infrastructure.
- **Status:** done
- **Landed:** Merged into `main` after two reviews. The Rakefile finds the suites from the root and each top-level directory with a `spec/` folder, leaving out `vendor/` and hidden directories. It runs every suite in its own process from its own directory, fails at the end if any suite failed or ran no examples, and fails if the root suite didn't run. The first review found that small edits could still drop the root suite with `rake` green, and the fix round added the root guard. The second review found no blockers, and its findings became 20260923-9 and 20260923-10.

### 20260923-4. Harden the runtime boundary check.

The runtime check in `spec/runtime_boundary_spec.rb` has two gaps:
- **It trusts the gemspec.** It builds its allowed set from the enclave gemspec's own dependency closure. If the enclave gains a dependency on `quaack-driver`, the check installs the driver and allows loading it. Only the dependency allowlist in `spec/boundary_spec.rb` catches that today. The runtime check should take the closure from that same allowlist, or assert that nothing loads from the driver gem or a known LLM gem.
- **It only runs `--version`.** A forbidden require in any other code path, such as `Kernel.enum_for("require", "quaack/driver").first` in the usage branch, passes every check. Make it also require every file under the installed gem's `lib/`. Write down what it still can't catch, like lazy loads inside method bodies.

- **Depends on:** 20260922-1.
- **Came from:** Second review of 20260922-1, findings 1 and 2.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Squash-merged into `main` after two reviews, under the user's accident-only threat model: the boundary guards against honest mistakes, not a deliberate insider. The runtime check now takes the enclave's allowed gems from `Boundary::ENCLAVE_ALLOWED_GEMS`, the same allowlist the static check uses. It rejects anything loaded from the other side, and for the enclave any LLM SDK, whatever the gemspec says. Besides `--version` and the usage branch, it requires every file under each shipped repo gem's `lib/`, including `quaack-protocol`. The first review found that the protocol gem was never loaded, and the fix round covered it. The second review found no blockers. At landing, the main session corrected CLAUDE.md, which implied the driver can't load an LLM SDK. The review's other findings became 20260923-13.

### 20260923-11. Index candidate and statistics shapes.

Define the two shapes that 5a-1 and 5a-2 share, so both generators can be built in parallel without conflicting:
- **`IndexCandidate`** is an immutable value. It holds the table (schema qualified), the key columns with their sort directions, the `INCLUDE` columns, the index method, an optional partial predicate, and the generators that proposed it. Two candidates with the same definition compare equal whatever their sources are. It can render itself as `CREATE INDEX` DDL through pg_query.
- **The statistics input** is what the generators read about each table and column. Per table, it holds `reltuples`. Per column, it holds `n_distinct`, `null_frac`, and `correlation`. It includes a helper for the distinct count: when `n_distinct` is negative, take its absolute value times `reltuples`.

- **Depends on:** 20260922-1.
- **Came from:** The user, who asked to build 5a-1 and 5a-2 in parallel with the main line.
- **README:** 5a, 5a-1, 5a-2, and 5a-3.
- **Status:** done

- **Landed:** Merged into `main` together with 20260923-14, which finished it. Its own loop ran a build, a review, a fix round, and a second review. The second review found a pattern-matching predicate leak, vacuous freeze and guard tests, and no UNIQUE support, so the work couldn't land until 20260923-14 fixed them.

### 20260923-14. Finish the index candidate and statistics shapes.

Start from the unlanded 20260923-11 branch (`shapes-20260923-11`, `324f495`) and fix what its second review found:
- **UNIQUE indexes (sufficiency).** `IndexCandidate.from_ddl` returns nil for every UNIQUE index, primary keys included, because the shape has no uniqueness. So `TableStatistics#indexes` never shows those indexes' columns. 5a-2 can't extend `orders_pkey`, and 5a-3 can't see that `(id)` is already covered.
- **Pattern-matching leak (trust boundary).** `case cand in {...}` with no match raises `NoMatchingPatternError`, whose message holds the raw predicate. The public `definition` exposes the predicate the same way. Close both, or document them next to `to_h` if closing isn't reasonable, and add sentinel tests.
- **Vacuous tests.** These mutants survive:
  - dropping `name.dup.freeze` in `KeyColumn` and in the column-name helper, since the "deeply frozen" test only passes literals, which are already frozen
  - dropping the `is_a?(IndexCandidate)` guard in `==` and `eql?`, where `cand == nil` must be false
  - `column_names.dup.freeze` in place of freezing each name
  - dropping `by_name.freeze` in `Statistics`
  - dropping the CONCURRENTLY and IF NOT EXISTS reset in `from_ddl`
- **Unchecked definitions (correctness, low).** The constructor accepts some definitions Postgres rejects: `$1`, subqueries, and volatile or aggregate functions in predicates, BRIN with INCLUDE, and multicolumn hash. Reject the cheap ones, or document that the shape doesn't check them.
- **Minor.** A `Complex` `n_distinct` raises RangeError, not ArgumentError. Duplicate `column_names` are accepted.

- **Depends on:** 20260923-11 (unlanded branch).
- **Came from:** Second review of 20260923-11.
- **README:** 5a, 5a-2, and 5a-3.
- **Status:** done
- **Landed:** Merged into `main` with 20260923-11, after a build, a review, a fix round, and a second review. It added `unique`, closed the pattern-matching leak, refused definitions Postgres rejects, and killed the surviving mutants. The first review found two vacuous tests, a require that was wrongly called equivalent, and overstated aggregate comments, and the fix round fixed them. The second review found no blockers, and its minor findings became 20260923-17.

### 20260922-2. Test database harness.

Give the test suite throwaway Postgres instances with HypoPG installed, plus a small sample schema like the README's `orders` and `customers` example. Integration tests for most later tasks need this.

- **Depends on:** 20260922-1.
- **README:** Steps 4, 5a, and 9.
- **Status:** done
- **Decided:**
  - Postgres 18 runs in Docker, from our own image: `postgres:18` plus the `postgresql-18-hypopg` package, since the official image doesn't include HypoPG.
  - A small Ruby test helper builds the image and drives it with the `docker` command. No testcontainers gem and no Compose.
  - One container per test run. Each test that needs a database gets a fresh one, created from a template and dropped afterward. Tests that need racetrack and arena side by side get two databases in the same container, like the real run server.
- **Landed:** Merged into `main` together with 20260923-15, which finished it. Its own loop found that a failed launch was never remembered, and that a forked child removed the parent's container. The fix round fixed both, but also added `ForkGuard`, which leaked every connection a test dropped. The second review blocked it on that leak, and 20260923-15 removed `ForkGuard`.

### 20260923-15. Finish the test database harness without ForkGuard.

Start from the unlanded 20260922-2 branch (`harness-20260922-2`, `1bd288f`) and fix what its second review found:
- **Remove `TestPostgres::ForkGuard` and the connection tracking (correctness).** `TestPostgres.open` keeps a strong reference to every connection. So a connection a test opens with `Database#connect` and never closes never gets its socket back. With the default macOS limit of 256 open files, about 250 such examples crash the run with `Errno::EMFILE`, and the container leaks because the `at_exit` `docker rm` can't open a pipe. Nothing in QUAACK forks. Keep the owner-pid guard on the `at_exit` cleanup. Document that a spec must not fork after using a database, or that the child must `exit!`.
- **Fork test (vacuous in part).** After ForkGuard is gone, the fork test should check what's still promised: a forked child that exits with `exit!` doesn't remove the parent's container, and the parent's own example connection still works in the same example.
- **"Dropped afterward" isn't pinned (test quality).** Changing `config.after` to `config.before` keeps every test green. Check within the example's own lifecycle that its databases exist during the example and are gone after it.
- Add a regression test for the connection leak. For example, open many connections through `connect` and drop them, then check the process doesn't keep their sockets open.

- **Depends on:** 20260922-2 (unlanded branch).
- **Came from:** Second review of 20260922-2, findings 1 through 4.
- **README:** Steps 4, 5a, and 9.
- **Status:** done
- **Landed:** Merged into `main` with 20260922-2 after a build, a review, a fix round, and a second review. It removed `ForkGuard` and its connection tracking, kept the owner-pid guard, and documented that a spec must not fork after using a database. It added a regression test for the leaked connections, rewrote the fork tests, and pinned down when databases get dropped. The fix round made a failed drop forget that example's databases, and made a lost connection raise `TestPostgres::ConnectionLost`. The second review found no blockers, and its minor findings went into 20260923-16.

### 20260923-13. Tighten the runtime boundary checker tests.

The second review of 20260923-4 found no boundary holes, since every in-scope plant in the real repo turns the runtime spec red. But some tests prove less than their names say:
- **Three checker tests pass with their plant removed.** In `spec/runtime_boundary_checker_spec.rb`, the tests for an orphan enclave lib file, an orphan protocol lib file, and the driver loading the enclave from a file `--version` never reaches each add the other side as a dependency. The every-file run then loads that gem's own files, which get flagged whether or not the planted `hidden.rb` exists. Drop the added dependency, or assert that the message names the planted file. Also add a deliberate test that a bare driver dependency, with no require, is flagged.
- **The real-gem every-file test can't tell every file from the entry file.** `spec/runtime_boundary_spec.rb` asserts that the entry file and `cli.rb` loaded, but the entry file loads `cli.rb` itself. Requiring only the first file keeps it green.
- **Code no test observes.** Nothing tests the trailing `/` in `under?`. The `rubyarchdir` entry in `stdlib_dirs` is redundant. `forbidden_require?` tries every `/lib/` split when the last one would do. `Check#closure`'s custom lookup can be replaced with `Boundary.installed_spec` and stay green. Simplify or test each one.
- **Known-gaps comment.** Mention `begin; require "openai"; rescue LoadError; end`. A rescued LoadError passes the runtime check, and only the static check catches it.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260923-4, findings 1, 2, 3, and 5. Finding 4 was a CLAUDE.md wording fix, made at landing.
- **Note:** This task came before the rule that vacuous tests block landing. It fixes the vacuous tests that landed with 20260923-4, so it comes before version 1.
- **README:** None. This is test infrastructure.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The orphan tests now require the other side from the repo checkout with no added dependency, and they assert the planted file's path. New tests show that a bare dependency is flagged on both sides. The real-gem test now asserts that every installed lib file loaded. Rules unit tests cover the trailing `/` and the last-`lib/` split, and `Check#closure` uses `Boundary.dependency_closure`. `rubyarchdir` stays, because Debian's packaged Ruby puts it outside `rubylibdir`, which a reviewer checked in Docker. The second review found no blockers, and its findings became 20260923-18.

### 20260923-19. MCV frequencies in the statistics input.

5a-2 needs to know how often a specific literal occurs to decide whether `col = literal` removes most rows on its own. Add the column's most-common values and their frequencies to `ColumnStatistics`, plus a helper that estimates one literal's frequency the way Postgres does. If the literal is an MCV, use its frequency. Otherwise use `(1 - sum of MCV frequencies - null_frac) / (distinct count - number of MCVs)`.

- **Depends on:** 20260923-14.
- **Came from:** First review of 20260922-31. The user chose MCV frequencies over a low-cardinality rule.
- **README:** 3c, 3f, and 5a-2.
- **Status:** done
- **Decided:**
  - The new fields are optional, so existing callers keep working. 5a-1 is being built against this shape right now.
  - MCV values are real data, so they're value-class. `inspect`, `to_s`, `pp`, pattern matching, and every error message must redact them, the way `IndexCandidate` redacts predicates. Add sentinel tests.
  - A literal is compared to MCV values by its text form, as `pg_stats` prints them. Document what that can't match.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `ColumnStatistics` has optional `most_common_vals` and `most_common_freqs`, and `TableStatistics#value_frequency` follows Postgres's `var_eq_const`. `PgArray.parse` reads `pg_stats` array text. MCV values are redacted everywhere except `to_h` and the readers. Real-Postgres tests compare the estimates with EXPLAIN. The first review found that booleans missed the MCV list, so the fix round maps boolean spellings when the MCVs are only `t` and `f`. The second review found that `bool = false` on a nullable column differs from EXPLAIN, because Postgres counts NULLs there. Our value is the true one, so at landing the main session documented the difference and narrowed a test name. Its minor findings became 20260923-22.

### 20260922-30. 5a-1 generator one.

Build index candidates from the parse: ranked equality columns, one range column, matching `ORDER BY` columns, a capped key, `INCLUDE` columns, every leading prefix, and BRIN on a well-correlated range column of a large table.

- **Depends on:** 20260923-11 and 20260923-14. It takes a parsed, fully qualified query and the 20260923-11 statistics input, so it doesn't need 20260922-14 or 20260922-19 to exist. Those tasks must produce the same input later.
- **README:** 5a-1.
- **Status:** done
- **Decided:**
  - Cap the key at three columns.
  - Emit a BRIN candidate when the range column's absolute correlation is 0.9 or more and the table's `reltuples` is at least 1,000,000.
  - All three limits are configurable.
  - The user approved building this in parallel with 20260922-31 and the main line, once 20260923-11 lands. It's a pure function over its inputs, in new files in the enclave gem.
  - Join columns: build every table's keys twice, once with its join columns counted as equality columns and once without them, then drop duplicates. A parse alone can't tell which way the join runs. On the README example this gives both `(customer_id, status, created_at)` and `(status, created_at DESC)`.
  - A column filtered only by `IS NULL` is ranked by `null_frac`, not `equality_selectivity`.
  - When the range column and ORDER BY conflict, emit two keys: equality plus range, and equality plus ORDER BY.
- **Note:** Built, fixed once, and reviewed twice, but not landed. The work is on branch `gen1-20260922-30` at `f2a1408`. The second review found an `IS NULL` in an upper join's ON that still lands on a nullable table, plus four vacuous tests. So 20260923-20 finishes the task from that branch, and both land together.
- **Landed:** Squash-merged into `main` together with 20260923-20, which finished it. Its own loop found four correctness bugs against real Postgres with HypoPG: `IS NULL` pinning ORDER BY, a prefix LIKE taking the range slot, ordinals after a star, and outer joins. The fix round fixed them. The second review found a remaining `IS NULL` hole and vacuous tests, so the work continued in 20260923-20.

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
- **Status:** done
- **Landed:** Squash-merged into `main` with 20260922-30. It narrowed the outer-join rule to skipping only `IS NULL` on a table made nullable below, and fixed the vacuous tests. Both reviews found no correctness blockers. The second review found two vacuous tests. The tests-only round fixed the alias test, but the repeated-ORDER-BY test was still vacuous. At the user's choice, the dedupe it covered was removed before landing and split out to 20260923-23. The other findings went into 20260923-21.

### 20260922-31. 5a-2 generator two.

Build index candidates from problem patterns in a plan. Use the production plan for the original query and the racetrack plan for rewrites.

- **Depends on:** 20260923-11, 20260923-14, and 20260923-19. It takes the production plan JSON and the 20260923-11 statistics input, so it doesn't need 20260922-13 or 20260922-19 to exist.
- **README:** 5a-2.
- **Status:** done
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
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. Generator two walks a production EXPLAIN ANALYZE plan and proposes candidates for each README 5a-2 pattern. It's tested against 35 real PG 18 fixtures that `capture.rb` regenerates from the harness data. The first review found that the partial-index signal fired only on columns 5a-3 drops. The user chose MCV frequencies (20260923-19), and the fix round switched to them. The fix round also fixed Parallel Hash row counts, a `pp` leak, a vacuous test, eight surviving mutants, and swallowed refusals. The second review found no leaks and no vacuous tests. Its findings became 20260923-24.

### 20260923-7. Simplify and relax the static boundary checker.

The static checker in `spec/support/boundary.rb` is about 220 lines, is still easy to get around, and flags ordinary code the next tasks need. It flags `public_send("cmd_#{sub}")` (the natural shape of the 20260922-4 dispatcher), `define_method("step_#{n}")`, `%i[save load]`, `{ require: true }`, and `JSON.load(x)`. It also applies every rule to the driver, where loading enclave code doesn't leak production data. Cut it back:
- For the driver, a plain require check that forbids `quaack/enclave` is enough.
- For the enclave, keep plain string requires plus the shebang rule. Review whether the send, lookup, symbol, eval, and `$LOAD_PATH` rules earn their cost once 20260923-4 lands.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, findings 5 and 6.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note:** Do this before 20260922-4, or the dispatcher will trip the checker.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It dropped the send, lookup, symbol, eval, and `$LOAD_PATH` rules, so `public_send("cmd_#{sub}")`, `define_method`, `%i[save load]`, `{ require: true }`, and `JSON.load(x)` are accepted. For the enclave and protocol gems it keeps these checks: plain requires of forbidden names, requires that leave the gem, `./` paths, `Bundler.require`, parse failures, the shebang, and, added in the fix round, `require` or `require_relative` of a path that isn't a plain string. The driver gets only the forbidden-name check. The second review found no blockers. Its findings became 20260923-25, and the computed-require consequence was noted on 20260922-4.

### 20260922-7. Egress function and whitelist.

Build the single egress function. It only accepts fields on a whitelist, and it drops anything else entirely rather than scrubbing it. The whitelist lives in one place so every change to it gets reviewed.

- **Depends on:** 20260922-1.
- **README:** Trust boundary.
- **Status:** done
- **Decided:**
  - The whitelist is one file in the protocol gem that maps each output type to its allowed field names, such as `column_stats: [table, column, n_distinct, null_frac, correlation, mcv_freqs, low_card_values]` and `error: [step, rule, sqlstate]`. It lists the fields of QUAACK's own output messages, not database columns, so it changes only when QUAACK changes what a step outputs.
  - The egress function drops any field not on its type's list, and drops any output of an unknown type. There are no field types.
  - Changes to the whitelist get reviewed through the normal git diff. There's no snapshot test and no CODEOWNERS.
- **Defaults the main session chose (the user was away):** The whitelist is in the protocol gem, and the egress function is in the enclave gem. The whitelist starts with only `error` and `column_stats`. An unknown type sends nothing.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `Quaack::Protocol::WHITELIST` maps each type to its fields. `Quaack::Enclave::Egress.serialize` returns one JSON line with `type` first and only the allowed fields. It returns nil for an unknown type or a non-Hash, and raises a fixed-message `Egress::Error` with no cause for a value that isn't plain JSON data. The first review found that exceptions and other objects leaked through `to_s` or `to_json`. `strict: true` doesn't close that on Ruby's default json 2.9.1, which the enclave uses outside Bundler. So the fix round allows only exact-class nil, booleans, Integer, Float, String, Symbol, Array, and Hash with String or Symbol keys, and sends the type as the whitelist's own name. The second review found no blockers. Its findings became 20260923-26.

### 20260922-14. Fully qualify relations.

Rewrite the query AST so every relation is schema qualified and `search_path` never matters.

- **Depends on:** 20260922-13.
- **README:** Step 1.
- **Status:** done
- **Decided:** The operator's query should already qualify every relation. If it doesn't, resolve the unqualified names with the `search_path` from the input plan's `SETTINGS`, since that's what the session used when the plan was made.
- **Decided:** When `SETTINGS` has no `search_path`, assume the default `"$user", public`. Resolve `"$user"` as the connecting role, then `public`, in `pg_catalog`. Abort if a name resolves nowhere.
- **Built early:** Built before 20260922-13 lands. `RelationQualifier.qualify(sql, settings, connection)` takes the query text, the plan's `Settings` hash, and a connection as plain inputs.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It follows Postgres's resolution rules. `pg_catalog` comes first unless it's listed. Schemas that are missing or lack USAGE are skipped. It handles quoted and mixed-case entries, `"$user"`, and 63-byte truncation. CTE names in scope are left alone, and DML targets are always qualified. The first review found `FOR UPDATE OF` aliases treated as relations, DML targets given CTE scope, a hidden `pg` constant, and missing truncation, and the fix round fixed all of them. The second review found no blockers. Its findings became 20260923-27.

### 20260922-15. Canonical plan form.

Define the canonical plan: keep node type, relation, index, join type, strategy, quals, and sort keys, and strip costs, row counts, buffers, and aliases. Build the comparison every later step uses.

- **Depends on:** 20260922-1.
- **README:** Step 1.
- **Status:** done
- **Decided:** Parse each qual with pg_query, replace each alias with the relation it stands for, and compare the pg_query fingerprints, which ignore constants. Two plans that differ only in literal values or alias names compare equal.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `CanonicalPlan.new(explain, hypothetical_indexes: nil)` walks the plan with `PlanNode`. It keeps node type, parallel awareness, relation, index, join type, strategy, parent relationship, subplan name, partial mode, and scan direction, plus fingerprints of each qual and sort key with aliases mapped to relations. `#matches?` compares two plans. Postgres 18 subplan forms such as `(InitPlan 1).col1` are rewritten so they parse. Any qual that still won't parse makes the plan not `comparable?`, and such a plan matches nothing. The first review found that different HypoPG indexes compared equal, because their automatic names match. So a caller can now map each hypothetical oid to an identity, such as `hypopg_get_indexdef`, and the plan compares a digest of it. The second review found no blockers. Its findings became 20260923-28.
- **Known limits, which follow from the fingerprint decision:** The fingerprint ignores the order of function arguments and AND/OR arms. It collapses repeated arms that differ only in literals, and it treats `= ANY(array)` like `= const`. Two aliases of one table can't be told apart. Workers Planned, Inner Unique, Memoize Cache Key and Mode, the WindowAgg definition, SetOp Command, and Schema are dropped.

### 20260922-43. 9 predicate atom extraction.

Pull every predicate atom out of the parse: equality, range, `LIKE`, `IN`, `IS NULL`, and every join condition. Give each a redacted shape for reporting.

- **Depends on:** 20260922-14, 20260922-23.
- **README:** Step 9.
- **Status:** done
- **Decided:** Extract atoms everywhere, including under `OR`, `NOT`, `CASE`, and in subqueries. The 9c vacuity guard catches any that fixtures can't exercise.
- **Note:** Built on branch `task/20260922-43`, with a build, a review, a fix round, and a second review, but not landed. The second review found that `extract` raises on a recursive CTE with `CYCLE` inside an atom, and that the explicit `normalize(x, 'lit')` redaction is untested. 20260923-29 finishes it on top of that branch, and 20260923-30 holds the rest.
- **Landed:** Merged into `main` together with 20260923-29. `PredicateAtoms.extract(parse, column_names:)` returns atoms from every position, each with its kind, operator, negation, columns, a redacted shape, and a path. `with_true` gives the query with one atom replaced by TRUE, and `node` gives an atom's parse node. The first review found a JSON_TABLE deparser segfault, TABLESAMPLE and table functions missing from scope, and functions in FROM not treated as LATERAL. The fix round fixed all of them. The second review's blockers went to 20260923-29, and its minor findings went to 20260923-30.

### 20260923-29. Finish predicate atom extraction.

Split out of 20260922-43, whose branch `task/20260922-43` holds the work so far. Build on that branch, then land both together. Fix what the second review of 20260922-43 found:
- **A recursive CTE with `CYCLE` inside an atom makes `extract` raise** `PgQuery::ParseError: deparse: unpermitted node type in AexprConst`. The deparser needs `CTECycleClause.cycle_mark_value` and `cycle_mark_default` to be `A_Const`. Keep them, or swap them for string placeholders, the way JSON paths are handled. Repro: `SELECT 1 FROM public.orders o WHERE EXISTS (WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t) CYCLE n SET c USING p SELECT 1 FROM t WHERE t.n = o.id)`.
- **The explicit `normalize` call isn't tested.** Removing `node.funcformat == :COERCE_SQL_SYNTAX &&` from `Literals.normal_form?` stays green, and then `pg_catalog.normalize(o.note, 'SENTINEL')` keeps its literal. Add a sentinel test.
- **XMLROOT shapes are wrong.** The `version no value` and `standalone` arguments are keywords that the deparser reads as `A_Const`. Keep them, the way the normal form is kept.
- **Surviving mutants for nested atoms:**
  - `null_test` in `boolean?`
  - `SUBQUERY_TESTS` shrunk (nested `IN (SELECT ...)` and `ALL`)
  - `EXPRESSIONS.key?` in `boolean_expression?` (`NULLIF`)
  - the ELSE and the argument of a simple CASE
  - the unreachable `path_placeholder` branch (drop it)

- **Depends on:** 20260922-43's branch.
- **Came from:** Second review of 20260922-43.
- **README:** Step 9.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. A constant with location -1 is parser-made (a grammar default or keyword), so it's kept and not numbered. The reviewers checked that rule against the vendored grammar and with about 150 sentinel probes. Written CYCLE marks, including typed ones, become string placeholders. The second review found no blockers. Its findings went into 20260923-30.

### 20260922-3. Governed store.

Build the per-run store directory on the jump server: its layout, a run ID, and reads and writes of every intermediate result. Also build the teardown that deletes the run's directory when the run ends.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs (the storage table), and the note about destroying state after each run.
- **Status:** done
- **Note:** Built on branch `task/20260922-3` through a build, a review, a fix round, and a second review, but not landed. The second review found `SystemStackError` on Hash nesting inside `MAX_DEPTH` on aarch64 Linux, and tests that miss a walk that skips sibling values. 20260923-32 finishes it on top of that branch.
- **Defaults the main session chose (the user was away):** the base is `~/.quaack/runs/`, run IDs look like `20260923T221500Z-<8 hex>`, entry names match `/\A[a-z][a-z0-9_]*\z/`, writes are atomic, and opening a run checks that it's 0700 and owned by the current user.
- **Decided:**
  - Each stored result is a JSON file in the run's directory.
  - The run directory is mode 0700 and its files are 0600, in the operator's home directory. Encryption at rest comes from the jump server's disk encryption. There's no encryption in the app.
- **Landed:** Merged into `main` together with 20260923-32. `Store.create`, `Store.open`, `#write`, `#read`, and `#teardown` are in `enclave/lib/quaack/enclave/store.rb`, with atomic 0600 writes in `private_files.rb`. The shared exact-class `PlainData.check` in `plain_data.rb` is now used by both store and egress. The first review found reads failing under a C locale, and non-JSON objects stored as `to_s`, and the fix round fixed both. The second review's blockers went to 20260923-32.

### 20260923-32. Finish the governed store.

Split out of 20260922-3. The work so far is on branch `task/20260922-3`. Build on that branch, then land both together. It also changes egress, which now shares `PlainData.check`. Fix what the second review of 20260922-3 found:
- **Hash nesting within `MAX_DEPTH` raises `SystemStackError` on aarch64 Linux.** json 2.9.1 on `ruby:3.4-slim` writes nested Hashes only about 9,700 deep on the main thread, and about 1,200 in a thread. The comment on `MAX_DEPTH = 10_000` promises more than that. The deepest real pg_query tree is about 1,500 levels. Lower `MAX_DEPTH` with room to spare. Add Hash and Array round-trip tests at `MAX_DEPTH`. Also turn `SystemStackError` from JSON into `Store::Error` and `Egress::Error`.
- **Tests miss a walk that skips sibling values.** Each of these changes stays green:
  - `hash.values` changed to `first(1)` or `last(1)`
  - an Array walk using `item.last(1)`
  - egress checking only the last field

  Put bad values first, in the middle, and in a field other than `rule`.
- **Egress now honors a singleton `to_json` on a plain Array or Hash,** because it generates the original object, not a copy. That's evasion, not an honest mistake, so just say so in a comment.

- **Depends on:** 20260922-3's branch.
- **Came from:** Second review of 20260922-3.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `MAX_DEPTH` is 3,000, measured on aarch64 Linux json 2.9.1. `SystemStackError` becomes `Store::Error`. Egress keeps json's default `max_nesting` of 100, so it needs no stack rescue, and the reviewers agreed. Sibling-position tests were added. `create` and `teardown` now raise `Store::Error`. The second review found no blockers. Its findings became 20260923-34.

### 20260922-20. 3d volatility check.

Check `provolatile` for every function in the query, including the select list. Abort and name any volatile function. Reusable for rewrite candidates.

- **Depends on:** 20260922-14.
- **README:** 3d.
- **Status:** done
- **Decided:** Yes. Resolve each operator's `oprcode` and each cast's `castfunc` in `pg_catalog`, and abort if any of them is volatile.
- **Defaults the main session chose (the user was away):** It doesn't try to resolve the exact overload. A call is volatile if any overload with the same name that could take that many arguments is volatile. Operators work the same way, by name and arity. A cast is volatile if any cast function to the target type, or the target type's input function, is volatile. On Postgres 18 and 11 common extensions, this caused no false positives for ordinary queries.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review. `VolatilityCheck.check(sql, settings, connection)` walks every call, including operators hidden in syntax, casts, aggregates and all eight of their support functions, and functions in FROM. It raises `volatile_function` and names the object, quoted with quote_ident. The first review found ordered-set aggregates slipping through, and support functions with no tests. The second review found one vacuous test, which the tests-only round fixed. The leftover findings became 20260923-35.

### 20260922-32. 5a-3 dedupe and filter.

Normalize definitions. Drop candidates covered by an existing index or by an earlier proposal in the same search, recording the source generators and the covering index. Drop partial indexes on columns that aren't low-cardinality. Set GIN and GiST aside, untested, for step 12. Scope must be per search, so each rewrite's search is independent.

- **Depends on:** 20260922-19, 20260922-22.
- **README:** 5a-3, step 8.
- **Status:** done
- **Note:** Built on branch `task/20260922-32` through a build, a review, a fix round, and a second review, but not landed. The second review found that an array check on the partial filter had a vacuous test, and that generator two's partials on `varchar` columns were always dropped. 20260923-31 finishes the task on top of that branch.
- **Landed:** Merged into `main` together with 20260923-31. `Dedupe.new(statistics:, low_cardinality:)` is one search. `#filter` takes one generator's output and returns the survivors, recording each drop with a reason (`:partial_not_low_cardinality`, `:covered_by_existing`, or `:duplicate`) and what covered it. GIN, GiST, and SP-GiST are set aside. The first review found literals that weren't tied to a column getting through, which led to the rule that every constant must be compared directly with a bare low-cardinality column. The second review's blockers went to 20260923-31.

### 20260923-31. Finish 5a-3 dedupe and filter.

Split out of 20260922-32. The work so far is on branch `task/20260922-32`. Build on that branch, then land both together. Fix what the second review of 20260922-32 found:
- **Vacuous test on the trust-boundary check.** In `predicate_check.rb` `constant?`, changing `elements.all?` to `elements.any?` stays green. With that mutant, `status = ANY(ARRAY['open', lower('bob@x.com')])` keeps its partial. Add a mixed-element array to the drop list.
- **Generator two's partials on `varchar` columns are always dropped.** Postgres prints `((status)::text = 'open'::text)`, so the predicate has a cast on the column side, and `constants_compared_with_columns?` wants a bare column. Accept a column under casts, but not under any other expression. Test it with real generator two output from a Postgres plan.
- **Allowed forms no test pins:** `AEXPR_OP_ALL`, `AEXPR_NOT_DISTINCT`, `AEXPR_ILIKE`, `AEXPR_NOT_BETWEEN`, and both SYMMETRIC forms.
- **Dead code:** the BETWEEN special case in `column_comparison?` can't be reached. Drop it.
- **Type modifiers in an allowed comparison aren't checked,** as in `status = 'x'::mytype(lower('bob'))`. Check them, or drop anything that isn't an integer constant.

- **Depends on:** 20260922-32's branch.
- **Came from:** Second review of 20260922-32.
- **README:** 5a-3.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The column side may sit under casts and COLLATE. Typmods must be integer constants. Operators must be comparisons (`= <> < <= > >= ~~ !~~ ~~* !~~*`), and a schema-qualified operator counts only from pg_catalog. Real generator-two output on varchar columns survives end to end. The second review found no blockers. Its findings went into 20260923-36.

### 20260922-46. 9a, 9b, and 9e arena transaction runner.

Open a transaction on arena with `statement_timeout`, load a fixture, run queries, and always roll back.

- **Depends on:** 20260922-27.
- **README:** 9a, 9b, and 9e.
- **Status:** done
- **Built early:** built before 20260922-27, against the test harness. The main session chose the defaults: a 10s `SET LOCAL statement_timeout`, FixtureRows plus raw step-10 INSERTs as inputs, and results kept as plain data inside the enclave.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `ArenaRunner.new(conn).with_fixture(rows, inserts:) { |tx| tx.query(sql) }` always rolls back. It drops Postgres notices while it runs and restores the caller's receiver afterward. A pg_query StatementCheck lets through exactly one INSERT for inserts and one SELECT for queries, and refuses everything else before it runs. Errors carry a fixed message, rule, SQLSTATE, step, and index, with `cause: nil`. The first review found NOTICE text leaking fixture values to stderr, and `COMMIT AND CHAIN` getting past the rollback. The fix round fixed both. The second review found no blockers. Its findings became 20260923-37.

### 20260922-8. Error filtering.

Send every enclave error through the egress function, including Postgres errors and stack traces. A unique-violation message, for example, can contain a real key value. Errors should still say which step and which rule failed.

- **Depends on:** 20260922-7.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `ErrorFilter.to_egress(exception, step:)` sends only the step, a rule (the exception's own rule if it's identifier-shaped, otherwise `internal_error`), and a 5-character SQLSTATE. It never reads the message, backtrace, class, or cause, and it never raises.
  - `guard(step:, out:)` writes one line for anything raised, and re-raises signals after writing.
  - `silence_stderr!` points fd 2 at /dev/null.
  - `drop_notices(conn)` drops libpq notices. Callers must call it again after `conn.reset`.
  - The main session chose to let step names match `/\A[a-z0-9][a-z0-9_-]{0,62}\z/`, since steps such as `5a-1` start with a digit or contain a hyphen.
  - The first review found that SIGTERM inside a looped guard didn't end the process. The fix round fixed that. The second review found no blockers. Its findings became 20260923-38.

### 20260923-33. Fail closed on unsupported SQL constructs.

The user decided that enclave code that walks SQL supports an explicit list of constructs and refuses everything else. That covers predicate atoms, relation qualification, the volatility check, and the inbound checks (20260922-10, 11, and 12). The reviews of 20260922-43, 20260922-14, and 20260922-20 kept finding bugs in rare constructs, such as JSON_TABLE, XMLTABLE, typed CYCLE marks, TABLESAMPLE, and ordered-set aggregates. Specs like "no literal survives" covered the whole grammar, so each review found more.
- Define one shared allowlist of pg_query node types, and of the fields within them where it matters, in the enclave gem. Start with the common constructs: SELECT, joins, CTEs (not CYCLE or SEARCH), subqueries, CASE, aggregates, window functions, the usual operators, casts, IN, ANY, LIKE, BETWEEN, and IS NULL.
- Before any walker runs, check the parse against the allowlist. Abort on anything else with the rule `unsupported_construct`, naming the node type. That's shape, and it holds no literals.
- **Constructs outside the list are refused in version 1.** Supporting each one becomes its own task under "After version 1", which the main session adds when this task defines the list. Group them by family, such as JSON_TABLE and the JSON functions, XMLTABLE and the XML functions, CTE CYCLE and SEARCH, and TABLESAMPLE. The user decided this. Special-case code already written for refused constructs, such as the JSON_TABLE path swap, CYCLE marks, and XMLROOT keywords, can stay if its tests still reach it. The after-v1 task for that construct decides whether to enable it or remove it.
- Update README "What goes into the enclave" and step 1 to say that queries using constructs outside the list are refused.
- Review this against the supported list, not the whole grammar. Correctness findings still block landing, since the user kept review severity strict.

- **Depends on:** 20260922-14, 20260922-43, and 20260922-20.
- **Came from:** The user's decision after the reviews of 20260922-43, 20260923-29, and 20260922-20.
- **README:** What goes into the enclave, step 1, and step 9.
- **Status:** done
- **Decided (by the user):** Use the default list: SELECT, joins, CTEs without CYCLE or SEARCH, subqueries, CASE, aggregates, window functions, the usual operators, casts, IN, ANY, LIKE, BETWEEN, and IS NULL. There are no sample queries to check it against.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `SupportedSql.check!` (`enclave/lib/quaack/enclave/supported_sql.rb`) walks every protobuf field and raises `unsupported_construct`, naming only the node type. It's called first by RelationQualifier, VolatilityCheck, GeneratorOne, and PredicateAtoms.
  - Code that only refused constructs could reach was removed, last present in 6507105. That covered DML targets and locking-clause skips in RelationQualifier, TABLESAMPLE in FunctionCalls, and in PredicateAtoms the JSON_TABLE path swap, CYCLE marks, normal-form keywords, TABLESAMPLE FROM items, and SIMILAR TO. GeneratorOne's own statement checks went too.
  - EXTRACT's field keyword is kept in shapes when it's a documented field name.
  - The review ran 60 realistic ORM and reporting queries, and every construct on the list passed.
  - Support for each refused family became an after-v1 task, 20260923-41 through 20260923-52. The minor findings became 20260923-40.

### 20260922-10. Inbound check for rewrite candidates.

Parse each rewrite candidate with pg_query. Accept exactly one `SELECT`. Reject data-modifying CTEs, `SELECT INTO`, and locking clauses. Run the 3d volatility check on it. Each rejection names the rule it broke.

- **Depends on:** 20260922-1, 20260922-20.
- **README:** What goes into the enclave.
- **Note (from the review of 20260922-20):** Run the 3a relation check on rewrite candidates too. Reject views, and relations the original query doesn't use, because a view's body can call a volatile function that the 3d check never sees.
- **Note (from the review of 20260922-46):** The arena runner relies on this check to refuse function calls with side effects that persist or change the session. Examples are `set_config` (which can turn off `statement_timeout`), session-level `pg_advisory_lock` (it survives ROLLBACK), and `lo_import`. The 3d volatility check refuses all of them. Test that it does, and call `SupportedSql.check!` (20260923-33) on every candidate.
- **Status:** done
- **Built early:** built before 3a and 3g. The original's relations and its placeholder count are a plain `Original` input.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `RewriteCandidateCheck.check(sql, original, settings, connection)` runs these checks in order: parse (`unparsable`), `SupportedSql`, placeholders `$1..$N` (`bad_placeholder`), relations (qualified, in the original's set as `unknown_relation`, relkind `r` only as `not_a_table`), then `VolatilityCheck`.
  - It returns `Accepted(sql:, parse:)`. Errors carry a rule, a message with shape-only names, and `cause: nil`.
  - The second review found two vacuous tests, which the tests-only round fixed. It also found that deparse can change a query's meaning, which became 20260923-55.
  - The rest became 20260923-57.

### 20260922-4. Enclave command-line script.

Build the stateless enclave script: a subcommand dispatcher that reads from the governed store, does one step's work, writes new state back, and prints its result. Nothing stays in memory between calls. All output goes through the egress function.

- **Depends on:** 20260922-3, 20260922-7, 20260922-8.
- **README:** Where QUAACK runs.
- **Note (from the reviews of 20260922-8 and 20260922-46):** use `ErrorFilter` (20260922-8) this way:
  - Call `ErrorFilter.silence_stderr!` first.
  - Run the dispatcher inside a single top-level `ErrorFilter.guard`, since nested guards write two lines for one signal.
  - Call `ErrorFilter.drop_notices` on every connection, including production and racetrack, and again after any `conn.reset`.
  - The current CLI prints USAGE to stderr, which will be silenced, so it has to go through egress instead.
  - An error line written after a partial stdout write lands on the same line.
  - A process killed by a signal dies with the signal, so the driver should treat a signal death as a failure and use the error line it already got.
  - Merge the arena runner's local notice receiver with `drop_notices`.
  - Consider `conn.cancel` or a `statement_timeout` when SIGTERM arrives mid-query.
- **Status:** done
- **Note:** Built on branch `task/20260922-4` through a build, a review, a fix round, and a second review, but not landed. The second review found that the input comment scan uses 60 to 80 times the input size in memory. 20260923-53 finishes the work on top of that branch.
- **Note (from the review of 20260922-46):** The enclave's stderr goes over ssh to the laptop, so it's a path around egress. The CLI must control stderr as well as stdout. That covers uncaught exceptions and backtraces, Ruby warnings, and libpq NOTICE and WARNING output on every connection, including production. A PL/pgSQL `RAISE NOTICE` in a stable function can print a row value. Install a notice receiver that drops notices, and send anything else on stderr through egress or discard it.
- **Note:** The static boundary check (20260923-7) flags `require` or `require_relative` of a computed path in the enclave, such as `require_relative "steps/#{name}"` or requiring every file in a directory. So the dispatcher lists its requires by hand and maps subcommands through a table or `public_send`, which is still allowed. That also keeps argv from choosing which file gets loaded.
- **Landed:** Merged into `main` together with 20260923-53.
  - **Step contract:** `CLI` dispatches through a frozen `STEPS` table with requires written out by hand. A step returns message Hashes, and egress serializes them.
  - **Input:** stdin JSON, only for steps that take it, capped at 64 MB. Repeated keys, comments, unknown escapes, and non-finite floats are refused under both json 2.9.1 and 3.0.2.
  - **Output:** buffered, with a final `{"type":"done"}` line on success.
  - **Streams and exits:** `silence_stderr!` and `claim_stdout!`, then one top-level guard. Exits are 0, 64, or 70, or death by the signal. A SystemExit from a step becomes `internal_error`.
  - **Connections:** `Connections.register` drops notices.
  - **Whitelist:** gained `version: [version]` and `done: []`.
  - **Reviews:** the first review asked for fixes to step exits, json parity, and output quirks. The second review's memory blocker went to 20260923-53.

### 20260923-53. Finish the enclave CLI.

Split out of 20260922-4. The work so far is on branch `task/20260922-4`. Build on that branch, then land both together. Fix what the second review of 20260922-4 found:
- **The input comment scan uses 60 to 80 times the input size in memory.** Onigmo pushes a backtrack entry for every character that `+`, `++`, or `*+` repeats. A 64 MB run of spaces took 5 GB, and a 64 MB string took 3.7 GB. An OOM kill is a SIGKILL, so the driver gets no error line. Skip ahead with `skip_until` or `String#index` instead of a repeated class. Pin memory in a test, for example by checking RSS growth in a subprocess on a large input.
- **Unknown escapes mean different things on the two json versions.** json 2.9.1, which the jump server uses, accepts `\q`, `\x41`, `\a`, `\'`, `\0`, and `\U0041` and keeps the escaped character. json 3.0.2 refuses them. Refuse any `\` followed by a character other than `"\/bfnrtu` inside a string, and add these to `INPUT_REFUSED_ON_EVERY_JSON`.
- **Exponent overflow becomes Infinity.** `1e400` parses to `Float::INFINITY` on both versions. Refuse non-finite floats in Input.
- **The driver can't tell `exit!(0)` from an empty success.** The main session's default: every successful run ends with a final `{"type":"done"}` line, and a whitelist `done` type with no fields. The driver treats a run without it as failed. Record that in 20260922-5.

- **Depends on:** 20260922-4's branch.
- **Came from:** Second review of 20260922-4.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The input comment scan uses `skip_until`, with no repeating regex, so memory stays flat, and a peak-RSS test with a sanity guard checks it. Unknown escapes and non-finite floats are refused. Every successful run ends with a `done` line. The second review found no blockers. Leftover findings became 20260923-58.

### 20260922-29. 5a-4 single-candidate testing.

For each candidate: reset HypoPG, create the hypothetical index, `EXPLAIN` the query once per literal set, and record index use, cost, canonical plan, and `hypopg_relation_size`. Keep results for unused candidates. Must work for the original query and for rewrite candidates.

- **Depends on:** 20260922-26, 20260922-21, 20260922-15, 20260922-23.
- **README:** 5a-4.
- **Note (from the review of 20260923-32):** Egress uses json's default `max_nesting` of 100, and a plan takes two levels per node. So a redacted or canonical plan more than about 48 nodes deep can't go out. Decide whether to flatten plans, set an explicit `max_nesting` together with a stack rescue, or refuse them with a clear rule.
- **Status:** done
- **Note:** This task was built on branch `task/20260922-29` through a build, a review, a fix round, and a second review, but not landed. The second review found that dropping `SET LOCAL plan_cache_mode = force_custom_plan` lets a session or database `force_generic_plan` setting make every plan generic. 20260923-39 finishes it on top of that branch.
- **Landed:** Merged into `main` together with 20260923-39 and 20260923-56.
  - `SingleCandidateTest.run(conn, query:, literal_sets:, candidates:)` runs inside one transaction that it rolls back. It sets `SET LOCAL plan_cache_mode = force_custom_plan` and `hypopg.enabled = on`, calls `hypopg_reset`, and refuses (`indexes_hidden`) if any indexes are hidden.
  - For each candidate, it creates the index in a savepoint. Then for each literal set, it prepares the query fresh, runs EXPLAIN EXECUTE, and deallocates.
  - It records whether the index was used (matched by exact name), the cost, a CanonicalPlan keyed by the candidate's `to_ddl`, and the size. It also records a baseline.
  - Literals are validated up front. SQLSTATEs are sorted into refusals and session failures. The first error is kept, notices are dropped, and deep plans parse.
  - The two second reviews found regressions (`force_generic_plan`, then `hypopg.enabled` and hidden indexes), each fixed in a split-off task.

### 20260923-39. Finish 5a-4 single-candidate testing.

This was split out of 20260922-29. The work so far is on branch `task/20260922-29`. Build on that branch, then land both together. Fix what the second review of 20260922-29 found:
- **`plan_cache_mode = force_generic_plan` makes every plan generic.** Postgres checks the setting before the execution count, so it applies even on a statement's first EXECUTE. The reviewer reproduced it on a session and on a database: the Filter was `(s = $1)`, and both literal sets showed the index as used. Put `SET LOCAL plan_cache_mode = force_custom_plan` back inside the transaction. Test it with the setting on the database, asserting that the literal sets differ and that the Filter holds the literal. Fix the module comment too.
- **The session-failure SQLSTATE classes are untested.** Dropping any of `08`, `25`, `40`, `53`, `58`, or the `XX001`/`XX002` pattern stays green. Add a table test that raises each one (`RAISE ... USING ERRCODE`) during create and expects `hypopg_failed`.
- **A lock timeout (`55P03`) during create counts as a refusal.** Consider adding it to the session-failure list.

- **Depends on:** 20260922-29's branch.
- **Came from:** Second review of 20260922-29.
- **README:** 5a-4.
- **Status:** done
- **Note:** Built on branch `task/20260923-39` with a build, a review, a fix round, and a second review, but not landed. The second review found that hidden real indexes skew the plans, and that deep plans raise a raw `JSON::NestingError`. 20260923-56 finishes it on top of that branch.
- **Landed:** Merged into `main` together with 20260922-29 and 20260923-56. It restored `force_custom_plan`, tested every session-failure SQLSTATE, and added `hypopg.enabled = on`, keep-the-first-error, and exact index-name matching.

### 20260923-56. Finish 5a-4, second pass.

Split out of 20260923-39. The work so far is on branch `task/20260923-39`, which carries 20260922-29. Build on that branch, then land all three together. Fix what the second review of 20260923-39 found:
- **A real index hidden with HypoPG skews every plan without warning.** HypoPG keeps hidden indexes per session, and `hypopg_reset()` doesn't clear hidden real ones. In the reproduction, the baseline cost went from 8.31 to 1887.0 and the run returned normally. Refuse when `hypopg_hidden_indexes()` isn't empty, with a new rule such as `indexes_hidden`. Don't unhide them, since that isn't transactional. Add a comment that HypoPG older than 1.4 fails closed.
- **A plan more than about 48 nodes deep raises a raw `JSON::NestingError`.** A 60-table join chain is enough. Parse EXPLAIN output with `max_nesting: false`, or with a documented cap that gives a clear refusal rule, and test it with a deep plan. This settles the parsing half of the note on 20260922-29. Sending plans through egress is still open.
- **Surviving mutants:**
  - Unanchored SQLSTATE class alternatives. Pin them with a refusal code such as `22025` or `42P08` that contains one of the class pairs.
  - An index-name match on `start_with?("<")`.
  - The `RELEASE SAVEPOINT` line, which you can delete, or explain why it's there.

- **Depends on:** 20260923-39's branch.
- **Came from:** Second review of 20260923-39.
- **README:** 5a-4.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It refuses when HypoPG has hidden indexes, parses plans with `max_nesting: false`, and pins the anchored SQLSTATE classes. It also has tests for the check order, a leftover prepared statement, and a real index with a hypothetical-looking name. The first review listed every piece of state the runner depends on, and that list went to 20260922-25. The second review found no blockers. Its findings became 20260924-1.

### 20260922-13. Input intake.

Read the three operator inputs from the governed store (query text, `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` output, and server name) and check that they're well formed.

- **Depends on:** 20260922-3, 20260922-4.
- **README:** Step 1.
- **Note (from 20260923-33):** Call `SupportedSql.check!` on the input query, so unsupported constructs are refused at intake.
- **Status:** done
- **Decided:** The operator runs a `quaacks` subcommand on the jump server, such as `quaacks intake --query q.sql --plan plan.json --server prod-db-3`. It checks the inputs, creates the run, and prints the run ID for the driver to use.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - **Usage:** `quaacks intake --query F --plan F --server NAME [--captured-at T]`.
  - **Files:** it reads regular files only, no symlinks, up to 16 MB each, and strips one leading BOM.
  - **Query checks:** UTF-8, no NUL bytes, it parses, exactly one statement, `SupportedSql`, and no `$n` parameters.
  - **Plan checks:** strict JSON, shaped `[{"Plan":...}]`, with ANALYZE and BUFFERS present. `Settings` can be missing or `{}`.
  - **Other checks:** a hostname-shaped server, and `--captured-at` in ISO-8601 with a zone, from 1970 up to one day after intake.
  - **On success:** a `CLI::Step new_run: true` run stores `query`, `plan`, `server`, and `clock_anchor` (UTC ISO-8601 with microseconds), then outputs `run: [run_id]` and `done`.
  - **On failure:** the run is deleted, and the error carries only the rule. Arguments are parsed before the run is created.
  - The second review found no blockers. Its findings went into 20260924-3.

### 20260923-55. Round-trip guard for deparsed SQL.

pg_query's deparser can change what a query means. `WHERE (status = $1) IS NOT DISTINCT FROM (true AND false)` deparses as `status = $1 IS NOT DISTINCT FROM true AND false`, which returned 0 rows where the original returned 20000. `(ARRAY(SELECT ...))[1]` deparses as `ARRAY(SELECT ...)[1]`, which doesn't parse. `RelationQualifier` (20260922-14) returns deparsed SQL, so both the original query in step 1 and every rewrite candidate that passes 20260922-10 can silently become a different query.
- After deparsing, reparse the SQL and compare its tree with the tree that was deparsed, ignoring locations. Refuse on a mismatch or a parse failure, with a rule such as `deparse_mismatch` and a fixed message. Put the guard in one shared place and use it in RelationQualifier. It also covers the `with_true` guard in 20260923-30.
- In 20260922-10, wrap the reparse so a parse failure raises `RewriteCandidateCheck::Error`, not a raw `PgQuery::ParseError`. Also run `SupportedSql` and the placeholder check on `Accepted.parse`, not only on the candidate's own parse.
- Test with the two repros above against real Postgres, plus the other deparse cases listed in 20260923-30.

- **Depends on:** 20260922-14, 20260922-10.
- **Came from:** Second review of 20260922-10.
- **README:** Step 1, and "What goes into the enclave".
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - **The guard:** `Deparse.faithfully`, `expression`, and `statement` deparse, reparse, and compare whole protobuf trees after clearing `version` and the int32 location fields. A mismatch raises `deparse_mismatch`.
  - **Where it's wired in:** RelationQualifier (which now returns `parse`), RewriteCandidateCheck, `with_true`, IndexSql `normalize_predicate` and `from_ddl`, `IndexCandidate#to_ddl`, and `PlanExpression.unqualified_sql`. GeneratorTwo skips a partial that doesn't round-trip. Shapes, which are report-only, aren't guarded.
  - **Checked against:** about 270 realistic queries, with no over-refusal.
  - Constructs that the guard now refuses because pg_query drops their parentheses became 20260924-4.

### 20260922-47. 9d result comparator.

Compare results using the rules for no `ORDER BY`, a partial `ORDER BY` (add a tiebreaker), `LIMIT` without `ORDER BY` (subset check), and float tolerance.

- **Depends on:** 20260922-46.
- **README:** 9d.
- **Status:** done
- **Note:** Built on branch `task/20260922-47` through a build, a review, a fix round, and a second review, but not landed. The second review found false matches when a tie crosses a LIMIT or OFFSET cut or a DISTINCT ON pick, and when a column is an enum. 20260923-54 finishes it on top of that branch.
- **Decided:** `float4` and `float8` values are equal within a relative 1e-9, with an absolute 1e-12 near zero. Numeric and integer columns compare exactly.
- **Landed:** Merged into `main` together with 20260923-54 and 20260924-2. `ResultComparator` compares two ArenaRunner Results, and `ResultComparison` shapes the queries with pg_query and runs them. The comparison works like this:
  - With no ORDER BY, it compares multisets.
  - With ORDER BY, it compares in order twice, once with an ascending tiebreaker and once with a descending one, on the output positions of faithful types.
  - For LIMIT with no ORDER BY, it does a subset check.
  - It refuses as `unsupported_order` for WITH TIES, for an original whose two runs differ (a tie at a cut), for left-out types (interval, jsonb, and containers of numeric or float) when either query has a top-level cut or a hidden difference, and for nondeterministic collations.
  - Floats use a relative 1e-9 and an absolute 1e-12 tolerance, which the user decided. Numeric is compared by value, and bpchar ignores trailing spaces.
  - The verdict holds no values.
  - The reviews found three kinds of false match, each fixed in a split-off task. The leftovers became 20260924-5, 20260924-6, and 20260924-7.

### 20260923-54. Finish the 9d result comparator.

Split out of 20260922-47. The work so far is on branch `task/20260922-47`. Build on that branch, then land both together. Fix what the second review of 20260922-47 found:
- **A false match when a tie crosses a LIMIT or OFFSET cut, or a DISTINCT ON pick.** The two tiebreaker runs, ascending and then descending, only expose the first and last row of each tie group. So a candidate can widen the tie at the cut and still match both runs. The reviewer reproduced this for LIMIT, DISTINCT ON, and OFFSET on real Postgres.
  - The main session's default is to fail closed. If the original's ascending and descending runs return different row multisets, the original depends on how ties break, so refuse the comparison with `unsupported_order` and never report a match.
  - Otherwise the two-run scheme is sound. Test all three repros.
  - A precise check could come later: the rows before the tied group must match exactly, and the rest must be drawn from that group.
- **Enum columns are left out of the tiebreaker, which allows a false match.** For example, `ORDER BY m` on an enum matched a candidate that sorted by another column. Include enums by looking up the catalog (`typtype = 'e'`), and ranges and composites too if that's cheap. Test it.
- **The comment claiming `max` and `min` are equivalent is wrong.** 7.603 against 7.603000007603 is equal under `max` and unequal under `min`. Fix the comment, and pin that pair in a test.

- **Depends on:** 20260922-47's branch.
- **Came from:** Second review of 20260922-47.
- **README:** 9d.
- **Status:** done
- **Note:** Built on branch `task/20260923-54` through a build, a review, a fix round, a second review, a tests-only round, and a tests-only review, but not landed. The tests-only review found the tie-of-three test still vacuous against a first-versus-last mutant in `hidden_differences?`. 20260924-2 fixes that test, and then both land together.
- **Landed:** Merged into `main` together with 20260922-47 and 20260924-2. It added the fail-closed tie-at-cut refusal, catalog-driven enums, ranges, and composites, the faithful-types principle, bpchar trailing-space equality, and the collation refusal.

### 20260924-2. Pin hidden_differences? for every row in a tie group.

Split out of 20260923-54. Build on its branch `task/20260923-54`, then land both together. The tests-only review of 20260923-54 found "refuses an interval column when a tie of three hides a different interval behind a repeat" still vacuous. Changing `hidden_differences?` in `result_comparison/tiebreaker.rb` to compare only `rows.first` and `rows.last` survives the whole suite, because the fixture ['1 day', '1 day', '24 hours'] puts the odd value last. Add a fixture with the odd value in the middle, such as ['1 day', '24 hours', '1 day'] or a group of four. It must go red under the first-two, first-and-last, and `all?` mutants.

Also, from the same review:
- The two composite tests (numeric and interval) should assert `rule: :unsupported_order`, not just `match? == false`.

- **Depends on:** 20260923-54's branch.
- **Came from:** Tests-only review of 20260923-54.
- **README:** 9d.
- **Status:** done
- **Landed:** Merged into `main` together with 20260922-47 and 20260923-54, after a build and two reviews. A four-row fixture pins `hidden_differences?`, and the composite tests assert `unsupported_order`.

### 20260922-61. Burndown counters.

Record per-stage counts (in, added, dropped by reason, out) in the governed store as each enclave step runs, and in the driver for LLM calls. Every stage task should call into this as it's built.

- **Depends on:** 20260922-3, 20260922-7.
- **README:** 15b.
- **Status:** done
- **Note:** This should be built early, right after the foundations, even though it lives in this section.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `Quaack::Enclave::Burndown` keeps a single `burndown` Store entry, keyed by stage and search, plus work totals. Every write checks `in + added - dropped - set_aside == out`.
  - Adapters: `record_dedupe` (5a-3), `record_single_candidate_test` (5a-4), and `record_llm_round` (one combined 5a-5 or 5a-6 record per round).
  - The shape predicate `Protocol::Burndown.valid?` lives in the protocol gem. Egress and the store both use it, so a hand-built `burndown` message can't carry a value.
  - The driver's `Burndown` counts LLM calls by step.
  - The whitelist gained `burndown: [stages, totals]`.
  - The second review found no blockers. Its findings became 20260924-8.

### 20260924-5. Rerun 9d comparisons with the fixture loaded in reverse.

High priority. A rewrite that drops a secondary sort key below the top level matches by luck, because fixtures load in id order and small sorts keep input order. Examples are a subquery `ORDER BY grp, id LIMIT 2` becoming `ORDER BY grp LIMIT 2`, and a LATERAL top-1 that drops `, id`. That's a realistic LLM mistake, and README 9d only covers the top level. Run each 9d comparison a second time with the same fixture loaded in reverse physical order, and require both runs to match. This also covers the DISTINCT and GROUP BY representative gaps and the multiset collation gap that the reviews of 20260923-54 documented. It belongs in step 9 orchestration (20260922-49) or ArenaRunner. Decide which, and update README 9d.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **README:** 9d.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `ResultComparison.compare_in_both_orders(runner, rows, original:, candidate:, inserts: [])` runs 9d twice, once with the fixture loaded forward and once reversed within each same-table run, and both runs must match.
  - The verdict records `load_order`. Raw inserts aren't reversed.
  - Both runs use `ArenaRunner#with_fixture(index_scans: false)`, which turns off index, index-only, and bitmap scans with SET LOCAL, so an index can't return ties in a fixed order.
  - A reverse-only load failure is `reverse_load_failed`.
  - In the second review, randomized probes found 15 survivors in about 1,900 wrong candidates. Its findings became 20260924-9.

### 20260922-35. 5a-7 combination and ranking.

Combine candidates greedily up to three indexes. Rank by worst-case cost reduction across literals, and break ties by size. Keep the top three plus the best combination if it wins. Each kept entry carries DDL, size, costs per literal, canonical plan, and partial-index tag.

- **Depends on:** 20260922-29.
- **README:** 5a-7.
- **Status:** done
- **Defaults the main session chose (the user was away):**
  - Reduction is `1 − after/before` per literal set, and the worst case is the minimum across sets.
  - Rank by worst case, highest first. Break ties by size, smallest first, then by DDL.
  - Combine greedily from the best single index. Keep an added partner only when the worst case strictly improves and every index gets used. Stop at three indexes.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `IndexRanking.rank(conn, query:, literal_sets:, baseline:, results:)` returns `Ranking(top:, combination:)`. Each entry carries the DDL, the size, the cost before and after for each literal set, `used`, the canonical plans, and `partial`. Inspect leaves out the DDL.
  - 5a-4's runner became a public `SingleCandidateTest::Session`, with `measure(candidates)` for several hypothetical indexes at once. All of 5a-4's safety moved over with it (the reviewers checked 28 mutants). Every measure resets HypoPG, and a closed session refuses to measure.
  - Leftover findings became 20260924-10.
