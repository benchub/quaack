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

### 20260922-6. LLM client.

Build the driver's LLM client, with a test double so tests never make real LLM calls. Count every call by step for the 15b burndown.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs, 15b.
- **Status:** done
- **Decided:**
  - Use the Anthropic API through the official `anthropic` Ruby gem. The key comes from `ANTHROPIC_API_KEY` on the laptop. The default model is `claude-opus-5-5`, and config can override it.
  - Don't build a provider abstraction yet, but don't make one hard to add later. The user may want other providers, or several models working in parallel, someday.
- **Landed:** Merged into `main` after two reviews. The first review's findings were fixed in the builder's one fix round. The second review found no blockers, and its minor findings went to 20260924-14.

### 20260922-66. Run teardown.

At the end of a run, delete the governed store directory and tell the operator to destroy the run server.

- **Depends on:** 20260922-3.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:** Teardown runs when a run ends, whether it succeeded or aborted. A `--keep` flag leaves the run server and store directory in place for debugging, and `quaacks teardown --run <run>` removes the store later. It only reminds the operator to destroy the run server.
- **Landed:** The enclave side was merged into `main` after a review, a fix round, and a clean second review. It adds `quaacks teardown --run <id>`, `Store.teardown`, the `teardown` whitelist type (`run_id`, `store`, `next_step`), and the rules `bad_run`, `bad_store_base`, and `teardown_failed`. The driver side (automatic teardown when a run ends, and `--keep`) is wiring, so it moved to 20260922-65 as a note. The minor findings went to 20260924-17.

### 20260922-5. Driver transport.

Build the driver side of the link: call enclave subcommands over ssh, pass arguments and untrusted inputs, and parse the results. Include a local transport so tests can run the enclave script without ssh.

- **Depends on:** 20260922-4.
- **README:** Where QUAACK runs.
- **Note (from the reviews of 20260922-4 and 20260922-8):** The driver's contract for reading `quaacks` output:
  - Skip blank lines, and lines that aren't JSON.
  - Treat any run as failed if it printed an error line, exited nonzero, or died by a signal, and discard its other lines. A signal in the middle of a write can leave a cut-off line, and valid-looking lines can come before the error line.
  - Exit codes are 0 for success, 64 when the CLI refuses a call, and 70 when a step fails. A signal death means the process died by that signal after writing its error line.
- **Note (from the second review of 20260922-4):** A step can end the process with `exit!(0)`, which prints nothing, so an empty stdout isn't proof of success. 20260923-53 adds a final `done` line to every successful run. Treat a run as failed unless `done` is its last non-blank line. A flush failure can print `done` and then an error line.
- **Status:** done
- **Decided:** Larger inputs go to the enclave script as a JSON document on stdin, piped into `ssh <jump server> quaacks <subcommand>`. The local test transport pipes the same JSON.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of those tests. It has `Transport::Local` and `Transport::Ssh` with `call(subcommand, args:, input:)`, and `EnclaveError` with only shaped fields. Any line that breaks the whitelist fails the run as `unexpected_output`. The minor findings went to 20260924-20.

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

### 20260922-9. Leak tests.

Build a reusable test helper that runs a step on data with known sentinel values and fails if any sentinel shows up in enclave output. Every later enclave task should use it.

- **Depends on:** 20260922-7, 20260922-2.
- **README:** Trust boundary.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The helper is in `enclave/spec/support/leak_check*`:
  - `LeakCheck::Sentinels` makes text, word, number, date (Gregorian, 1100 to 1899), json, and LIKE sentinels.
  - `LeakCheck.findings` scans stdout, stderr, status, and objects: inspect, to_s, messages, backtraces, causes, ivars, members, and a StringIO's `#string`. It refuses a StringIO or IO where a String belongs.
  - `expect_no_leaks` runs an isolated positive control first, with every needle in every place.
  - `LeakCheck::Quaacks` runs the installed gem outside Bundler with a temporary HOME.
  - `LeakCheck::Fixture.plant` seeds sentinels into `pg_stats`.
  - The intake and error_filter specs use it.

  The second review found no blockers. Its findings became 20260924-13.

### 20260922-24. 3h clock anchoring.

Replace the listed time functions with `quaack.clock_anchor()` in the AST. Keep a way to put the original functions back for the report.

- **Depends on:** 20260922-14.
- **README:** 3h.
- **Note (from 20260922-13):** Intake stores `clock_anchor` as a UTC ISO-8601 string with microseconds, such as `2026-09-24T07:35:44.661129Z`.
- **Status:** done
- **Note:** Built on branch `task/20260922-24` through a build, a review, a fix round, and a second review, but not landed. The second review found that anchoring renames implicit output columns and function-in-FROM aliases, which can silently rebind `ORDER BY now`. 20260924-12 finishes it on top of that branch.
- **Decided:** `quaacks intake` takes an optional `--captured-at` flag, the time the production plan ran. Without it, the anchor is the time of intake. The run stores the anchor, and `clock_anchor()` returns it.
- **Landed:** Merged into `main` together with 20260924-12, which finished it.

### 20260924-12. Finish 3h clock anchoring.

Split out of 20260922-24. The work so far is on branch `task/20260922-24`. Build on that branch, then land both together. Fix what the second review of 20260922-24 found:
- **Anchoring changes implicit names.** Postgres names an unaliased `now()` column `now`, and it looks through casts, so `now()::date` is also `now`. `CURRENT_DATE` is `current_date`, and `LOCALTIMESTAMP` is `localtimestamp`. After anchoring, the names become `clock_anchor`, `date`, or `timestamp`. So each of these fails after anchoring:
  - `SELECT s.now FROM (SELECT now()) s`
  - `WITH w AS (SELECT now()) SELECT w.now FROM w`
  - `SELECT now() ORDER BY now`
  - `SELECT now.now FROM now()`

  The worst case is silent. In `SELECT id, now()::date FROM public.ev ORDER BY now`, where `ev` has a column named `now`, `ORDER BY now` rebinds to the table column and the order changes. Keep the original names: set `ResTarget.name` when it's empty, and add an alias when an unaliased function in FROM is anchored. Make `restore` handle or remove what anchoring added. Test each case on Postgres, including the silent one and `GROUP BY` by name.
- **Minor:**
  - `NodeRewrite` has no spec of its own.
  - The "is plain strings" test passes on an empty list.

- **Depends on:** 20260922-24's branch.
- **Came from:** Second review of 20260922-24.
- **README:** 3h.
- **Status:** done
- **Landed:** Merged into `main` with 20260922-24 after a review, a fix round, and a second review. The second review found no blockers, and its minor findings went to 20260924-15.

### 20260923-34. Governed store loose ends.

Minor findings from the second review of 20260923-32:
- **`Store.open` and `#teardown` still let a raw `SystemCallError` out of `PrivateFiles.lstat`.** For example, after `File.chmod(0, base)`, both raise `Errno::EACCES` naming `<base>/<run_id>`. A base that's a regular file gives `Errno::ENOTDIR`. Nothing below the run directory is named, so nothing leaks, but the class promises `Store::Error`.
- **The 4 MB-thread test pins `MAX_DEPTH` loosely on macOS.** A value of 6,000 still passes there, though it would likely fail on aarch64 Linux.
- **Reading an entry that's a FIFO blocks forever.** Only the owner can plant one, so this is informational.

- **Depends on:** 20260923-32.
- **Came from:** Second review of 20260923-32.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note (from the review of 20260922-66):** A symlinked store base (`~/.quaack/runs`) is followed by create, open, and teardown. Decide whether to refuse it.
- **Decided:** A symlinked store base (`~/.quaack/runs` or `~/.quaack`) is refused, failing closed. Only QUAACK's own components are checked, not the operator's home directory. The CLI sends `bad_store_base` for any base it can't use.
- **Landed:** Merged into `main` after a review, a fix round, and a clean second review. The minor findings went to 20260924-18.

### 20260922-17. 3a relations.

List the query's relations with pg_query and check each `relkind`. Abort on views and materialized views.

- **Depends on:** 20260922-14.
- **README:** 3a.
- **Status:** done
- **Decided:** Allow only plain tables (`relkind` `r`). Abort on views, materialized views, partitioned tables, and foreign tables, and name the relation and its kind in the message.
- **Decided (main session, pending the user):** Each kind gets its own rule: `view_relation`, `matview_relation`, `partitioned_relation`, `foreign_relation`, `sequence_relation`, `composite_type_relation`, `toast_relation`, `index_relation`, and `not_a_table`. The relation name stays in the enclave. Unless every reference says ONLY, every inheritance descendant is checked, and the first one that isn't `r` is refused. Relations are checked in the query's text order.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of those tests. The entry point is `Relations.check(sql, settings, connection)`. The minor findings went to 20260924-19.

### 20260922-18. 3b schema dump and subset.

Run the full schema-only dump on every namespace the query touches, plus `public`. Build the subset: the query's tables and their FK parent tables.

- **Depends on:** 20260922-17.
- **README:** 3b.
- **Status:** done
- **Decided:**
  - Include the whole FK chain up, not only direct parents, so arena can satisfy every FK.
  - Don't parse the dump. Find the subset tables and their FK ancestors from `pg_catalog`, and get the subset from `pg_dump --table` for each one. This came from 20260923-1.
- **Decided (user, September 24):** For v1, schema DDL is assumed to hold no PII, so the subset can go to the LLM as is.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of that test. The entry point is `SchemaDump.run(store:, relations:, connection:, conninfo:, pg_dump:)`, and it stores `schema_dump` and `schema_subset`. The leftover findings went to 20260924-22.

### 20260924-4. Parenthesize what pg_query deparses wrong.

The round-trip guard (20260923-55) now correctly refuses supported constructs that pg_query's deparser prints without needed parentheses, which would change their meaning:
- `(a OR b) IS NULL`
- `(a AND b) IS NOT NULL`
- `(NOT a) IS NULL`
- `(a AND b) IN (true)`
- `(a AND b) = ANY(...)`
- `(a = 1) = ANY(ARRAY[true])`
- `a IS NOT DISTINCT FROM (b AND c)`
- `a BETWEEN (b AND c) AND d`
- `created_at AT TIME ZONE ('UTC' || '')`

Before deparsing, wrap the operand in an explicit parenthesis node, or post-process the SQL, so these round-trip and stop being refused. Keep the guard in place as the check. Also consider fixing shapes, which use `deparse_expr` and so turn `EXISTS (SELECT WHERE x)` into `EXISTS (x)`.

- **Depends on:** 20260923-55.
- **Came from:** The reviews of 20260923-55.
- **README:** Step 1.
- **Status:** done
- **Landed:** Merged into `main` after two reviews. The second review was clean: 77,000 fuzzed supported queries round-trip with none refused, and 2,798 gave the same rows on PG18. `Deparse::Parentheses.add!` wraps operands before deparsing, and the round-trip guard still runs last. The leftovers went to 20260924-23.

### 20260922-16. Production inventory.

Check the connection to the production server and record the version, extensions, memory, planner settings, parallel settings, non-default GUCs from the plan's `SETTINGS`, `pg_database` locale fields, and `default_text_search_config`.

- **Depends on:** 20260922-4, 20260922-13.
- **README:** Step 2.
- **Status:** done
- **Decided:**
  - Connect with the operator's own libpq setup on the jump server: the host from the input, plus `PGUSER`, `~/.pgpass`, and `~/.pg_service.conf`. QUAACK stores no credentials, and it reads inside a read-only transaction.
  - A `quaacks` config value holds a one-line shell command for finding instance memory, with the hostname filled in. The enclave script runs it on the jump server. That leaves room for any cloud provider.
- **Open questions:** What does the memory command print (bytes, or a size like `64GB`)? What happens when it isn't configured, or when it fails?
- **Answered (main session default, pending the user):** The memory command prints bytes, or a number with a kB, MB, GB, TB, KiB, MiB, GiB, or TiB unit (all binary). If it isn't configured, memory is unknown and the run continues. If it's configured and fails, the run aborts with `memory_command_failed`, `memory_command_timed_out`, or `memory_command_bad_output`. The config is `~/.quaack/config.json`, with `memory_command` and a `{host}` placeholder.
- **Landed:** Merged into `main` after a review, a fix round with only the one blocker (`enable_gathermerge`), and a clean second review. It adds `quaacks inventory --run <id>` and the whitelist type `inventory: [major_version, memory_known]`, and makes `pg` a runtime dependency of quaacks. The minor findings went to 20260924-24.

### 20260922-23. 3g redaction.

Replace literals with numbered, shape-preserving placeholders. Annotate each with estimated and actual rows from the consuming plan node. Strip literals from plan quals. Keep the placeholder map in the store. Bind real literals with `PREPARE` when running placeholder queries. Make the plan redaction reusable for racetrack plans.

- **Depends on:** 20260922-13, 20260922-15.
- **README:** 3g.
- **Note (from the review of 20260923-32):** Egress uses json's default `max_nesting` of 100, and a plan takes two levels per node. So a redacted or canonical plan more than about 48 nodes deep can't go out. Decide whether to flatten plans, set an explicit `max_nesting` together with a stack rescue, or refuse them with a clear rule.
- **Status:** done
- **Note:** Built on branch `task/20260922-23` through a build, a review, a fix round, and a second review, but not landed. The second review found that a string like `'1e99999999'` hangs `Rational()` in the matcher. 20260924-11 finishes it on top of that branch.
- **Decided:** Match each literal in a racetrack plan to the placeholder map by value, after normalizing casts. Replace anything still unmatched with a generic `$?` marker, so no literal leaks, and count the masks for the 15b burndown.
- **Landed:** Merged into `main` together with 20260924-11 and 20260924-16, which finished it.

### 20260924-11. Finish 3g redaction.

Split out of 20260922-23. The work so far is on branch `task/20260922-23`. Build on that branch, then land both together. Fix what the second review of 20260922-23 found:
- **A huge exponent hangs redaction.** `Matcher#number` calls `Rational(text)` on any text that looks like a decimal, with any exponent. `Rational("1e99999999")` doesn't finish in 60 seconds. An untyped string placeholder is `unknown`, which is in `NUMBERS_FROM`, so `WHERE t.s = '1e99999999'` hangs. Cap the exponent and the digit count before converting, or compare some other bounded way. Test it with a timeout.
- **Bit strings never match real plans.** PG18 prints `B'10110'` as `'10110'::bit varying`, and `X'1F'` as `'00011111'::"bit"`. The matcher never compares a string token with a bit placeholder, so the `bits?` branch never runs for real plans. Match them, and test with real PG18 output.
- **Surviving mutants:**
  - The retry-cap guard (`@types[number - 1] == "unknown"`). Test it with a fake connection that repeats 42P18 for the same parameter.
  - The ESCAPE `uncast`. Test `ESCAPE '!'::text`.

- **Depends on:** 20260922-23's branch.
- **Came from:** Second review of 20260922-23.
- **README:** 3g.
- **Status:** done
- **Note:** Built on branch `task/20260924-11` (on top of `task/20260922-23`) through a build, a review, a fix round, and a second review, but not landed. This task's own items are fixed and verified. The second review found three new blockers, and 20260924-16 finishes the work on the same branch.
- **Landed:** Merged into `main` with 20260922-23 and 20260924-16.

### 20260924-16. Finish 3g redaction, part two.

Split out of 20260924-11. The work so far is on branch `task/20260924-11`, which also carries 20260922-23. Build on that branch, then land all three together. Fix what the second review of 20260924-11 found:
- **A number like `5.e3` crashes redaction, and the error message quotes the literal.** `DECIMAL` accepts `\d+\.` followed by an exponent, but `Rational("5.e3")` raises `ArgumentError: invalid value for convert(): "5.e3"`. It fires while the map is built, for any `unknown` or number placeholder (`t.s = '918273.e5'`, or the numeric literal `t.n = 918273.e5`), and in `Redaction.plan` on plan tokens. Match or mask the literal, and never raise with it in the message. Look for other texts that `DECIMAL` accepts but `Rational` or `Literal` refuse.
- **An expression that appears in both GROUP BY and the select list, ORDER BY, or HAVING gets two placeholders, so it can't be prepared.** `SELECT date_trunc('day', o.created_at), count(*) FROM public.orders o GROUP BY date_trunc('day', o.created_at)` becomes `date_trunc($1, ...) ... GROUP BY date_trunc($2, ...)`, and `Binding#prepare` fails with 42803. `o.status || '-x'` fails the same way. **Main session default, pending the user:** where Postgres requires two expressions to match (GROUP BY against the target list, ORDER BY, and HAVING; DISTINCT ON against the leading ORDER BY; SELECT DISTINCT against ORDER BY; and any others you find), equal literals in matching positions of structurally identical expressions share one placeholder. Everywhere else, keep one placeholder per occurrence. The map still sends each placeholder to exactly one value. Record the rule in README 3g. Test by binding and running the redacted query on real PG18, and check that the rows match the original's. The existing "GROUP BY and HAVING" sentinel query has to bind, too.
- **Vacuous test: "refuses SQL that isn't one SELECT".** Changing `unless stmts.size == 1 && stmts.first.stmt.select_stmt` to `unless stmts.size == 1` survives, because the only input has two statements. Add a single non-SELECT, such as `DELETE ... WHERE id = $1`.
- **Binding accepts a data-modifying CTE and `FOR UPDATE`,** which SupportedSql refuses. Refuse them in Binding too, or narrow the doc's "exactly one SELECT" claim to what's checked.
- **Surviving mutants worth killing:**
  - `literal.rb`: `digits = text.delete("_")` → `text` (PREPARE would declare `1_000_000_000_000` as numeric). The `INT8` bounds (±1). `> MAX_DIGITS` → `>=`. Dropping `.delete_prefix("+")`. `class_of` for a Float node (the shape of 5000000000).
  - `matcher.rb`: the `MAX_NUMBER` boundary (`>=`, 99, 101). `NUMBER_TYPES` without `bigint`. `[eE]` and `[+-]?` in `DECIMAL`. `TRUE_TEXT` and `FALSE_TEXT` members. The `strip` and `downcase` in `word`. The `.sort` on the number and boolean branches.
  - `expression.rb`: the array `rescue ArgumentError` not counting its mask.
  - `binding.rb`: dropping `raise unless postgres_error?(e)`. The 42P18 sqlstate check and the regex anchors in `untyped_parameter`. Deleting `RELEASE SAVEPOINT`. Capping retries at two (test a query with two untyped parameters, such as `concat('a', 'b')`).
- **The huge-exponent test's `Timeout` can't interrupt `Rational()`.** Make the test fail fast without the cap, for example by running the call in a subprocess with a kill.

The three `Cast` survivors in `expression.rb` (the WITH line in `Cast#word?`, `after_word?` in `modifiers`, and the `break` on `","`) couldn't be reached from a real PG18 plan. Kill them if you can build a reachable case. Otherwise, say so.

- **Depends on:** 20260924-11's branch.
- **Came from:** Second review of 20260924-11.
- **README:** 3g.
- **Status:** done
- **Decided (user, September 24):** Where Postgres requires two expressions to match, equal literals in matching positions share one placeholder. Otherwise, each occurrence gets its own.
- **Landed:** Merged into `main` with 20260922-23 and 20260924-11, after a review, a fix round with only the blockers, a second review, a tests-only round, and a fresh check of those tests. The leftovers went to 20260924-25.

### 20260924-21. 9d Shape deparses without the round-trip guard.

**High priority. It's a correctness bug in the 9d comparison.** `ResultComparison::Shape#build` in `enclave/lib/quaack/enclave/result_comparison.rb` calls raw `PgQuery.deparse`, with no round-trip guard and no parentheses. It runs on the real 9d path: `without_limit`, `with_tiebreaker`, and `probe`. For example, `Shape.parse("SELECT id FROM t WHERE (a OR b) IS NULL ORDER BY id LIMIT 5", nil).without_limit` returns `SELECT id FROM t WHERE a OR b IS NULL ORDER BY id`. That's a different query, and it silently changes what 9d compares. Route it through `Deparse.faithfully` (with the parentheses fix from 20260924-4 once that lands), and refuse cleanly when the guard refuses. Add a PG18 test where the raw deparse would change the rows. Also check for other raw `PgQuery.deparse` or `deparse_expr` calls in the enclave that build SQL to run, and route each one through the guard.

- **Depends on:** 20260922-47, 20260923-55.
- **Came from:** First review of 20260924-4.
- **README:** 9d, Step 1.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. `Shape#build` uses `Deparse.faithfully`, and a refusal raises `ResultComparison::Error` with rule `deparse_mismatch`. `without_limit` also resets `limit_option`. A grep found no other enclave code that deparses SQL for running without the guard. A minor note: `LIMIT ALL` and `LIMIT NULL` use subset mode, which is harmless.

### 20260922-19. 3c statistics.

Pull planner statistics (including extended statistics), index definitions, and index sizes for the query's tables. Keep them in the governed store as value-class data.

- **Depends on:** 20260922-17.
- **README:** 3c.
- **Note (from the review of 20260922-32):** Leave out invalid indexes (`indisvalid = false`), or a failed `CREATE INDEX CONCURRENTLY` counts as covering in 5a-3. Also fill `TableStatistics#indexes`, and the low-cardinality set for 3f, in the shapes `Dedupe` takes.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `PlannerStatistics.run(store:, relations:, connection:)`, and `PlannerStatistics.load(store)` reads it back. It stores the `statistics` entry, and returns `Statistics` shapes with `TableStatistics#indexes` filled, plus `few_distinct` (fewer than 50 distinct values) for 3f and Dedupe. Invalid indexes are left out, and inheritance parents are refused. The leftovers went to 20260924-26.

### 20260922-22. 3f PII and low-cardinality classification.

Classify each column as PII or not, using a configured list and a high-cardinality text heuristic. Mark low-cardinality columns (fewer than 50 distinct values, not PII). Decide which derived scalars and MCV values may leave.

- **Depends on:** 20260922-19.
- **README:** 3f.
- **Status:** done
- **Decided:** The PII list is a set of `schema.table.column` globs, such as `*.users.email`, in the `quaacks` config file on the jump server. A text column is high-cardinality when it has 50 or more distinct values, the same line 3f uses for low-cardinality. The config can change the threshold.
- **Decided (user, September 24):** Low-cardinality also requires a positive pg_stats `n_distinct`, meaning the values repeat. So a small table's unique values, such as 40 emails in a 40-row table, never leave.
- **Landed:** Merged into `main` after a review, a fix round for the user's rule, and a second review. The entry point is `PiiClassification.run(store:, config:)`, and `.load` reads it back. It stores the `classification` entry with the `outbound_statistics` projection, and `Result#low_cardinality` feeds Dedupe. The config gains `pii_columns` globs and `cardinality_threshold`. `few_distinct` was removed from 3c. The leftovers went to 20260924-27.

### 20260922-21. 3e literal set.

Build the slow, worst-case, and typical literal sets and keep them in the governed store.

- **Depends on:** 20260922-14, 20260922-19.
- **README:** 3e.
- **Status:** done
- **Decided:** Pick values by operator.
  - **Ranges:** the worst case is the histogram bound that selects the most rows, and the typical value is the middle bound.
  - **`IN` lists:** each element follows the equality rule, and the list keeps its length.
  - **`LIKE` and any other operator:** use the slow literal in all three sets.
- **Decided (builder and main session, where the rules were silent):**
  - For BETWEEN, and for a lower and an upper range on the same column in the same AND, the typical value is the middle histogram bucket, and the worst case is the first and last bounds.
  - IN elements take distinct MCVs, and consecutive bounds for the typical set.
  - An `= ANY` array falls back as a whole.
  - Only plain `=` counts as equality.
  - `$n::type` cast placeholders keep the slow literal.
- **Landed:** Merged into `main` after a review, a fix round for the range-pair blocker, and a second review. The entry point is `LiteralSet.run(store:, sql:)`, and `.load` reads it back. It stores `literal_sets` (slow, worst_case, and typical placeholder maps, plus fallback reasons), and any set binds through `Redaction.binding`. The leftovers went to 20260924-28.

### 20260922-25. Run server checks.

Verify the run server: same major version and extensions as production plus HypoPG, same planner GUCs and locale settings, superuser access, no other clients, no background jobs, and autovacuum off. Abort and name the failed check.

- **Depends on:** 20260922-16.
- **README:** Step 4.
- **Note (from the review of 20260923-56):** The 5a-4 runner pins `plan_cache_mode` and `hypopg.enabled` itself, and refuses when HypoPG has hidden indexes. It relies on this step for everything else. The reviewer found these change plans without warning, so compare them with production too:
  - `enable_*`, the cost GUCs, `geqo`, the collapse limits, and `max_parallel_*`.
  - The developer GUC `debug_parallel_query`. It moved a baseline cost from 1887 to 2887.
  - `TimeZone`, `DateStyle`, and `IntervalStyle`, which change how a quoted literal is read.
  - Per-tablespace `random_page_cost`.
  - Also note that the required superuser bypasses row-level security. Plans for tables with RLS can differ from production. The step 5 plan gate catches that for the original query.
- **Status:** done
- **Decided:** Require that `pg_stat_activity` shows no other client backends. If pg_cron is installed, also require that no job in `cron.job` is active. Document that schedulers outside Postgres are the operator's responsibility.
- **Decided (builder, accepted by the main session):**
  - Production's value for a GUC is its own recorded value from step 2, not the plan session's value.
  - Step 2 also records TimeZone, DateStyle, IntervalStyle, and default_statistics_target, because they aren't EXPLAIN-flagged.
  - A GUC with no recorded value must be EXPLAIN-flagged and at its boot_val.
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `RunServerCheck.run(store:, connection:, own_connections:)`. It raises on the first failure, with a `run_server_*` rule and a message of the form `rule: name`. The leftovers went to 20260924-29.

### 20260922-26. 4a racetrack setup.

In the restored racetrack database, create `hypopg`, the `quaack` schema, and `clock_anchor()`.

- **Depends on:** 20260922-25, 20260922-24.
- **README:** 4a.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `Racetrack.setup(store:, connection:)`. `quaack.clock_anchor()` is plpgsql, STABLE, PARALLEL SAFE, and COST 1, which matches `now()` and isn't inlined, so plans and runtime pruning match production's `now()` on PG18. A foreign object in the `quaack` schema is refused, checked through pg_depend.

### 20260922-11. Inbound check for index DDL.

Accept exactly one `CREATE INDEX` statement on a table the query uses. Reject anything else, naming the rule it broke.

- **Depends on:** 20260922-1, 20260922-17.
- **README:** What goes into the enclave.
- **Status:** done
- **Decided:**
  - Reject `CONCURRENTLY`, `TABLESPACE`, and `UNIQUE`.
  - Don't reject any index method. The user sees real room for improvement in methods beyond btree.
  - The table name must be schema-qualified. Refuse an unqualified one. Don't resolve it through the search path.
  - Refuse volatile functions and operators in key expressions and the WHERE predicate, using the 3d rule. Leave STABLE to Postgres: HypoPG (5a-4) and the real CREATE INDEX (step 12) refuse it with exact type resolution. (The first plan was to require IMMUTABLE here, but the catalog lookup can't pick overloads, and `=`, `<`, `||`, and `date_trunc` each have STABLE versions, so almost every partial index would be refused.)
  - Also reject `NULLS NOT DISTINCT` and `ON ONLY`. Accept `WITH (...)` storage options and `IF NOT EXISTS`.
  - Drop any index name the DDL gives, so later steps name indexes themselves.
- **Open questions:** How should later steps treat index methods other than btree? 5a-3 sets GIN and GiST candidates aside today. (Not needed for this task.)
- **Landed:** Merged into `main` after a build, a first review, and a second review. Both reviews found nothing blocking, so there was no fix round. The builder stopped once to ask about the IMMUTABLE rule, and the user changed it to refuse volatile only.
  - `IndexDdlCheck.check(sql, tables, settings, connection)` runs these rules in order: `unparsable`, `not_create_index`, `concurrently`, `unique`, `nulls_not_distinct`, `tablespace`, `on_only`, `unqualified_table`, `unknown_relation`, `forbidden_in_index` (parameters, subqueries, and aggregate, window, or grouping calls), `unsupported_construct`, `volatile_function` or `bad_search_path`, and `deparse_mismatch`.
  - It returns `Accepted(sql:, parse:, table:)`. The SQL has the name, IF NOT EXISTS, and comments dropped. Errors carry a rule and shape-only names, with `cause: nil`.
  - It reuses `VolatilityCheck.check_parse` (new) and `IndexSql.forbidden` (split out of `check_predicate_node`).
  - The first review's minor finding (the attribute-notation and domain CHECK gaps reach index DDL) went to 20260923-35. The second review's two minor findings became 20260925-1.

### 20260922-12. Inbound check for step 10 inserts.

Accept only plain `INSERT` statements into tables in the 3b subset schema. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, and anything else that isn't a plain insert.

- **Depends on:** 20260922-1, 20260922-18.
- **README:** What goes into the enclave.
- **Note (from the review of 20260922-46):** The arena runner accepts any single InsertStmt, including `WITH ... INSERT`, `ON CONFLICT`, and `RETURNING`. This check is the real guard. It must refuse those forms, plus `set_config`, advisory locks, and any function that isn't immutable.
- **Status:** done
- **Decided:** A plain insert is `INSERT INTO <subset table> (<columns>) VALUES (...), ...`. The values can be constants, casts, `DEFAULT`, and calls to immutable functions that pass the 3d volatility check. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, `WITH`, `OVERRIDING`, and any function that isn't immutable.
- **Landed:** Merged into `main` after a build and a first review. The review found nothing blocking, so there was no fix round and no second review.
  - `InsertCheck.check(sql, tables, settings, connection)` runs these rules in order: `unparsable`, `not_insert`, `with`, `on_conflict`, `returning`, `overriding`, `missing_columns`, `insert_select`, `alias`, `unqualified_table`, `unknown_relation`, `unknown_column`, `not_plain_value`, `not_immutable` or `bad_search_path`, `volatile_function`, and `deparse_mismatch`. It returns `Accepted(sql:, parse:, table:)`.
  - Function calls must be IMMUTABLE. Casts are held only to the 3d no-volatile rule, because the date and timestamptz input functions are STABLE.
  - The review's four minor findings became 20260925-2.

### 20260922-28. 5 plan gate.

`EXPLAIN` the original query on the racetrack with the slow literals and compare canonical forms with the step 1 plan. On mismatch, abort and name stale racetrack statistics as the likely cause.

- **Depends on:** 20260922-26, 20260922-15, 20260922-21, 20260922-23.
- **README:** Step 5.
- **Status:** done
- **Note (from 20260922-26):** CanonicalPlan fingerprints include function names, so a racetrack qual like `created_at > quaack.clock_anchor()` won't match production's `created_at > now()`. Map the anchor back to the original functions (as `ClockAnchoring.restore` does), or normalize both sides, before comparing.
- **Landed:** Merged into `main` after a build and a first review. The review found nothing blocking, so there was no fix round and no second review.
  - `CanonicalPlan` now always swaps the clock functions 3h replaces for their anchored form before fingerprinting, and drops `pg_catalog` from casts of `quaack.clock_anchor()`.
  - `PlanGate.check(store:, connection:, sql:)` takes the redacted, anchored SQL, binds the stored placeholder map, EXPLAINs through `SingleCandidateTest.run`, and raises `plan_gate_bad_plan`, `plan_gate_not_comparable`, or `plan_gate_mismatch_likely_stale_statistics`. The cause is in the rule name, because only the rule leaves the enclave.
  - Parameter types are inferred by Postgres. The review found no realistic query where that changes the plan.
  - The review's two minor findings became 20260925-3.

### 20260925-7. Enclave subcommand: `quaacks run-server` (step 4).

Record the run server in the run store and run the step 4 checks against it. `quaacks run-server --run <run ID> --host <host> --port <port> --racetrack-db <name> --arena-db <name>`. Credentials come from the operator's libpq setup (the `PG` environment variables, `~/.pg_service.conf`, `~/.pgpass`), as they do for production. QUAACK stores none. Later racetrack and arena steps connect using what this step recorded. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260922-25, 20260922-16.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** Step 4.
- **Decided:** The user chose to give the run server at its own step and store it in the run, with the port recorded too.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks run-server` checks its arguments and refuses a run with no inventory. It runs `RunServerCheck` on the racetrack database only, because 4b makes arena. It records the `run_server` entry (host, port, racetrack_db, arena_db) only after every check passes. It prints only DONE.
  - `RunServer.connect(store, :racetrack | :arena)` opens later steps' connections. A libpq failure becomes `run_server_connection_failed` with no cause.
  - Refusals: `bad_run_server_host`, `bad_run_server_port`, `bad_run_server_database`, `run_server_same_database`, and `run_server_no_inventory`. IPv6 and Unix sockets are unsupported in v1.
  - The review's minor finding became 20260925-17.

### 20260925-8. Enclave subcommand: `quaacks qualify` (step 1 qualification and 3a relations).

Fully qualify the query against production and find its relations. Store the qualified query and the relation list. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260922-14, 20260922-17, 20260922-13.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** Step 1, 3a.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks qualify --run ID` reads `query`, `plan` and `server`, connects to production with libpq, and runs `Relations.check` (qualification through the plan's `search_path`, and the 3a relkind check). Only after every check passes does it store `qualified_query` (a String that still holds literals) and `relations` (an Array of `{schema, name}` in first-named order). It prints only DONE.
  - `CLI::Step` moved to `cli/step.rb`.
  - The review's minor findings became 20260925-18.

### 20260925-9. Enclave subcommand: `quaacks schema-dump` (3b).

Dump the schema and build the subset. Store the subset. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-18.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3b.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks schema-dump --run ID` reads `server` and `relations`, and runs `SchemaDump.run` inside `Inventory::Production.read_only`. pg_dump comes from PATH and gets only the host; libpq supplies the rest, the same way the connection gets it. It stores `schema_dump` (namespaces and the full DDL) and `schema_subset` (tables and DDL), and prints only DONE. The 5a-5 payload step will send the subset.
  - The review's minor findings became 20260925-19.

### 20260925-10. Enclave subcommand: `quaacks statistics` (3c).

Gather the planner statistics and existing indexes for the query's tables (README 3c). Store them for generators one and two and for Dedupe. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-19.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3c.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks statistics --run ID` reads `server` and `relations` and calls `PlannerStatistics.run`, which reads inside `read_only` and writes the `statistics` entry only after the transaction closes. It prints only DONE. `PlannerStatistics.load` rebuilds the objects.
  - It uses `relations`, not the subset tables. The review confirmed that no consumer needs statistics for FK parents: 4a's restore brings production's statistics with it.
  - The review's minor finding became 20260925-20.

### 20260925-11. Enclave subcommand: `quaacks volatility` (3d).

Run the volatility check on the qualified query. Store the result. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-20.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3d.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks volatility --run ID` reads `server`, `plan` and `qualified_query`, and runs `VolatilityCheck.check` inside `read_only` with the plan's `search_path`. After the transaction closes it stores the marker `volatility: {"passed" => true}`. It prints only DONE. Stable clock functions pass, for 3h to anchor.
  - The refusal names only its rule for now. The user wants the function named, so that became 20260925-21.

### 20260925-13. Enclave subcommand: `quaacks classify` (3f).

Classify PII and low-cardinality columns. Store the classification, and send `outbound_statistics` out as `column_stats`. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-10, 20260922-22.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3f.
- **Status:** done
- **Decided:** The user changed this: classify stores the stats and sends nothing. The 5a-5 payload step (20260925-4) sends `outbound_statistics`.
- **Landed:** Merged into `main` after a build, a first review, a fix round for the user's change, and a clean second review.
  - `quaacks classify --run ID` loads the config, runs `PiiClassification.run`, and stores `classification` (`{columns, outbound_statistics}`). It never touches production, prints only DONE, and stores nothing on failure.

### 20260925-14. Enclave subcommand: `quaacks redact` (3g).

Redact the query. Store the placeholder map and the redacted SQL (the redacted SQL isn't stored today). Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260925-13, 20260922-23.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3g.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks redact --run ID` reads `qualified_query` and `plan`, and runs `Redaction.redact`. It computes everything before the first write, then stores `placeholder_map`, `placeholder_shapes`, `redacted_query`, and `redacted_plan` (`{explain, masked, dropped}`). It prints only DONE and needs no production connection.
  - The review's minor findings became 20260925-22.

### 20260925-12. Enclave subcommand: `quaacks literals` (3e).

Build the literal set and store it. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260925-10, 20260925-14, 20260922-21.
- **Note (from the first build attempt):** `LiteralSet.run(store:, sql:)` reads 3g's `placeholder_map` and 3c's `statistics`, and checks the redacted SQL against the map. So this step runs after `quaacks redact`, not before it. It reads `placeholder_map`, the redacted SQL, and `statistics`, and refuses cleanly if any is missing. It writes the existing `literal_sets` entry and needs no production connection. It should also refuse unless the `volatility` marker exists.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3e.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks literals --run ID` refuses with `volatility_not_passed` unless `volatility` is `{"passed" => true}`. It then runs `LiteralSet.run(store:, sql: redacted_query)`, which reads `placeholder_map` and `statistics` and writes `literal_sets`. It prints only DONE and needs no production connection.
  - The review's minor finding went into 20260925-22.

### 20260925-15. Enclave subcommand: `quaacks anchor` (3h).

Anchor the clock in the redacted query. Store the anchored SQL. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-14, 20260922-24.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3h.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks anchor --run ID` runs `ClockAnchoring.anchor(redacted_query, plan settings)`, and stores `anchored_query` (the `sql:` for `PlanGate` and 5a-4) and `clock_replacements` (names only, for `restore`). It prints only DONE. The CLI `STEPS` table moved to `cli/steps.rb`.
  - The review's minor findings became 20260925-23.

### 20260925-16. Enclave subcommand: `quaacks racetrack-setup` (4a).

Set up the racetrack on the run server recorded by `run-server`, using the stored schema and statistics. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-7, 20260925-9, 20260925-10, 20260922-26.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 4a.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks racetrack-setup --run ID` refuses with `racetrack_setup_no_run_server` when there's no `run_server` entry. Otherwise it connects with `RunServer.connect(store, :racetrack)`, runs `Racetrack.setup` (hypopg and `quaack.clock_anchor()`), and writes `racetrack_setup: true` only on success. It prints only DONE.
  - The review's minor findings went into 20260925-22.

### 20260925-6. Enclave subcommand for the mechanical half of step 5.

Add `quaacks` subcommands that open the racetrack connection and run the mechanical half of step 5: the plan gate, 5a-1, 5a-2, 5a-3, and 5a-4. They save the mechanical proposals and Dedupe state, the 5a-4 results, and the redacted plan in the governed store, so the 5a-5 subcommands (20260925-4) can read them. The driver side of step 5 is wired in 20260922-36.

- **Depends on:** 20260922-26, 20260922-28, 20260922-29, 20260922-30, 20260922-31, 20260922-32, 20260925-7 through 20260925-16.
- **README:** Step 5, 5a.
- **Note:** `IndexCandidate` and `Dedupe` can't be saved to and read back from the store yet. This task must add that, because the 20260925-4 `index-test` loads the Dedupe state it saves. Key the saved entries per search (for example `index_search_original`, and later `index_search_rewrite_<n>`).
- **Decided:** The user chose to build this as its own prerequisite task, ahead of the 5a-5 subcommands and 20260922-36.
- **Status:** done
- **Landed:** Merged into `main` after a build, a first review with four blocking findings, a fix round, and a clean second review.
  - `quaacks index-search --run ID [--search original]` refuses without `racetrack_setup`, runs PlanGate on `anchored_query`, builds a Dedupe from the stored statistics and low-cardinality columns, filters generators one and two, and runs SingleCandidateTest on each survivor for each literal set (slow, worst_case, typical). It prints only DONE.
  - It stores `index_search_original` as `{dedupe, baseline, results}`. Each set gets `{used, total_cost, plan}`, where `plan` is the EXPLAIN redacted through 3g. Candidates can hold real literals, which is allowed inside the store (see the note on 20260925-4).
  - `IndexStore` round-trips IndexCandidate and Dedupe, through a new `Dedupe.restore`.
  - The minor findings became 20260925-24. 5a-7 ranking is left for 20260925-4 and 20260922-36.

### 20260925-4. 5a-5 generator three: the LLM loop.

The rest of 20260922-33. Build the shape-only payload, ask the LLM for up to five candidates it hasn't seen covered, filter them through 5a-3, ask once for replacements of dropped ones, tag partial indexes, and test survivors with 5a-4. It must work for the original query and for rewrites.

- **Depends on:** 20260922-33 piece one (landed), 20260925-6.
- **README:** 5a-5.
- **Decided:** Use two enclave subcommands. `quaacks index-payload [--candidate ID]` sends the shape-only payload out through egress, using a new whitelisted type. `quaacks index-test` reads the LLM's DDL on stdin and runs `IndexDdlCheck`, then `from_ddl` with `sources: [:llm]`, then Dedupe against the mechanical proposals saved in the store, then 5a-4. It saves the results in the store and returns a shape-only outcome for each candidate: accepted, or dropped with its rule. The driver runs the replacement round by calling `index-test` again.
- **Note (from the review of 20260925-6):** The stored `index_search_<search>` entries hold real literals. Generator two runs on the unredacted step 1 plan, so partial predicates and key expressions, in `dedupe` proposals, drops, `covered_by`, and `results[].candidate`, can embed real quals such as `status = 'held'`. `index-payload` must not send candidate DDL or predicates as they are. Redact them through 3g, or allow only the 5a-3 low-cardinality values plus an explicit egress check. Add a sentinel test with a partial candidate whose predicate holds a sentinel. `index-test` should save its results under the same per-search key.
- **Note (from 20260925-13):** `index-payload` must send `classification.outbound_statistics` as the payload's `stats`. By the user's decision, classify stores it and sends nothing.
- **Note:** The prompt must say plainly that an unqualified table name gets the candidate refused and counts against the LLM.
- **Note:** `IndexDdlCheck` accepts `WITH (...)` storage options, but `from_ddl` returns nil for them. Strip them or refuse them, so LLM DDL that uses them isn't silently lost. The "proportion" bullet of 20260923-17 can be decided in light of piece one.
- **Status:** done
- **Landed (piece two):** Merged into `main` after a build, a first review with two blocking leaks, a fix round, and a clean second review.
  - `quaacks index-payload` sends the new `index_payload` type: query, placeholders, the plan with `Settings` stripped (the user's decision), schema, mechanical_results, and stats. `CandidateDdlRedaction` masks every constant in candidate DDL as `?`, except an MCV value compared directly with its own low-cardinality column.
  - `quaacks index-test` reads `{"ddls": [...]}`, filters through the stored Dedupe and GeneratorThree, runs SingleCandidateTest for each set, appends `llm_results`, replaces `dedupe`, and sends `index_outcome` lines. The driver's `index_test` calls the transport.
  - Left out, and moved to 20260926-3: the 5a-5 burndown record. Rewrite searches come with step 8 and 11.


### 20260922-33. 5a-5 generator three.

Build the shape-only payload, ask the LLM for up to five candidates it hasn't seen covered, filter them through 5a-3, ask once for replacements of dropped ones, tag partial indexes, and test survivors with 5a-4. Must work for the original query and for rewrites.

- **Depends on:** 20260922-6, 20260922-5, 20260922-11, 20260922-22, 20260922-23, 20260922-29, 20260922-32, 20260923-11.
- **README:** 5a-5.
- **Status:** done
- **Note:** The `IndexCandidate` shape from 20260923-11 only holds plain column keys. 5a-5 asks the LLM for expression indexes and operator classes such as `text_pattern_ops` and trigram GIN. So this task has to extend the shape with expression keys, opclasses, and probably collations, and teach 5a-3's dedupe to handle them.
- **Note (from 20260922-11):** The inbound check refuses index DDL whose table name isn't schema-qualified. The LLM prompt must say so plainly: an unqualified table name gets the candidate refused and counts against the LLM, so it should always write the schema.
- **Progress:** Piece one landed on `main` after a build, a first review, a fix round and a clean second review. `IndexCandidate::KeyColumn` now holds expression keys (normalized through pg_query, redacted like predicates), opclasses and collations (with `pg_catalog` dropped). `from_ddl` and `to_ddl` round-trip them, and Dedupe matches key columns only when all of them agree, including when a btree is read backward. The LLM loop is left, and it's split out as 20260925-4. Close this task when 20260925-4 lands.
- **Landed:** Covered by piece one of this task and by 20260925-4.


### 20260925-5. Generator three piece one loose ends.

Minor findings from the first review of 20260925-4:
- **`covered_by` going out through egress is untested.** In `enclave/lib/quaack/enclave/generator_three.rb` `messages`, setting `covered_by: nil` stays green. Add a DDL covered by an existing index to the egress sentinel case in `generator_three_postgres_spec.rb`.
- **The replacement ask can ask for more than five.** `driver/lib/quaack/driver/generator_three.rb` `replacement_ask` asks for `dropped.size` replacements, including `too_many` drops. Cap it at five, and leave `too_many` drops out of the request.

- **Depends on:** 20260925-4 piece one (landed).
- **Came from:** The first review of 20260925-4.
- **README:** 5a-5.
- **Status:** done
- **Landed:** Both fixes were folded into piece two of 20260925-4.

### 20260922-54. 12b run discipline.

Run every measurement statement in a `READ ONLY` transaction with `statement_timeout`, one at a time.

- **Depends on:** 20260922-26.
- **README:** 12b.
- **Status:** done
- **Decided:** `statement_timeout` is 3× the original query's baseline time, clamped to at least 5 seconds and at most 5 minutes. We should always be willing to wait 5 seconds, and anything needing more than 5 minutes needs a human. A candidate whose measurement times out is dropped and counted in the report as timed out.

### 20260923-12. 5a-2 on rewrite plans.

20260922-31 builds generator two from the production plan only. The task also wanted it to run on rewrites, with the racetrack plan. A racetrack plain `EXPLAIN` has no actual rows and no rows removed, so most of the patterns can't fire there. Decide how the patterns work on estimates, then build it.

- **Depends on:** 20260922-31, 20260922-26.
- **Came from:** Splitting 20260922-31, at the user's request to build it early.
- **README:** 5a-2, step 8.
- **Status:** done
- **Decided:** On rewrite plans, run only the patterns that need neither actual rows nor rows removed, and skip the rest. The LLM in step 11 covers the gaps.

### 20260922-40. 8 structural discards.

Discard candidates that fail to plan on the racetrack, or whose output column count or types differ from the original. Count inbound-check rejections here too, for the report.

- **Depends on:** 20260922-10, 20260922-23, 20260922-26.
- **README:** Step 8.
- **Status:** done

### 20260922-41. 8 mechanical index search per candidate.

For each remaining candidate, run 5a-1, 5a-2, 5a-3, and 5a-4 on its own parse and racetrack plan. Save the 5a-4 results for step 11.

- **Depends on:** 20260922-40, 20260922-29, 20260922-30, 20260922-31, 20260922-32, 20260923-12.
- **README:** Step 8.
- **Status:** done

### 20260922-42. 8 three-configuration pruning.

`EXPLAIN` each candidate with no hypothetical indexes, with the original's top three, and with its own top three. Discard it only if its canonical plan matches the original's in all three.

- **Depends on:** 20260922-41, 20260922-35, 20260922-15.
- **README:** Step 8.
- **Status:** done
- **Decided:** Compare against the original's plan under the same index configuration.

## Step 9: Predicate-aware fixtures.

### 20260922-34. 5a-6 refinement round.

If any LLM candidate went unused or lost to a simpler mechanical candidate, send the LLM its own 5a-4 results and ask for one revision. Filter and test what comes back. Only one round.

- **Depends on:** 20260922-33.
- **README:** 5a-6.
- **Status:** done
- **Decided:** An LLM candidate qualifies for the revision round if the planner didn't use it, or if a mechanical candidate with fewer key and INCLUDE columns (ties broken by smaller estimated size) has a worst-case cost across the literal sets no higher than the LLM candidate's.

### 20260922-36. Step 5 orchestration.

Wire the plan gate and 5a-1 through 5a-7 together in the driver, in the order the README gives.
- **Decided (driver CLI):** `quaack start` (20260926-1) creates the run, and `quaack run --run ID` drives every remaining step in order. It can resume, skipping steps whose outputs are already in the store. Each orchestration task adds its stage to that sequence.

- **Depends on:** 20260922-28, 20260922-30, 20260922-31, 20260922-32, 20260922-33, 20260922-34, 20260922-35.
- **README:** 5a.
- **Status:** done
- **Note (from 20260922-22):** Feed `PiiClassification#low_cardinality` into Dedupe, and send `outbound_statistics` through egress. Update from 20260925-13: the 5a-5 `index-payload` step (20260925-4) sends it, and Dedupe's low-cardinality input comes from the stored `classification` entry.

## Steps 6 and 7: Rewrite candidates.

### 20260926-1. Driver finds the jump server with a configured command.

The driver has no way to know which jump server serves a production server. Add a driver config file on the laptop, `~/.quaack/driver.json`, with `jump_command`: a shell one-liner with `{server}` that prints the ssh host, following the pattern of `memory_command` (quoting, timeout, output checks). The operator starts a run from the laptop with something like `quaack start --server <prod> --query <path on jump server> --plan <path on jump server>`. The driver runs `jump_command`, then runs `quaacks intake` remotely over `Transport::Ssh` (the query and plan files stay on the jump server), and remembers run ID to jump host locally, so later commands take only the run ID. Update README "Where QUAACK runs" and step 1.

- **Depends on:** 20260922-5, 20260922-13.
- **README:** Where QUAACK runs, Step 1.
- **Decided:** The user chose a driver-side config command over a static map or a `--jump` flag.
- **Status:** done

### 20260926-2. Build and record the run server with a configured command.

Add `run_server_command` to the quaacks config on the jump server (`~/.quaack/config.json`). It's given `{server}` and `{run}`, builds or finds the run server from production, and prints JSON `{host, port, racetrack_db, arena_db}`. `quaacks run-server --run ID` with no flags calls it, validates the output the same way it validates the flags, and runs the step 4 checks. Flags still override. Add an optional matching `destroy_command` that `quaacks teardown` calls, so the run server is destroyed too, not just announced. Follow the `memory_command` pattern for quoting, timeouts, and discarding stderr. Nothing the command prints goes out except through the existing rules. Update README step 4 and teardown.

- **Depends on:** 20260925-7, 20260922-66.
- **README:** 4, Run teardown.
- **Decided:** The user chose a provision command in the quaacks config over having the operator build the server by hand.
- **Status:** done

### 20260924-30. Include extensions in the 3b schema dump.

pg_dump with `--schema` emits no CREATE EXTENSION. So the full dump that 4b loads into arena fails on columns like `public.citext`. Found while building 20260922-27. The user picked this fix on September 24.
- For each extension in production's `pg_extension` other than plpgsql, pass a quoted `--extension=<name>` to the full dump. pg_dump then emits `CREATE EXTENSION IF NOT EXISTS ... WITH SCHEMA ...`.
- Add each extension's schema to the full dump's namespaces, so `WITH SCHEMA ext` doesn't fail on a schema that doesn't exist.
- Test with real pg_dump 18 output: citext in public, and pgcrypto in a separate schema `ext`. Load the dump into a fresh template0 database, and check that it succeeds.
- Known and accepted: CREATE EXTENSION carries no VERSION, so arena gets the run server's default versions.

- **Depends on:** 20260922-18.
- **Came from:** The build of 20260922-27.
- **README:** 3b.
- **Status:** done

### 20260922-37. 6a rewrite generation.

Ask the LLM for rewrites of the redacted query, each stating its transformation and every assumption it relies on. Send candidates through the inbound check.

- **Depends on:** 20260922-6, 20260922-5, 20260922-10, 20260922-18, 20260922-23.
- **README:** 6a.
- **Status:** done
- **Decided (wiring):** `quaacks rewrite-payload` sends the redacted query, plan, schema, and stats, reusing the `index_payload` fields where it can. `quaacks rewrite-check` reads the LLM's rewrites on stdin (SQL, transformation, and structured assumptions). It runs the inbound check, 6b, and step 8's structural discards on the racetrack, stores survivors under `rewrite_<n>`, and returns shape-only outcomes.
- **Decided:** Ask for up to five rewrites per run. Assumptions use a structured format, and the vocabulary is exactly: a `NOT NULL` column, a unique column set, a foreign key, and a `CHECK` constraint. A candidate stating any other kind of assumption is rejected.

### 20260922-38. 6b assumption check.

Check each stated assumption against `pg_constraint` and `pg_index`, treating `NOT VALID` constraints as absent. Reject candidates with unmet assumptions.

- **Depends on:** 20260922-37.
- **README:** 6b.
- **Status:** done
- **Decided:** The vocabulary is fixed by 20260922-37, so an assumption outside it rejects the candidate. A `CHECK` assumption is met only by a validated `CHECK` constraint on that table whose expression, normalized through pg_query, is identical to the stated one. Implied constraints don't count in v1.

### 20260922-39. 7 operator candidates.

Let operators submit placeholder-based rewrites through the driver. Ask the LLM to infer their transformation and assumptions, marked as inferred. Unmet inferred assumptions only add a report warning.

- **Depends on:** 20260922-37, 20260922-38.
- **README:** Step 7.
- **Status:** done
- **Decided:** A file flag on the laptop, `--rewrites <file>`, with one placeholder-SQL rewrite per `;`-terminated statement. They go through the same `quaacks rewrite-check` as 6a's rewrites, flagged as inferred.

## Step 8: Plan-based pruning.

### 20260924-27. 3f classification loose ends.

Findings from the build and reviews of 20260922-22:
- **text[], json, and jsonb columns aren't text-like for the heuristic,** so their MCV frequencies leave unless a glob names them. Their values never leave. The reviewer judged this low risk: a frequency vector over a large domain doesn't re-identify anyone. Decide whether they should fail closed as PII anyway.
- **Expression-index and extended-statistics MCVs are left out of the projection entirely.** If 5a-5 needs them, they'll need rules of their own.

- **Decided:** Leave text[], json and jsonb as they are: their frequencies may leave, and their values never do. Add rules that send expression-index and extended-statistics MCVs, classified under the rules of their base columns. An expression that touches any PII column is treated as PII.
- **Depends on:** 20260922-22.
- **Came from:** The build and reviews of 20260922-22.
- **README:** 3f.
- **Status:** done

### 20260922-44. 9 value pools.

Build each atom's pool: a satisfying value, a failing value, boundary values, pattern and case variants, `NULL` for nullable columns, and type boundary values.

- **Depends on:** 20260922-43, 20260922-21, 20260922-19.
- **README:** Step 9.
- **Status:** done

### 20260922-45. 9 scenario builder.

Build scenarios S0 through S6 from the pools, with hit rows, one near-miss row per atom, and join partners created or withheld. Every row satisfies every `VALID` constraint.

- **Depends on:** 20260922-44, 20260922-18.
- **README:** Step 9.
- **Note (from 20260924-5):** 9d reverses each run of consecutive same-table rows. So every table's rows must be contiguous in the fixture, or the reverse load does nothing. Tables with self-referencing FKs fail the reverse load (see 20260924-9).
- **Status:** done
- **Open questions:** This is likely the largest task in the backlog, so we'll probably split it when we pick it up. How do we satisfy `CHECK` constraints and required columns the query never mentions?
- **Decided:** Use the column's DEFAULT if it has one, or else a type-typical value (0, empty string, epoch). For a simple CHECK (column op constant, an IN list, or BETWEEN), pick a value that satisfies it. Refuse a query whose CHECKs are too complex, and list that as unsupported in v1.

### 20260922-48. 9c vacuity guard.

On S1, run the original with and without each atom replaced by `TRUE`. Retry vacuous atoms up to three times with other pool values. Mark any that stay vacuous as untested, by redacted shape.

- **Depends on:** 20260922-43, 20260922-45, 20260922-46, 20260922-47.
- **README:** 9c.
- **Status:** done

### 20260922-49. Step 9 orchestration.

Run every scenario through 9a to 9e for each candidate, and report pass or fail with the disproving scenario.

- **Depends on:** 20260922-45, 20260922-46, 20260922-47, 20260922-48.
- **README:** Step 9.
- **Status:** done

## Step 10: Adversarial fixtures.

### 20260922-50. 10a counterexample generation.

Ask the LLM for constraint-satisfying inserts that make a candidate and the original return different results, aimed at any untested atoms. Send them through the inbound check. Fill FK gaps by adding parent rows.

- **Depends on:** 20260922-6, 20260922-5, 20260922-12, 20260922-48.
- **README:** 10a.
- **Status:** done
- **Decided:** The enclave writes FK parent rows mechanically, using the step 9 fixture rules. The LLM writes shape-level inserts with placeholders, and the enclave binds the real literals.

### 20260922-51. 10b and 10c compare and roll back.

Load the inserts, run the 9d comparator, recheck untested atoms with the 9c test, and roll back. Up to three rounds per candidate.

- **Depends on:** 20260922-50, 20260922-47, 20260922-48.
- **README:** 10b and 10c.
- **Status:** done
- **Decided:** All three rounds always run.

## Step 11: Per-candidate index ranking.

### 20260926-7. Wire `quaack run` into the driver CLI.

Add `quaack run --run ID [--rewrites <file>]` to `driver/lib/quaack/driver/cli.rb`. It looks up the jump host with `Runs#host` (20260926-1), builds `Transport::Ssh` and the LLM client, and calls `Pipeline#run` (20260922-36). If `--rewrites` is given, it sends the file through `OperatorCandidates.from_file` (20260922-39).

- **Depends on:** 20260926-1, 20260922-36, 20260922-39.
- **Came from:** Track A, B, and F build reports.
- **README:** Where QUAACK runs, and step 7.
- **Status:** done

### 20260926-11. Structural discard: compare typmods.

The output-type check compares only type OIDs, so a `varchar(10)` column and a `varchar(20)` column count as the same. Decide whether a difference in typmod should count as an output mismatch.
- **Decided:** No. Compare OIDs only, so the task is dropped.

- **Depends on:** 20260922-40.
- **Came from:** Track C build report.
- **README:** Step 8.
- **Status:** dropped

### 20260926-6. Step 8 wiring.

The step 8 library pieces have landed: `StructuralDiscard`, `Steps::IndexSearch.rewrite_entry` and `ThreeConfigurationPruning` (20260922-40, -41, -42), along with `rewrite-check` (20260922-37). Wire them together:
- `quaacks index-search --search rewrite_<n>`.
- A per-candidate loop: search, rank the rewrite's top three with `IndexRanking`, then prune against `index_ranking_original`.
- Record the step 8 burndown, including the count of inbound-check rejections (`StructuralDiscard.record`).
- A driver stage in `Pipeline::STAGES`.

- **Depends on:** 20260922-37, -40, -41, -42, -36.
- **Came from:** Track C and track B build reports.
- **README:** Step 8.
- **Status:** done

### 20260922-27. 4b arena setup.

Create arena from `template0` with matching locale settings, load the full schema and extensions, create `clock_anchor()`, keep `VALID` constraints, and disable user triggers only.

- **Depends on:** 20260922-25, 20260922-18, 20260922-24, 20260924-30.
- **README:** 4b.
- **Status:** done
- **Note (from the first build attempt):** Waiting on 20260924-30. The plan once it lands: load the dump through the connection with the `\restrict` and `\unrestrict` lines removed, as one implicit transaction. Drop the empty `public` schema before loading, since the dump runs `CREATE SCHEMA public`. Map the locale provider (`c` to libc, `i` to ICU_LOCALE, `b` to BUILTIN_LOCALE). Name the database from the run ID, with a COMMENT tag, and on a rerun drop and rebuild a tagged database. Reuse Racetrack's anchor code. Run DISABLE TRIGGER USER on every table. Don't create hypopg. The inventory doesn't record the database encoding, so arena gets the run server's default.
- **Note (from 20260925-7):** The user chose to take the arena database name at `quaacks run-server --arena-db`. Use the recorded name and connect with `RunServer.connect(store, :arena)`, rather than naming the database from the run ID. The COMMENT tag and drop-and-rebuild on a rerun still apply.
- **Note (from 20260922-26):** Reuse `Racetrack.create_clock_anchor` and `anchor_literal` for arena, perhaps through a shared module.

## Step 5: Plan gate and index candidates.

### 20260926-10. Arena database: handle the dump's `CREATE SCHEMA public`.

When the full dump is loaded into a fresh database, its `CREATE SCHEMA public` clashes with that database's own `public` schema. The 20260924-30 test gets around this by dropping `public` first. Step 4b's arena creation has to handle it the same way. Check whether it already does.

- **Depends on:** 20260924-30.
- **Came from:** Track F build report.
- **README:** Step 4b.
- **Status:** done

### 20260926-12. Assumption check loose ends.

These are minor findings from the review of 20260922-38:
- A `check` assumption is compared as-is with `pg_get_constraintdef`, so casts that Postgres adds (`(0)::numeric`) break the match. Normalize the casts.
- A `NO INHERIT` suffix doesn't parse.
- A `unique` assumption is met by a unique index on nullable columns (NULLS DISTINCT), which can wrongly pass. Also require NOT NULL or `indnullsnotdistinct`.
- Deferrable unique indexes count as met.
- `rewrite-check` plans the SQL before it checks the assumptions. The spec's name and the README 6b order should say so.

- **Depends on:** 20260922-38.
- **Came from:** Track B review.
- **README:** 6b.
- **Status:** done

### 20260926-5. Run discipline: tell timeouts apart from cancels, and allow one statement only.

Both of these are minor findings from the 20260922-54 review. First, `rescue PG::QueryCanceled` counts every cancel as a timeout, so an operator's `pg_cancel_backend` is also recorded as timed out. Check that the error really is a statement timeout. Second, `connection.exec` accepts several statements in one string, so a `COMMIT` in the SQL could end the READ ONLY transaction. Refuse SQL that holds more than one statement, or run it with `exec_params`.

- **Depends on:** 20260922-54.
- **Came from:** 20260922-54 review, minor findings.
- **README:** Step 12b.
- **Status:** done

### 20260922-52. 11 LLM index search per candidate.

For each candidate that survived steps 9 and 10, run 5a-5, 5a-3, 5a-4, 5a-6, and 5a-7 using the step 8 results, with the candidate's plan redacted through 3g.

- **Depends on:** 20260922-33, 20260922-34, 20260922-35, 20260922-41, 20260922-51.
- **README:** Step 11.
- **Status:** done

## Steps 12 through 14: Measurement.

### 20260926-18. Parallel spec runs remove each other's Postgres containers.

A full rake run died with 1216 enclave failures and "docker rm … removal already in progress". The stale-container cleanup in `spec/support/test_postgres.rb` removes every container labelled `quaack.test-postgres`, including ones that another spec process started a moment ago. Only remove containers whose owner process is gone, for example by labelling each container with its PID and checking whether that process is alive.

- **Depends on:** none.
- **Came from:** Build of 20260926-12 and -5, with several worktrees running rake at once.
- **README:** none (see CLAUDE.md, Development).
- **Status:** done

### 20260926-9. Driver start and run server loose ends.

These are minor findings from the review of 20260926-1, 20260926-2 and 20260924-30:
- `Runs#record` has a run-ID guard that no test covers.
- The README should show flags in the space-separated form.
- The docs should say `destroy_command` must be idempotent.
- The child process for `jump_command` isn't in its own process group, so a timeout doesn't kill what the shell started.
- Some spec wrote an empty run-ID file into `enclave/`. Find it and make it write to a temp dir.

- **Depends on:** 20260926-1, 20260926-2.
- **Came from:** Track F review.
- **README:** Where QUAACK runs, step 4, and teardown.
- **Status:** done

### 20260926-13. Expression MCV classification: tests for the paths that aren't covered.

These are minor findings from the review of 20260924-27. The code handles each case, but no spec covers it:
- A partial index whose only PII column appears in its WHERE clause.
- A definition that won't parse.
- A definition that names a column the table doesn't have.

- **Depends on:** 20260924-27.
- **Came from:** 20260924-27 review.
- **README:** 3f.
- **Status:** done

### 20260926-16. `quaack run` loose ends.

These are minor findings from the review of 20260926-7:
- No spec covers a failing enclave or LLM call (exit 1 and `quaack run failed: <rule>`). Changing the exit code to 0, or narrowing the rescue list, stays green.
- No spec covers a rewrites file that won't parse.
- A reply to rewrite-payload with no `rewrite_payload` message passes nil on and crashes with a stack trace.
- Step 7 runs after the whole pipeline, not next to 6a.
- Nothing prints on success.

- **Depends on:** 20260926-7.
- **Came from:** 20260926-7 build report and review.
- **README:** Step 7.
- **Status:** done

### 20260926-14. Wire steps 9 and 10 into the CLI and the pipeline.

`StepNine.run`, `Enclave::Counterexamples` and `Driver::Counterexamples` (20260922-44 to -51) have landed, but nothing calls them yet. They need:
- `quaacks` subcommands for step 9 and for 10b/10c. These read the stored rewrites and candidates, and send only shape-level outcomes.
- A driver stage in `Pipeline::STAGES` after step 8.

- **Depends on:** 20260922-49, -51, 20260926-6.
- **Came from:** Track D build report.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260926-19. Assumption and run discipline loose ends, part two.

These are minor findings from the build and review of 20260926-12 and -5:
- A stated `CHECK (col IN (...))` never matches, because Postgres stores it as `col = ANY (ARRAY[...])`. Normalize IN lists to that form.
- Telling a timeout from a cancel relies on Postgres's English message text, since both use SQLSTATE 57014. A non-English `lc_messages` breaks it. Set `lc_messages` for the session, or find another signal.

- **Depends on:** 20260926-12, 20260926-5.
- **Came from:** Their build report and review.
- **README:** 6b, 12b.
- **Status:** done

### 20260926-17. Arena setup loose ends.

These are minor findings from the build and review of 20260922-27:
- Check with real `pg_dump` 18 output from an ordinary database that the dump runs `CREATE SCHEMA public`, since arena setup drops `public` first. If a dump doesn't, every load fails.
- Every dump-load error comes out as one rule.
- The ICU and libc locale mapping is untested.
- Nothing in the driver pipeline runs `arena-setup`, and the arena steps don't check for its marker.

- **Depends on:** 20260922-27.
- **Came from:** 20260922-27 build report and review.
- **README:** 4b.
- **Status:** done

### 20260922-53. 12a build and hide indexes.

Build every distinct index from 5a and step 11 with raised maintenance settings. Record built sizes. Hide them with `indisvalid`, touching only proposed non-unique indexes, and confirm with `EXPLAIN` that the right set is hidden.

- **Depends on:** 20260922-35, 20260922-52.
- **README:** 12a.
- **Status:** done
- **Decided:** Each measurement unhides only its own combination. Build and measure the GIN and GiST candidates set aside in 5a-3 too.

### 20260926-8. Step 5 orchestration loose ends.

These are minor findings from the review of 20260922-34 and -36:
- If the LLM's 5a-6 answer is empty, `refined` is never set, so every resume asks the LLM again (`refinement_round.rb:57`). Call `index-test --round refinement` with an empty list.
- After a partial crash, a resume can leave the ranking stale.
- `index-payload` runs on every resume.
- Same for 6a: an empty rewrite reply never writes `rewrites_generated`, so every resume asks the LLM again (`rewrite_generation.rb:90`, from the review of 20260926-6).
- `IndexRanking` entries don't carry the canonical plans that README 5a-7 says they should.

- **Depends on:** 20260922-36.
- **Came from:** 20260922-34 and -36 build report and review.
- **README:** 5a-6, 5a-7.
- **Status:** done

### 20260926-22. Steps 9 and 10 wiring loose ends.

- A rewrite whose inserts failed to load in every round is still marked survived, with no fixture ever compared. The report should flag it (from the 20260926-14 review).
- A resume restarts step 10 at round 1, which repeats LLM calls.
- The driver doesn't check that a reply holds the message it expects (`rewrite_test`, `counterexample_payload`), so a missing one crashes.
- The payload's untested-atom test seeds the store directly rather than getting the atoms from a real step 9 run.

- **Depends on:** 20260926-14.
- **Came from:** 20260926-14 build and reviews.
- **README:** Steps 9 and 10, 15.
- **Status:** done

### 20260926-15. Scenario builder and counterexample loose ends.

These are minor findings from the build and reviews of 20260922-44 to -51:
- A statement timeout while loading an LLM's inserts becomes `:statement_timeout`, which isn't in `LOAD_RULES`, so it wrongly disproves the candidate (`arena_runner.rb:214`). Check the step, not the rule.
- `Counterexamples.covered` skips atoms it can't replace, and no test covers that.
- Only equality joins between plain columns tie keys together.
- A join near miss is skipped when a foreign key touches either column.
- Groups that collide on a unique key are dropped without saying so.
- Self-joins merge aliases into one row.
- Domain CHECK constraints are ignored.
- Bound literals are uncast (bit strings).
- 3e literal sets and 3c statistics aren't used for pools.
- The rule that an atom, once exercised, stays exercised across rebuilds has no test.

- **Depends on:** 20260922-51.
- **Came from:** Track D build report and reviews.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260922-55. 13 baseline runs.

Run the original three times per literal set with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Record total blocks and the hit-versus-read split. Mark a literal unstable if the count moves, and record each run's plan.
- **Decided:** For an unstable literal, 14a and 14b use the maximum of the three runs, for the original and for the candidates alike. The report flags that literal.

- **Depends on:** 20260922-53, 20260922-54.
- **README:** Step 13.
- **Status:** done

### 20260926-26. Scenario and counterexample loose ends, part two.

- `counterexamples/parent_rows.rb` calls `Values#typical` in strict mode, so a parent row whose domain column fails the typical value is refused with `unsupported_type` (this fails safe). Pass `strict: false`, and add a test.
- The `dropped` group count isn't carried through to the driver's report.
- A timeout during the fixture load step (as opposed to the insert step) has no direct test.
- The typed-binding item from 20260926-15 was judged stale (untyped binding works for bit strings) but wasn't independently checked.

- **Depends on:** 20260926-15.
- **Came from:** 20260926-15 build and review.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260926-24. Assumption and timeout loose ends, part three.

- Postgres may store a one-element IN list as plain `=`, so a stated `x IN ('a')` wouldn't match (this fails safe). Check it, and leave one-element lists as `=` when normalizing.
- The timeout heuristic counts an operator cancel that lands in the few milliseconds after `timeout_ms` as a timeout. That's harmless.

- **Depends on:** 20260926-19.
- **Came from:** Review of 20260926-19.
- **README:** 6b, 12b.
- **Status:** done

### 20260922-56. 13a index baselines.

Repeat the baseline runs for each index combination kept in 5a.

- **Depends on:** 20260922-55.
- **README:** 13a.
- **Status:** done

### 20260922-57. 14 candidate runs.

Run each candidate with its index combinations, using the step 13 process.

- **Depends on:** 20260922-55.
- **README:** Step 14.
- **Status:** done

### 20260926-4. Wire run discipline into steps 13 and 14.

`RunDiscipline` (20260922-54) exists, but nothing calls it yet. Steps 13 and 14 have to run every timed statement through it, drop any candidate whose statement timed out, and give the report a count of timed-out candidates.

- **Depends on:** 20260922-54, and the step 13 and 14 tasks.
- **Came from:** 20260922-54 build report.
- **README:** Step 12b.
- **Status:** done

### 20260926-20. Step 11 loose ends.

- A rewrite's index payload reuses the original's placeholder row counts, because a rewrite has no EXPLAIN ANALYZE of its own.
- The driver specs for `RewriteIndexStage` weren't mutation-tested.

- **Depends on:** 20260922-52.
- **Came from:** 20260922-52 build report and review.
- **README:** Step 11.
- **Status:** done

### 20260926-21. Harness and driver loose ends, part three.

- Test containers: no test covers the "same host label, dead PID, so remove it" path separately from the path for containers with no label (20260926-18 review).
- The driver's SIGKILL timing test (`Transport limits kills a run that ignores SIGTERM with SIGKILL`) flakes under heavy parallel load.
- An earlier run hit 1216 enclave failures from containers being removed mid-run, even though main already had the PID-scoped cleanup. The cause is unknown, so watch for it.
- Step 7 (`--rewrites`) runs after the whole pipeline, not next to 6a (from 20260926-16).

- **Depends on:** 20260926-18, 20260926-16.
- **Came from:** Builds and reviews of 20260926-18 and -16.
- **README:** Step 7; CLAUDE.md Development.
- **Status:** done

### 20260926-25. Pipeline loose ends, part four.

- A resumed run restarts step 10 at round 1. Continuing mid-way would need the earlier rounds' LLM conversation.
- The sentinel check in `index_rank_step_postgres_spec.rb` doesn't bite by itself. Plant a sentinel literal in the fixture's literal sets.

- **Depends on:** 20260926-8, 20260926-22.
- **Came from:** Their build and review.
- **README:** 5a-7, step 10.
- **Status:** done

### 20260922-59. 14c production result comparison.

Run the original and each candidate as plain queries per literal and compare in the enclave with the 9d rules. Stream and use an order-independent hash with float rounding when results are large. Mark `LIMIT` without `ORDER BY` as partial if it times out. Report any divergence prominently.

- **Depends on:** 20260922-47, 20260922-57.
- **README:** 14c.
- **Note (from the reviews of 20260922-47):** 9d runs the ordered comparison twice, once with an ascending tiebreaker and once with a descending one. It refuses WITH TIES, and it refuses originals whose own result depends on how ties break. README 14c says to "add the same tiebreaker here before hashing", so hashing needs the same treatment.
- **Status:** done
- **Decided:** Hash each row, sort the hashes, and hash the sorted list together with the row count.

### 20260926-23. Index build loose ends.

These are minor findings from the build and review of 20260922-53:
- The hiding guard in `IndexBuild.set_valid` is untested: removing the `quaack_` name filter or the unique/primary/exclusion filter keeps every test green. Add a test that tries to hide a primary key and a user unique index named `quaack_x`, and asserts both stay valid.
- `set_valid` and `valid_names` match on `relname`, not schema.
- Unqualified DDL makes the lookup of existing indexes miss on rerun.
- `status` has no `index_build` entry, so a resume can't skip the step, and the pipeline doesn't run it yet.
- The maintenance settings (1GB, 4 workers) are hard-coded.

- **Depends on:** 20260922-53.
- **Came from:** 20260922-53 build and review.
- **README:** 12a.
- **Status:** done

### 20260922-58. 14a and 14b metric and minimax rule.

Compare on total blocks only, with a 5% threshold. A candidate must beat the original on the slow literal and be no worse on the rest. Break ties by smallest index footprint.

- **Depends on:** 20260922-56, 20260922-57.
- **README:** 14a and 14b.
- **Status:** done
- **Note (from the review of 20260922-26):** The plpgsql `quaack.clock_anchor()` adds about 0.2 µs per row in a per-row filter, compared with `now()`: 70 ms against 27 ms on 187k rows. Plans don't change, but anchored runtimes carry that fixed extra cost, which shrinks a candidate's apparent speedup. Lean on blocks rather than time alone, or account for the cost.
- **Decided (original timeouts):** Baseline gives the original up to 15 minutes per run, not the 3x clamp. If the original still times out on a literal set, that set's count counts as infinite, so any candidate that finishes beats the original there. The report flags that set. The timeout for candidates stays 3x the original, clamped.
- **Decided:** "No worse" means an increase within the 5% threshold.
- **Decided:** Two candidates tie when their total blocks on the slow literal are within 5% of each other. Discard the one with the larger index footprint.
- **Decided:** For an unstable literal, use the maximum of the three runs.

### 20260926-28. Operator rewrites skip steps 8 to 11.

`quaack run --rewrites` runs step 7 after the whole pipeline, so the operator's rewrites never go through step 8 (index search and pruning), steps 9 and 10 (equivalence testing), or step 11. Run step 7 next to 6a, inside or right after `RewriteStage`, before step 8. Add an enclave status marker so a resume doesn't run step 7 again.

- **Depends on:** 20260926-7, 20260926-14.
- **Came from:** Build of 20260926-21.
- **README:** Step 7.
- **Status:** done

### 20260922-60. 14d selection.

Keep the top three candidates by total blocks.
- **Decided:** Rank the candidates that survive minimax by total blocks on the slow literal. Break ties by the sum across all literals.

- **Depends on:** 20260922-58, 20260922-59.
- **README:** 14d.
- **Status:** done

## Step 15: Report.

### 20260926-27. Baseline loose ends.

- If the original times out on a literal set during baseline, that set is only listed in `timed_out`. Decide how 14a and 14b treat that set, and how the report shows it.
- No real-Postgres test produces an unstable literal. Only the `summarize` unit test covers that path.
- Nothing in the pipeline calls `quaacks baseline` yet (see -65).

- **Depends on:** 20260922-55.
- **Came from:** 20260922-55 build and reviews.
- **README:** Step 13.
- **Status:** done

### 20260926-30. Result comparison loose ends.

- No test pins `BEGIN READ ONLY` in `ProductionComparison`. Changing it to plain `BEGIN` passes every spec, so a data-modifying CTE could write to the racetrack before the rollback. Add a spec where a write fails as read-only.
- The row count inside the digest duplicates the separate count comparisons. That's harmless, but untested.
- A candidate that times out during 14c is discarded (`fail`, `timed_out`). The task only defined partial for the LIMIT case, so this was the builder's choice.
- Two floats within tolerance, on either side of a rounding boundary, compare as a mismatch. This fails safe.
- `partial_count` is only tested at 0.

- **Depends on:** 20260922-59.
- **Came from:** 20260922-59 build and review.
- **README:** 14c.
- **Status:** done

### 20260926-31. Minimax and operator rewrite loose ends.

- No test covers an empty `--rewrites` file (`rewrites: []`): removing the `rewrites.empty?` check stays green. Add a spec asserting no rewrite-check call and no LLM call (from the 20260926-28 review).
- The timed-out guard in `Minimax.decide` wasn't separately mutation-tested.
- No end-to-end Postgres test sends a real racetrack run through `quaacks minimax`. The step test uses a hand-built store.

- **Depends on:** 20260922-58, 20260926-28.
- **Came from:** Their builds and reviews.
- **README:** 14b, step 7.
- **Status:** done

### 20260922-62. 15 main report.

Rank candidates per literal and overall with the minimax rule. List untested atoms and whether step 10 covered them. For each index, give built size, prefix coverage, and redundancy. Explain why the winner touches fewer blocks using only plans and selectivities. Show the query with the 3h functions put back.

- **Depends on:** 20260922-60, 20260922-24.
- **README:** Step 15.
- **Status:** done
- **Decided:** The report is written to a file on the laptop, `./quaack-<run>.html` or `--out <path>`, and its path is printed.
- **Note:** Scenario groups dropped on a unique-key collision are counted in `StepNine::Report#dropped` (20260926-15), but the count isn't sent to the driver yet. Add it here if the report shows it.
- **Decided:** HTML output. The explanation is templated from the measurements, not LLM-written.

### 20260925-17. Possible flake in the run-server success test.

`enclave/spec/run_server_postgres_spec.rb:65` needs no other clients on the shared test server. It closes the harness's admin connection, but if another spec in the same process leaves a connection open, the test fails with `run_server_other_clients`. It hasn't happened yet. If it shows up, give that test its own server or close every harness connection first.

- **Depends on:** 20260925-7.
- **Came from:** The first review of 20260925-7.
- **README:** 4.
- **Status:** done

### 20260925-20. Statistics step: test the read failure.

The `statistics` step spec has no `production_read_failed` case, but README 3c promises that the refusal stores nothing. Add a step-level test that pins it end to end.

- **Depends on:** 20260925-10.
- **Came from:** The first review of 20260925-10.
- **README:** 3c.
- **Status:** done

### 20260925-22. Name the missing input when a step's store entry is absent.

The new step subcommands (redact, classify, and others) report a missing upstream entry as `internal_error`. The README says a failure names only its rule, and the rule should name what's missing, such as `missing_plan` or a shared `missing_entry` naming the entry. Fix this in one place, for all the steps. The racetrack-setup success test should also check that `hypopg` exists, and a run with `run_server` but no `clock_anchor` should fail with a clean rule. Also add a test for `quaacks literals` refusing a `volatility` entry that's present but not passed (`literals.rb:27`), which no test covers yet. Also note, or fix, that `redact` writes its entries one at a time, so a crash partway through can leave some of them stored. A rerun overwrites them.

- **Depends on:** 20260925-14.
- **Came from:** The first reviews of 20260925-14, 20260925-12, and 20260925-16.
- **README:** Step 3.
- **Status:** done

### 20260925-21. Name the function in a 3d refusal.

README 3d says to abort and say which function caused it. Today the `volatile_function` error line carries only the step, the rule and the SQLSTATE, and 20260925-11 added a README paragraph calling that a v1 limitation. The user decided the function should be named. Function names are schema, so they're shape. Add a whitelisted field, such as `function` holding the schema-qualified name, to the `volatile_function` refusal, for both the step and the other `VolatilityCheck` callers where it makes sense. Remove the README limitation paragraph so 3d no longer contradicts itself. Prove with a sentinel that only the name goes out, never an argument or literal.

- **Depends on:** 20260925-11.
- **Came from:** The first review of 20260925-11, and the user's decision.
- **README:** 3d, What leaves the enclave.
- **Status:** done

### 20260926-33. Wire steps 4b and 12 to 14 into the pipeline.

The enclave steps exist, but `Pipeline` doesn't run them: `arena-setup` (4b), `index-build` (12a), `baseline` (13), `index-baseline` (13a), `candidate-runs` (14), `minimax` (14a/b), `result-comparison` (14c) and `selection` (14d). Until it does, a real `quaack run` never writes the report. Add resumable stages in README order, with status entries for each step's store output, and put `arena-setup` before steps 9 and 10.

- **Depends on:** 20260922-27, -53, -55, -56, -57, -58, -59, -60, -62.
- **Came from:** 20260922-62 build report.
- **README:** Steps 4b and 12-14.
- **Status:** done

### 20260922-63. 15a negative result.

When nothing beats the original, explain which rewrites were disproved and by which scenario, which indexes the planner declined, and which proposed indexes already existed.

- **Depends on:** 20260922-62.
- **README:** 15a.
- **Status:** done

### 20260922-64. 15b burndown tables.

Render the three burndown sections from the recorded counts.

- **Depends on:** 20260922-61, 20260922-62.
- **README:** 15b.
- **Status:** done

## End to end.

### 20260924-31. Keyset pagination with row comparisons.

**Decided:** Yes, support keyset pagination with row comparisons in v1. (The original question was whether this should be part of the v1 profile.) `WHERE (created_at, id) > ($1, $2)` is refused today as `unsupported_construct: RowExpr`, because 20260923-33's allowlist leaves out row comparisons. ORMs generate it often for cursor pagination, so it's arguably an ordinary query under the lean v1 profile. If the answer is yes, allow RowExpr only in a row comparison (`(a, b) op (x, y)` with `<`, `<=`, `>`, `>=`, `=`, or `<>`), and check every walker that SupportedSql guards: qualification, volatility, predicate atoms, 3g redaction, and 3e literals, where a row comparison falls back to the slow literal.

- **Depends on:** 20260923-33.
- **Came from:** The review of 20260923-33 and the second review of 20260924-16.
- **README:** Step 1.
- **Status:** done

### 20260926-37. Step 9 fixtures fail to load on realistic schemas.

The prompt pack (20260922-65, part one) ran the pipeline on an ordinary users/products/orders/line_items schema, and every supported query stopped at step 9 with `fixture_load_failed`:
- **23505, unique violation:** the scenario builder honors unique constraints but not unique indexes created with `CREATE UNIQUE INDEX` (for example `users_email_key`). It also skips columns that have a default, which can collide.
- **23503, foreign-key violation:** fixture rows reference a parent table the query doesn't name (`orders.user_id` pointing to `users`), and the parent rows are never loaded.
Both are correctness bugs on realistic setups: a correct rewrite is rejected. Fix the scenario builder so fixtures honor unique indexes (including partial unique indexes and expression unique indexes, or refuse cleanly) and load parent rows for every FK, including FKs to tables outside the query, recursively. Test on the prompt pack's schema (`script/prompt_pack/schema.sql`).

- **Depends on:** 20260922-45, -49.
- **Came from:** The 20260922-65 prompt pack run.
- **README:** Step 9.
- **Status:** done

### 20260926-34. Report loose ends.

- If `IndexCandidate.from_ddl` can't parse a built index's DDL, the report shows an empty cell and doesn't say why.
- The `StepNine::Report#dropped` count isn't included.
- "Whether step 10 covered them" shows only the `evidence` flag, because per-round covered shapes aren't stored.
- A plan node with no `Schema` field is matched to a table by name only when exactly one subset table has that name.

- **Depends on:** 20260922-62.
- **Came from:** 20260922-62 build and review.
- **README:** Step 15.
- **Status:** done

### 20260926-35. Statistics spec restores the pg_stats grant.

The read-failure test in `enclave/spec/statistics_step_postgres_spec.rb` revokes `SELECT ON pg_catalog.pg_stats FROM PUBLIC` and never restores it. The container is shared per process, so a later spec that reads pg_stats as a non-superuser could fail depending on test order. Add `GRANT SELECT ON pg_catalog.pg_stats TO PUBLIC` to the `after` block. Also mention the `missing_<entry>` rules in the README.

- **Depends on:** 20260925-20, -22.
- **Came from:** Review of 20260925-20.
- **README:** 3c, "What leaves the enclave".
- **Status:** done

### 20260926-36. Pipeline wiring and 3d follow-ups.

- ReportStage's "selection missing" guard can no longer trigger from the pipeline. Remove it, or test it by calling ReportStage directly.
- The driver's `EnclaveError` doesn't show the new `function` field from a `volatile_function` refusal to the operator (`transport/reply.rb` `error_fields`).

- **Depends on:** 20260926-33, 20260925-21.
- **Came from:** Their builds and reviews.
- **README:** 3d, `quaack run`.
- **Status:** done

### 20260926-38. Report loose ends, part two.

- The `existing` list's DDL redaction has no sentinel coverage (the planted drops carry no literal).
- `NegativeResult.disproved` fails at `store.read` if `rewrite_round_<n>` is missing for a non-survivor.
- 15a finds rewrites by counting up until one is missing, so it assumes no gaps.
- A rewrite that passed steps 9 and 10 but was knocked out by minimax or 14c isn't explained in 15a.
- LLM call counts aren't passed to the report (part of -65).

- **Depends on:** 20260922-63, -64.
- **Came from:** Their build and review.
- **README:** 15a, 15b.
- **Status:** done

### 20260926-39. LLM payload fidelity.

The prompt pack showed two things wrong with what the LLM is sent:
- **Placeholder types:** the `created_at` placeholders in the ORM join are typed `text` in the payload, though the plan casts them to `timestamptz`. The payload should give each placeholder the type Postgres infers for it (for example from a PREPARE, as `Measurement` does).
- **pg_dump's `\restrict` token:** the schema DDL sent to the LLM includes pg_dump's random `\restrict`/`\unrestrict` token lines. They're noise for the LLM, and they change every prompt on every run. Strip them from the schema in payloads.

- **Depends on:** 20260925-4 (index payload), 20260922-37 (rewrite payload).
- **Came from:** Review of the 20260922-65 prompt pack.
- **README:** 3b, 5a-5, 6a.
- **Status:** done

### 20260926-41. Step 9: support expression unique indexes instead of refusing.

After 20260926-37, a unique index on an expression anywhere in the fixture tables' closure (for example `CREATE UNIQUE INDEX ON users (lower(email))`, which is common in Rails apps) makes step 9 refuse the whole query as `expression_unique_index`. That fails safe, but it refuses many realistic schemas. Support it: evaluate the expression for candidate values (through Postgres, as `ValuePools.probe` does) and keep the evaluated keys distinct. Or, since fixture text values are already distinct, give every column the expression touches a distinct value, and verify the expression values differ.

Also from the review:
- Values set explicitly on identity columns don't advance the sequence. If ParentRows and a scenario path that leaves the identity column out ever write to the same table, they could collide. Call `setval` after loading, or confirm the two never mix.
- No test covers INCLUDE columns or partial unique indexes directly.
- `UNIQUE NULLS NOT DISTINCT` isn't handled.

- **Depends on:** 20260926-37.
- **Came from:** 20260926-37 build and review.
- **README:** Step 9.
- **Status:** done

### 20260924-13. Leak-test helper loose ends.

Findings from the reviews of 20260922-9:
- **A Tempfile slips past the IO refusal.** Tempfile is a Delegator, so `is_a?(IO)` is false, and a Tempfile holding a sentinel returns no findings. Refuse Tempfile too. A File nested inside an object is also neither scanned nor refused.
- **The positive control doesn't plant in Array elements, Hash keys and values, Struct or Data members, or a StringIO's `#string`,** though its comment says it does. The unit specs catch those breaks. Add the plants, or reword the comment.
- **Surviving mutants:**
  - `MAX_DEPTH` 24 → 10
  - case-insensitive `extra:` needles
  - scanning only the first backtrace line
  - `MIN_EXTRA` 9 → 4
  - the `seen` set, which only affects speed
- **`pg` isn't a runtime dependency of quaacks,** so `LeakCheck::Quaacks` can't run subcommands that connect to Postgres. The first task with such a step (20260922-16) must add `pg` to the quaacks gemspec and to `ENCLAVE_ALLOWED_GEMS`.
- **The harness schema has no JSON column,** so the fixture can't plant the JSON sentinel in stored rows.

- **Depends on:** 20260922-9.
- **Came from:** Both reviews of 20260922-9.
- **README:** Trust boundary.
- **Status:** done
- **Note:** The `pg` item is resolved. 20260922-16 made pg a runtime dependency of quaacks.

### 20260924-14. LLM client loose ends.

Findings from the builds and reviews of 20260922-6:
- **Streaming.** Non-streaming requests are capped at the gem's limit: 21,333 max_tokens for the default model, and lower for some models. Add streaming if a step ever needs bigger outputs.
- **Lazy-load `anthropic`.** Requiring it adds about 0.5s to every driver CLI start, even for commands that never call the LLM.
- **A driver config file** for the model and similar settings. Today config comes only from code and the environment.
- **Surviving mutants in `driver/lib/quaack/driver/llm/client.rb`:**
  - `limit = MODEL_NONSTREAMING_TOKENS[...]` → `nil`. The per-model limit is never tested. Try `model: "claude-opus-4-0"` with `max_tokens: 8193`.
  - `ENV[ALLOW_REAL_ENV] == "1"` → truthy. Nothing tests `QUAACK_ALLOW_REAL_LLM=yes` against the client guard. The root suite and child processes rely on that guard alone.
  - `ENV[SPECS_ENV] == "1"` → truthy. Nothing tests `QUAACK_SPECS=0`.
  - `e.message` passed through with extra text. Messages are matched by prefix only.
- **The `NoNetwork` prepend is only in the driver suite.** The root suite and child processes get only the client-level guard. Consider sharing it.
- **The workload-identity token exchange bypasses `PooledNetRequester`.** It calls `Net::HTTP` directly when a client is built with no key and federation credentials exist. Our client always passes a key, so only a spec that builds `Anthropic::Client` directly could reach it.
- **`calculate_nonstreaming_timeout` isn't in the gem's `rbi/` or `sig/`,** so a 1.x update could rename it. The specs would go red, but note this when bumping the gem.

- **Depends on:** 20260922-6.
- **Came from:** The builds and both reviews of 20260922-6.
- **README:** Where QUAACK runs, 15b.
- **Status:** done

### 20260924-17. Teardown loose ends.

Findings from the reviews of 20260922-66:
- **The rule is wrong when the recheck fails.** If the recheck `lstat` inside `Store.teardown`'s `rescue Error` raises a `SystemCallError`, such as EACCES after the base's mode changes mid-call, the raw Errno escapes as `internal_error`, where it should be `bad_store_base` or `teardown_failed`.
- **The rule is wrong after a race.** If the run path is swapped for a non-directory between `open`'s check and the delete, the path is left alone, as it should be, but the rule is `teardown_failed`, not `bad_run`.
- **A doc comment describes unbuilt behavior.** The top of `steps/teardown.rb` says the driver runs teardown at the end of every run. That's future work (20260922-65).
- **A redundant check.** `return :already_gone unless PrivateFiles.lstat(path)` is an equivalent mutant, because the recheck already covers it. Keep it as a fast path with a comment, or drop it.

- **Depends on:** 20260922-66.
- **Came from:** The reviews of 20260922-66.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-20. Driver transport loose ends.

Findings from the reviews of 20260922-5:
- **A timeout doesn't stop the remote `quaacks`.** It kills only the local ssh process. With `-T`, the remote side gets no SIGHUP, and it can keep running queries on the jump server until it next writes. Options: run the remote side under `timeout`, or have the enclave CLI exit when stdin or stdout closes.
- **Over ssh, a remote quaacks killed by a signal shows up as ssh exit 255,** so `killed?` is false. The error line still decides the rule.
- **Lexical is skipped when a line starts with whitespace,** so json 2.9.1 and 3.0.2 read ` {"type":"error",/*c*/"rule":"zz"}` differently. Check `line.lstrip`, or run Lexical on every line.
- **A child that closes stdout and then reads the rest of stdin hangs until the timeout,** because Pump stops writing on stdout EOF.
- **A grandchild holding stdout makes a call wait out the whole timeout** (3,600s by default) and then report success.
- **MAX_ARGV_BYTES doesn't bound the escaped ssh remote command.** Shellwords turns a newline into 3 bytes, so a value that passes can exceed Linux's 128 KiB per-argument limit and show up as `incomplete`. Cap the escaped length for Ssh.
- **Three Pump mutants are caught only by hanging the suite.** Add a per-example timeout to the driver specs.
- **The timeout test expects under 3s against a 1s timeout,** which could flake on a loaded machine.

- **Depends on:** 20260922-5.
- **Came from:** The reviews of 20260922-5.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-15. 3h clock anchoring loose ends.

Findings from the builds and reviews of 20260922-24 and 20260924-12:
- **Restore LLM candidates by anchored form, not by position.** `restore` finds added names by slot number. That's sound for queries with the same structure, but a restructured rewrite candidate (README step 15) usually gives `restore_mismatch`. Rarely, it could strip a name the author wrote that happens to match. A candidate that swaps the anchors gets mislabeled, and `quaack.clock_anchor()::date` without pg_catalog raises. This is needed if the report shows candidate SQL.
- **`'now'`, `'today'`, `'yesterday'`, and `'tomorrow'` literals also read the clock,** as in `created_at > 'today'::date - 7`. That needs a README change, or a decision from the user.
- **Three-part names:** `db.pg_catalog.now()`.
- **Refusing pg_temp and `$user` before pg_catalog is stricter than Postgres.**
- **ImplicitName differs from Postgres for some scalar subqueries.** It reads the raw parse, and Postgres reads the analyzed target list. For example, `(SELECT * FROM (SELECT 1 AS z) q)` is `z` in Postgres but `?column?` here, `(SELECT t.* FROM ...)` is `z` but `t` here, and `(VALUES (1))` is `column1` but `?column?` here. Anchoring stays correct, because inner slots keep their own names. Fix the code, or narrow the doc comment's claim.
- **Surviving mutants:**
  - `figure_sub_link`: removing `return NONE unless target` survives. Add `(VALUES (1))` to the oracle list.
  - `figure_sub_link`: the weak-name path `target.name.empty? ? figure(target.val) : strong(target.name)` survives. `(SELECT 1)::text` kills it.
  - `clock_anchoring.rb` `split_path`: dropping `cause: nil` from the `bad_search_path` raise survives.

- **Depends on:** 20260924-12.
- **Came from:** The reviews of 20260922-24 and 20260924-12.
- **README:** 3h.
- **Status:** done

### 20260924-18. Governed store loose ends, part two.

Minor findings from the second review of 20260923-34:
- **Nothing tests that create makes nothing through a linked `~/.quaack`.** In `Store.create`, replacing the first `in_base(...) { PrivateFiles.make_directories(base) }` with a plain call survives: the second check still raises BadBase, but `target/runs` gets created. Add a store case where the parent is linked and the target has no `runs`, and assert the target stays empty.
- **The pre-open lstat's condition isn't pinned.** `unless File.lstat(file).file?` → `if File.lstat(file).directory?` survives. Stub `File.lstat` to return a FIFO's stat for a real regular-file entry, and expect a refusal. Also fix the `PrivateFiles.read` comment, which says no test can tell the lstat is there.
- **`Store::BaseChecks` is a public constant.** Its methods are private, but it could be `private_constant`.
- **A base directly under macOS `/tmp` is refused,** because `/tmp` is a symlink. Only a custom test base can hit this. `standalone_require_spec` falls back to `/tmp` when `TMPDIR` is unset.

- **Depends on:** 20260923-34.
- **Came from:** Second review of 20260923-34.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-19. 3a relations loose ends.

Findings from the reviews of 20260922-17:
- **A function in FROM can hide a view or foreign table.** With `CREATE FUNCTION public.f() RETURNS SETOF public.order_view LANGUAGE sql STABLE AS 'SELECT * FROM public.order_view'`, `SELECT * FROM f()` passes with relations `[]`, while EXPLAIN shows the base table scanned. Non-inlined functions have the same gap. README 3a says to list relations with pg_query, so this matches the letter of the README. But 3b and 3c may need the relations the plan actually scans. Decide whether to refuse set-returning functions in FROM, or to read relations from the plan.
- **A relation named only in an unused CTE is still checked,** so it can over-refuse, for example `WITH c AS (SELECT id FROM p1) SELECT id FROM ONLY p1`.
- **`Relations.check` always reads search_path,** where `RelationQualifier.qualify` reads it only when a name has no schema. It doesn't matter in practice.
- **3b and 3c may need inheritance descendants,** because the scan reads them. `relations` lists only the tables the query names.
- **A leaf partition named directly is relkind `r`, so it passes.** **Decided:** Allow it and treat it as the table it is.

- **Depends on:** 20260922-17.
- **Came from:** The reviews of 20260922-17.
- **README:** 3a.
- **Status:** done

### 20260924-22. 3b schema dump loose ends.

Findings from the build and reviews of 20260922-18:
- **The subset DDL can't restore into an empty arena on its own.** `pg_dump --table` emits no `CREATE SCHEMA`, types, domains, enums, functions used in defaults or CHECKs, or extensions. That matters for 4b and step 10.
- **A query table that's a partition needs its parent.** Its dump carries `ALTER TABLE ONLY <parent> ATTACH PARTITION`.
- **The full dump covers only the query's namespaces plus public,** so a cross-schema FK ancestor is in the subset but not in the full dump. That follows the README, but it's worth knowing.
- **Add `--no-password` (`-w`),** so pg_dump never prompts.
- **A SQL_ASCII database with non-ASCII names crashes as `internal_error`.** It fails closed. Refuse SQL_ASCII by name, and list it as unsupported in v1.
- **In EUC_JP or WIN1252 databases, tables aren't in UTF-8 byte order.** Sort in Ruby after transcoding.
- **Near-miss secret keys aren't refused,** such as `"password "`, `PASSWORD`, or keys holding `=`. Require keys to match `/\A[a-z_]+\z/`.
- **Untested paths:** the subset dump's lock-wait timeout, a signal-killed pg_dump beyond the message, and an empty conninfo.
- **A password can hide in a dbname URI.**
- **Both dumps are held in memory.**

- **Depends on:** 20260922-18.
- **Came from:** The build and reviews of 20260922-18.
- **README:** 3b.
- **Status:** done

### 20260924-23. Deparse loose ends.

Findings from the build and reviews of 20260924-4:
- **`'t'::boolean` and `'f'::boolean` are still refused.** The deparser prints them as `true` and `false`, which parse to a different tree.
- **Shapes turn `EXISTS (SELECT WHERE x)` into `EXISTS (x)`,** because `deparse_expr` strips every `SELECT WHERE `.
- **Very deep queries raise RuntimeError instead of deparse_mismatch.** The wrappers can push a tree past pg_query's encode limit of 1,000, for example `(e OR b) IS TRUE` nested 150 times. It fails closed as `internal_error`, but callers that rescue only `Deparse::Error` (generator two, index SQL, relations, and the rewrite candidate check) abort instead of skipping. Rescue the encode error in `faithful_parse`, and raise `Error`.
- **Stale comments:** `predicate_atoms.rb` lines 82–89, `index_candidate.rb` lines 52–55, and `deparse.rb` lines 15–21, which don't mention Parentheses.
- **Four mutants refuse rare SQL without a test noticing:** the `b_expr` edits at `parentheses.rb` line 156 (three variants), and `operator_level(..., subquery: true)` at line 300. Pin them if it's cheap.
- **The deparse_spec matrix adds about 20s** to the enclave suite.

- **Depends on:** 20260924-4.
- **Came from:** The build and reviews of 20260924-4.
- **README:** Step 1.
- **Status:** done

### 20260926-46. Driver crashes on the first counterexample round.

`Pipeline::CounterexampleStage.compare` (`driver/lib/quaack/driver/pipeline.rb:151`) passes `round:` as an Integer. `Transport::Base#option` accepts only Strings, so it raises `ArgumentError: --round needs a String value` before the enclave runs. Any real run whose rewrite passes step 9 crashes. The specs miss it because `pipeline_spec.rb:304` uses a fake transport that doesn't validate args. Fix it with `round.to_s`, and add a spec that goes through the real `Transport::Base#argv`. Then check for other Integer option values the same way, and remove the prompt pack's `PromptPack::Transport` workaround.

- **Depends on:** 20260926-14.
- **Came from:** Prompt pack regeneration.
- **README:** Step 10.
- **Status:** done

### 20260926-47. Refuse user-defined set-returning functions in FROM.

A set-returning function in FROM can hide a view or foreign table from 3a's relation checks (`SELECT * FROM f()` where `f` reads a view).
- **Decided:** Allow built-in (pg_catalog) set-returning functions such as `generate_series` and `unnest`. Refuse user-defined functions in FROM, and list that as unsupported in v1.

- **Depends on:** 20260924-19.
- **Came from:** Build of 20260924-19.
- **README:** 3a, step 1.
- **Status:** done

### 20260926-48. Anchor clock-reading date literals.

`'now'`, `'today'`, `'yesterday'` and `'tomorrow'` as date or timestamp literals read the clock, just as `now()` does, but 3h doesn't anchor them.
- **Decided:** Anchor them. Rewrite them to the `clock_anchor()` equivalent, as 3h does for `now()` and `current_date`, so runs are reproducible.

- **Depends on:** 20260924-15.
- **Came from:** Build of 20260924-15.
- **README:** 3h.
- **Status:** done

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty.

`Hangup.during` watches stdout with `IO.select` for the reader going away. A regular file is readable at once, so `quaacks probe > out.json` sends HUP immediately and every step fails. A read-write tty becomes readable on a keypress. Start the watcher only when `out.stat.pipe? || out.stat.socket?`, and test both cases.

- **Depends on:** 20260926-45.
- **Came from:** Review of the -45 hangup item.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260926-52. Anchor the clock in rewrite candidates too.

The original is anchored (3h: `now()`, `current_date`, and since 20260926-48 the `'now'`/`'today'`/`'yesterday'`/`'tomorrow'` literals), but LLM and operator rewrite candidates bind the raw placeholder values and call the real clock functions. For a query whose `'now'` literal is compared against a timestamp column, steps 9, 13, 14 and 14c can then see spurious differences between the anchored original and a candidate. The other words differ only across a day boundary or with a pinned anchor. Apply the same anchoring (functions and clock-literal placeholders) to every candidate before it's tested or measured, and test a `'now'` query end to end through a candidate.

Also from the review of -48:
- `restored_node` now accepts any type_cast, which weakens restore's mismatch detection. Add a restore spec with an unrelated `$n::date` next to an anchored one.
- Clock words typed another way (a function argument, an expression on a column, a domain over a domain) aren't anchored, and are listed as unsupported in v1.

- **Depends on:** 20260926-48, 20260922-24.
- **Came from:** 20260926-48 build and review.
- **README:** 3h, steps 9-14.
- **Status:** done

### 20260923-6. Test the runtime check's environment scrubbing.

Removing `GEM_PATH` or `RUBYLIB` from the isolated environment in `spec/support/isolated_install.rb` stays green. Without `GEM_PATH`, RubyGems can see the user and Homebrew gem directories. Also consider `RUBYGEMS_GEMDEPS` and `HOME` (for `~/.gemrc`). Plant a leak for each and prove the check goes red. Also check that closure gems like `quaack-protocol` load from the installed copy, not the repo.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, finding 4.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-8. Unit-test the RepoGems helper.

`spec/support/repo_gems.rb` finds each repo gem's gemspec for the boundary and runtime specs, but its lookups have no direct tests:
- **The one-gemspec guard is untested.** Loosening `paths.size == 1` to `>= 1` in `RepoGems.gemspec` keeps every spec green. Only `enclave/` has its own "exactly one gemspec" test. If `driver/` or `protocol/` gained a second gemspec, `paths.first` could quietly pick the wrong one. Test the guard with two gemspecs planted in a temp directory.
- **One test repeats another.** `spec/repo_gems_spec.rb` checks that the enclave gemspec is named `quaacks`, which `enclave/spec/gemspec_spec.rb` already checks. Replace it with direct tests of `RepoGems.gemspec` and `gemspec_path_of`.
- **Noisy failures.** `enclave/spec/gemspec_spec.rb` loads its gemspec with `Gem::Specification.load` instead of `RepoGems.load`. A broken gemspec makes most of its examples fail with a `NoMethodError` on nil instead of one clear message.

- **Depends on:** 20260923-3.
- **Came from:** Second review of 20260923-3, minor findings 1 through 3.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-9. Close the test gaps in the spec task guards.

Task 20260923-5 made `rake spec` find the suites itself, run them all, and fail if the root suite didn't run. The second review found that the guards work today, but some mutants of them still pass every test:
- **The root guard is only tested by changing SPEC_SUITES.** The test in `spec/rakefile_spec.rb` swaps `SPEC_SUITES` for `%w[foo]`. So a guard that checks `SPEC_SUITES` instead of what actually ran also passes. Combined with a later `drop(1)` in the loop, full `rake` goes green with no root suite. Add a test where `SPEC_SUITES` still includes `"."` but the loop skips it.
- **Nothing tests a suite that can't start.** When `sh` can't start the command, `ok` is nil. Changing `unless ok` to `if ok == false` keeps every test green, and then a missing interpreter makes `rake spec` pass with zero examples run. Also, `ran` records a suite as run even when it never started. Test both.
- **Output is hard to use.** The echoed command has no shell quoting, so you can't paste it to rerun one suite. A suite that can't start is reported only as `Spec suites failed: x/spec`, with no reason or exit status.
- **The Rakefile comment oversells the guard.** It says the guard catches "a loop that skips a suite", but that holds only for the root suite.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, findings 1, 2, 4, 5, and 6.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-10. Stop local RSpec options from filtering out boundary specs.

RSpec reads `.rspec-local`, `~/.rspec`, and `SPEC_OPTS`. None of them are in the repo, and `.rspec-local` isn't gitignored. A `.rspec-local` with `--exclude-pattern "**/boundary*_spec.rb"` made full `rake` pass with a planted enclave dependency on `quaack-driver`. The root suite ran 20 examples instead of 61. Local `rake` is the only check, so a personal options file can quietly turn off the trust-boundary checks. Make the spec task ignore local and personal RSpec options, or check that the boundary specs actually ran, and test it with a planted exclusion.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, finding 3.
- **README:** Where QUAACK runs.
- **Status:** done

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
- **Status:** done

### 20260923-18. Runtime checker test loose ends.

Findings from both reviews of 20260923-13, all outside its diff:
- **Dead plants in three older tests.** In `spec/runtime_boundary_checker_spec.rb`, three tests stay green with their planted `require` deleted: "flags the driver as forbidden even when the allowlist admits it", "flags an LLM SDK by what it loads as", and "flags any file from the installed driver gem". Each adds a dependency on a gem built from source, so the every-file run flags that gem's files anyway. They aren't vacuous, since each goes red when its named rule breaks, but the plant proves nothing. Restrict each assertion to the `--version` run, or assert the planted path.
- **Failing for the right reason.** The two bare-dependency tests fail with a `KeyError` from `gem_dirs.fetch` when their dependency is removed, not on their assertion. Assert that the gem is installed first.
- **Isolation code no test watches.** In `spec/support/isolated_install.rb`, nothing tests `"GEM_PATH" => @home`, `"RUBYOPT" => nil`, `Bundler.with_unbundled_env` in `run_ruby`, or `File.realpath` in `stdlib_dirs`. Test them, or say why they're belt and braces. This overlaps with 20260923-6.

- **Depends on:** 20260923-13.
- **Came from:** Both reviews of 20260923-13.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-25. Static checker loose ends.

Minor findings from the second review of 20260923-7:
- `::Bundler.require` isn't flagged, because `bundler_require?` needs a `ConstantReadNode` receiver, and `::Bundler` parses as a `ConstantPathNode`.
- In names-only mode, the driver misses `require_relative "../../../../enclave/lib/quaack/enclave"`, and doesn't check its shebang. That's by design per the task, but say so in the header.
- The header and the `require_violations` comment say names-only mode checks only forbidden names, but parse failures are still flagged. Fix the wording.
- Nothing pins `names_only: true` for the real driver in `spec/boundary_spec.rb`. Dropping it stays green. The fixture tests do pin the mode itself.

- **Depends on:** 20260923-7.
- **Came from:** Second review of 20260923-7.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260926-40. Keyset pagination loose ends.

- Step 9 pools keysets only on the leading column. Scenarios never build the tie case, so a candidate that changes only the tie-breaker value (`(qty, id) < (7, 901)` instead of `(7, 900)`) can pass step 9. Seed tie rows on the leading column, or list it as a v1 limitation. (Steps 10 and 14c may still catch it.)
- Row comparisons with `=` or `<>`, or with an expression in the column row, get no pool, so 9c may mark them untested.
- 3e picks no worst-case or typical values for tuple placeholders.
- No candidate-specific tests for row comparisons in rewrites.
- The relation-qualifier keyset test sits under a misleading `describe`.

- **Depends on:** 20260924-31.
- **Came from:** 20260924-31 build and review.
- **README:** 3e, step 9.
- **Status:** done

### 20260926-44. Expression-unique loose ends.

- `RowSet`'s `expression?` guard is untested: inverting it stays green. Add a unit test with a crafted key like `a), (b`, asserting the group is dropped without running the key.
- There's no perturb-and-retry for colliding expression keys, so the group is dropped.
- A column an expression reads that the row leaves out (a generated column) counts as NULL when the key is worked out.

- **Depends on:** 20260926-41.
- **Came from:** 20260926-41 build and review.
- **README:** Step 9.
- **Status:** done

### 20260926-50. FROM functions: non-FuncCall items crash.

`FromFunctions.calls` assumes every FROM function item is a FuncCall, so `SELECT * FROM current_user` or `SELECT * FROM coalesce(1,2)` may raise NoMethodError instead of a clean refusal (unless an earlier stage refuses them). Refuse any non-FuncCall item cleanly, and test it. Overloads aren't told apart either: a user function sitting earlier in the path with a pg_catalog name is refused (documented as unsupported in v1).

- **Depends on:** 20260926-47.
- **Came from:** 20260926-47 review.
- **README:** 3a.
- **Status:** done

### 20260923-23. Dedupe repeated ORDER BY columns in 5a-1.

Split out of 20260923-20. Postgres reads a column that ORDER BY repeats only at its first position, whatever the repeat's direction or position. An index on `(a, created_at)` serves both `ORDER BY a, a DESC, created_at` and `ORDER BY a, created_at, a DESC` with no Sort. Generator one no longer drops repeats. So today `WHERE a IN (1, 2) ORDER BY a, a, created_at` gives only `(a)`, and `ORDER BY created_at, created_at DESC` can propose a key with `created_at` twice. Re-add the dedupe, keeping the first occurrence. Test it with a non-adjacent repeat such as `ORDER BY a, created_at, a DESC`, so an adjacent-only dedupe goes red.

- **Depends on:** 20260923-20.
- **Came from:** The tests-only round of 20260923-20, where the old test stayed vacuous against an adjacent-only dedupe.
- **README:** 5a-1.
- **Status:** done

### 20260923-26. Egress loose ends.

Minor findings from the second review of 20260922-7:
- **A String subclass as a Hash key isn't tested.** Changing `[String, Symbol].include?(key.class)` in `plain_hash` to `is_a?` checks stays green, and it's a real leak: `rule: { Class.new(String) { def to_s = "SENTINEL" }.new("a") => 1 }` then sends the sentinel. Add it to the table of values that must raise.
- **A Hash-like message isn't tested.** Changing `message.is_a?(Hash)` to `message.respond_to?(:each_key)` stays green. Add an object with `each_key` and `[]`, or `ENV`, to the "sends nothing" table.
- **Deep nesting and cycles raise `SystemStackError`.** Fixed by 20260923-32 through the shared `PlainData.check`. Drop this item. A 100,000-deep Array or a self-containing Array recurses in `plain` before JSON's nesting limit applies. Nothing leaks, but the contract says `Egress::Error`, and `SystemStackError` isn't a `StandardError`. Add a depth cap in `plain`.
- **Error filtering (20260922-8) must catch `Egress::Error`, and must never print the cause chain of the errors it filters.**

- **Depends on:** 20260922-7.
- **Came from:** Both reviews of 20260922-7.
- **README:** Trust boundary.
- **Status:** done

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
- **Status:** done
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
- **Status:** done

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
- **Status:** done

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
- **Status:** done

### 20260925-19. Schema-dump loose ends.

Minor findings from the first review of 20260925-9:
- **A failure after the writes.** The connection stays idle in transaction through both pg_dump runs. If production's `idle_in_transaction_session_timeout` ends the session, the ROLLBACK in `Inventory::Production.read_only` raises `production_read_failed` after `schema_dump` and `schema_subset` are already stored. Reproduce it with `ALTER ROLE ... SET idle_in_transaction_session_timeout = '1s'` and a fake pg_dump that sleeps 2 seconds. Fix: do the catalog reads, commit, then run pg_dump and write; or delete both entries on a later error.
- **The transaction test only proves that some transaction is open, not that it's read-only.** Note this, or find a way to check `transaction_read_only`.

- **Depends on:** 20260925-9.
- **Came from:** The first review of 20260925-9.
- **README:** 3b.
- **Status:** done

### 20260925-23. Anchor step loose ends.

- **`clock_replacements` can't go straight back into `restore`.** It's stored as string-keyed hashes, but `ClockAnchoring.restore` calls `.anchored` and `.original` on objects. Add a loader (`ClockAnchoring.load_replacements(store)` or similar) that rebuilds them, with a test that round-trips the stored form through `restore`. Step 15 needs this.
- **The step spec doesn't cover `now() - interval $n`.** Add a case.

- **Depends on:** 20260925-15.
- **Came from:** The first review of 20260925-15.
- **README:** 3h.
- **Status:** done

### 20260925-1. Index DDL check loose ends.

Findings from the second review of 20260922-11:
- **The unparsable sentinel test doesn't exercise the leak path.** In `enclave/spec/index_ddl_check_spec.rb`, the `"unparsable"` case in "a sentinel in the DDL" ends in a trailing AND. So pg_query's message is "syntax error at end of input", which never quotes the sentinel. Plant the syntax error on a sentinel token, such as `... WHERE status = '<sentinel>' '<sentinel>'`. The exact-message test still catches a leak today.
- **The README doesn't list the index DDL rules.** README "What goes into the enclave" says only "exactly one `CREATE INDEX` statement on a table the query uses". Add the refusals (CONCURRENTLY, UNIQUE, NULLS NOT DISTINCT, TABLESPACE, ON ONLY, an unqualified table, volatile functions, parameters, subqueries, and aggregates). Also say that the index name is dropped and that STABLE is left to Postgres.

- **Depends on:** 20260922-11.
- **Came from:** The second review of 20260922-11.
- **README:** What goes into the enclave.
- **Status:** done

### 20260925-3. Plan gate loose ends.

Minor findings from the first review of 20260922-28:
- **The `Redaction.binding` call in `plan_gate.rb` is untested.** Deleting it stays green. Add a test that SQL which doesn't bind to the stored map (an extra `$n`, or unredacted SQL) raises `Redaction::Error`.
- **The guards in `CanonicalPlan#unqualify_type` are untested.** Removing the anchor-only guard or the `names.size > 1` guard stays green. Test them, or drop the guards if stripping `pg_catalog` from every cast is fine.

- **Depends on:** 20260922-28.
- **Came from:** The first review of 20260922-28.
- **README:** Step 5.
- **Status:** done

### 20260925-24. Index-search loose ends.

- `Dedupe.restore` doesn't check that `considered` matches the lists, so a corrupt entry restores silently.
- `index_search.rb` finds proposals with `==`, which relies on `IndexCandidate#==` ignoring sources. If SingleCandidateTest ever normalizes a candidate, the lookup gives nil and crashes.

- **Depends on:** 20260925-6.
- **Came from:** The reviews of 20260925-6.
- **README:** 5a-3, 5a-4.
- **Status:** done

### 20260926-57. Update the e2e corpus for keyset support, and check for other drift.

The e2e corpus (merged from the user's branch) was written against an older README. Case `070-row-comparison-refused` expects keyset pagination `(created_at, id) < (...)` to be refused, but 20260924-31 made it supported. Turn 070 into an `index` case (for example an index on `(created_at DESC, id DESC)`), add a new refused case for a construct that is still refused (SIMILAR TO, TABLESAMPLE, or CTE CYCLE), and regenerate with `ruby e2e/verify.rb <case> --write`. Then run `quaacks intake` (or `SupportedSql`) over all 100 slow queries to catch any other case whose supported/refused expectation has drifted. Note in `e2e/README.md` that the full verify takes about 25 minutes and isn't part of `rake`.

- **Depends on:** 20260924-31.
- **Came from:** Review of the e2e corpus branch.
- **README:** Step 1.
- **Status:** done

### 20260926-43. Payload fidelity loose ends.

- Nothing tests the fallback when PREPARE fails (empty `parameter_types`, so the payload falls back to the 3g type class).
- The rewrite payload spec only checks that it agrees with the index payload, not that the types are correct.

- **Depends on:** 20260926-39.
- **Came from:** 20260926-39 build and review.
- **README:** 5a-5, 6a.
- **Status:** done

### 20260926-59. Keyset tie rows are dropped on realistic schemas.

On the prompt-pack `shop.orders` schema, step 9 doesn't catch a keyset candidate that changes only the tie-breaker value (`id < 900` becomes `id < 901`). The candidate passes with `dropped: 3`: the tie rows are left out, probably because they collide on a unique key, an FK, or the `GENERATED ALWAYS` identity id. The same test catches it on the simple `fx` schema. Find out why the tie rows are dropped, and make them load: give their other unique columns distinct values, keep them within FK parents, and handle identity keys as 20260926-37 did. Add the tie-breaker test to `step_nine_realistic_schema_postgres_spec.rb`.

- **Depends on:** 20260926-40, -55.
- **Came from:** Build of 20260926-55.
- **README:** Step 9.
- **Status:** done

### 20260926-58. End-to-end runner over the e2e corpus (20260922-65, part two).

Build a runner (a script or rake task outside the default `rake` check, like `e2e/verify.rb`) that runs the real `quaacks` + `quaack run` pipeline end to end over each `e2e/cases/*`:
- a throwaway harness Postgres standing in for production, loaded from the case's `schema.sql`
- a run server and racetrack from the same data
- the driver's `Pipeline`
- a fake LLM that returns empty answers for now, and replays `spec/fixtures/llm_corpus` replies once they exist

Per case it checks the case's claim:
- a `refused` case fails intake with the expected rule
- `index` cases produce a report whose top-ranked fix meets the case's block bound in `results.md`/`case.json`
- `rewrite`, `both` and `trap` cases are recorded as expected to need the LLM
- no case crashes

It writes a summary table and fails clearly on crashes. Any real QUAACK bug it finds becomes its own backlog task, not a fix inside this one.

- **Depends on:** 20260926-33, 20260926-57, the e2e corpus.
- **Came from:** User direction, 2026-09-26.
- **README:** All.
- **Status:** done

### 20260927-1. Set operations crash generator one (5a-1).

e2e cases 029, 058, 068, 097, 098 and 100 stop at `index-search` with `internal_error`. `generator_one.rb:157` raises `ArgumentError` on UNION, INTERSECT or EXCEPT, which intake accepts. Handle set operations in 5a-1: generate candidates per branch, or skip set-operation queries with a clean result. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-7. e2e corpus fixes: 075 and 010.

- 075's table has an inheritance child, which README 3c refuses as `inheritance_parent`. Make the case expect that refusal, or drop the child.
- 010's GIN index comes from the LLM, but its `features` don't say 5a-5. Add it.

- **Depends on:** the e2e corpus.
- **Came from:** The e2e runner.
- **README:** none.
- **Status:** done

### 20260927-6. Weak or unstable top picks.

- e2e 066 never finds the two-index combination it needs.
- 025 generated the right shape, but its top fix measured 4984 blocks against a bound of 2618.
- 055's matching candidate was declined as unused.
- Most urgent: the top fix isn't stable between runs on the same data. 024 measured 52 then 8 blocks, and 096 measured 2511, 11, then 2511. 070 (5 vs 4) and 086 (1013 vs 1007) miss narrowly on every run.

Find out why ranking or measurement varies between runs; it could be ANALYZE sampling, hint-bit or visibility-map state, or ties in ranking. Until then, the index verdicts can't gate anything. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-7, 12-14.
- **Landed (2026-09-27):** the instability was in the e2e harness, not in QUAACK. With `synchronous_commit=off`, VACUUM raced the WAL writer, so `relallvisible` came out 0 or full at random, and that flipped index-only pricing. The fix is a CHECKPOINT before VACUUM in `e2e/run.rb`. 024, 070 and 096 now pass every run. What's left moved to 20260927-9 to -12.
- **Status:** done

### 20260927-12. e2e 086 misses its bound by 6 blocks.

Now that runs are stable, 086 measures 1013 blocks against a bound of 1007, every run. Find out whether it's a real small miss in QUAACK or a bound that's too tight in the corpus.

- **Depends on:** 20260927-6.
- **Came from:** The 20260927-6 investigation.
- **README:** none.
- **Status:** done

### 20260927-2. 5a-4 and the plan gate prepare with untyped parameters.

`SingleCandidateTest#explain` (`single_candidate_test.rb:419`) prepares the query without parameter types, so Postgres guesses wrong:
- e2e 020, 048, 099 fail with `prepare_failed` 42883: `now()::date - $1` resolves as date minus date.
- 031 fails with `explain_failed` 22P02: `4242.0` won't bind to an inferred bigint.
- 091 is probably a plan-gate mismatch on `substring(... FROM $1 FOR $2)`.

Use the original literal's type for each placeholder (from the placeholder map, or cast the placeholder the way the original literal was written). Check every other PREPARE site (the plan gate, index search) for the same bug. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-4, step 5 plan gate.
- **Status:** done

### 20260927-3. 5a-1 puts grouping and ordering columns in INCLUDE instead of the key.

e2e 013 gets `(tenant_id) INCLUDE (status)` and 073 gets `(account_id) INCLUDE (started_at)`. The cases need those columns as key columns for GROUP BY or ORDER BY to use the index order. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-4. 5a-1 gives no atoms for correlated subqueries.

e2e 027 (LATERAL top-N) and 089 (`ARRAY(SELECT ...)`) get no index on the correlated column. Generate candidates from correlation predicates inside LATERAL and scalar/array subqueries. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-5. 5a-1 gives no candidates in some common shapes.

These shapes get no candidates:
- A column compared with a non-constant expression (e2e 076, 078, 093, 094).
- OR across two columns (015, which could use a BitmapOr of two indexes).
- `COLLATE "C"` (090).

Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1, 5a-2.
- **Status:** done

### 20260927-8. e2e 097: top fix far above bound; CTEs and subqueries get no candidates.

- e2e 097 (a set operation) no longer crashes, but its top fix measures 384 blocks against a bound of 118. Diagnose why.
- Generator one gives no candidates for a CTE body or a subquery in FROM, including set operations inside one. Add a spec pinning that a CTE referenced from a set-operation branch is neither refused nor qualified as a table. Consider descending into CTE bodies and FROM subqueries for candidates.

- **Depends on:** 20260927-1.
- **Came from:** 20260927-1 build and review.
- **README:** 5a-1.
- **Status:** done

### 20260927-14. Typed-prepare loose ends, and e2e 020 and 099.

- **e2e 020:** `started_at >= current_date - 1 GROUP BY user_id`. Its one candidate is declined as unused (bound 94). Diagnose it: clock anchoring's effect on the predicate, or 5a-1's choice.
- **e2e 099:** the top fix touches 13 blocks against a bound of 12. Is it a ranking issue or the bound?
- **Weak sentinel test:** the "failed typed prepare error free of the literal" test can't catch a regression, because the sentinel never reaches PREPARE.
- **Type names:** `Redaction.prepare` and `Binding#prepare_sql` interpolate type names unchecked. They're safe only because the set is fixed. Add an allowlist.
- **SELECT only:** `Redaction.one_statement?` doesn't require a SELECT.

- **Depends on:** 20260927-2.
- **Came from:** 20260927-2 build and review.
- **README:** 5a-4.
- **Status:** done

### 20260927-13. 5a-1 adds a non-covering INCLUDE and no bare-key variant.

Diagnosed from e2e 086 (20260927-12). QUAACK built `catalog (price_cents) INCLUDE (id, sku, name)`, which measured 1013 blocks against 1007 for the plain `(price_cents)` index. The plan is a BitmapOr feeding a heap scan, which never uses INCLUDE columns, and the heap filter needs `category`, which isn't in the INCLUDE. So the INCLUDE only widens the leaf entries.
- `btree(key)` (generator_one.rb ~792) always adds `include: covered - key`.
- `covered_columns` (~584) takes only target-list and GROUP BY columns, and leaves out WHERE-only filter columns.
- No bare-key variant is proposed, so ranking can't compare the two (`considered: 1`).

Fix: add the INCLUDE only when it makes the index truly covering for that table (every column the query reads from it, filter columns included), and/or always also propose the bare-key variant. Related to 20260927-11 (INCLUDE vs deduplication).

- **Depends on:** 20260927-12.
- **Came from:** The 20260927-12 investigation.
- **README:** 5a-1.
- **Status:** done

### 20260927-15. 5a-1 generation loose ends.

These are minor findings from the review of 20260927-3 to -8:
- A volatile value (`col = random()`) counts as a value and yields a false candidate. Refuse volatile calls in `value?`.
- A schema-qualified outer reference (`public.orders.id`) isn't treated as an outer column.
- Inside a subquery, an unqualified outer column that shares a name with an inner column resolves to the inner table.
- The first collation wins when a column gets different COLLATEs.
- Long OR chains build one set of uses per arm. Consider a cap.

- **Depends on:** 20260927-5.
- **Came from:** Review of 20260927-3 to -8.
- **README:** 5a-1.
- **Status:** done

### 20260927-16. one_statement? lets data-modifying CTEs and SELECT INTO through.

`Redaction.one_statement?` accepts `WITH d AS (DELETE ... RETURNING 1) SELECT ...` and `SELECT ... INTO t2`, because both parse as a SelectStmt. SingleCandidateTest rolls back, so writes should be undone. Check whether its transaction is READ ONLY, and consider refusing non-SELECT CTEs and `into_clause` (intake's allowlist probably already refuses these in the original query; check). e2e 020 now passes after 20260927-5, and 099 passes after 20260927-2.

- **Depends on:** 20260927-14.
- **Came from:** Review of 20260927-14.
- **README:** 5a-4.
- **Status:** done

### 20260926-60. A fixture load failure in the vacuity guard crashes step 9.

A genuine fixture load failure inside `VacuityGuard.exercised_atoms` (vacuity_guard.rb:91, from step_nine.rb:41) raises `ArenaRunner::Error` out of `StepNine.run` instead of producing a clean per-candidate outcome. Decide how 9c should treat a scenario that won't load: skip it and mark its atoms untested, or refuse the candidate with a rule. Then handle it, with a test.
- **Decided (2026-09-27):** scenarios must never crash QUAACK. Skip a scenario that won't load and mark the atoms it would have tested as untested.

- **Depends on:** 20260922-48, 20260926-59.
- **Came from:** Build of 20260926-59.
- **README:** Step 9.
- **Status:** done

### 20260927-10. Capture and restore relallvisible.

The planner prices index-only scans from `pg_class.relallvisible`. The enclave captures only `reltuples` and `relpages`, so index-only pricing on the racetrack depends on whether it has been vacuumed, not on production. Capture `relallvisible` in the statistics step. **Decided (2026-09-27):** neither, for v1. Assume production is vacuumed normally and the racetrack is fully analyzed and vacuumed after restore. Document these assumptions in the README (3c, 4a).

- **Depends on:** 20260922-17.
- **Came from:** The 20260927-6 investigation.
- **README:** 3c, 4a.
- **Status:** done

### 20260927-9. 5a-7 ranking and combining are stricter than the README.

e2e 025 and 066 fail because of how `IndexRanking` reads the worst-case rule:
- A candidate the planner doesn't use for the worst-case literal gets a worst-case reduction of 0, so a marginal index that helps every set by about 5% outranks one that cuts the slow set by 4x (025).
- `combine` adds a second index only if the worst case improves, so a needed pair is never built (066).

README 5a-7 says to keep adding indexes "as long as each addition lowers the cost further".
- **Decided (2026-09-27):** follow README 5a-7: keep adding while cost drops without making any set worse, and break worst-case ties on the next-worst set. (The original question was whether to combine while an addition lowers cost without making any set worse, and when worst-case reductions tie, compare the next-worst set before falling back to size? That changes how the worst-case rule is read.

- **Depends on:** 20260922-35.
- **Came from:** The 20260927-6 investigation.
- **README:** 5a-7.
- **Status:** done

### 20260927-11. HypoPG size ignores B-tree deduplication.

In e2e 055, the real key-only index `orders (status, total_cents)` is 5.6 MB and used, but HypoPG estimates 17.4 MB. 5a-1 proposes the INCLUDE shape, which isn't deduplicated, so the real planner wouldn't use it either. **Needs a decision:**
- make 5a-1 prefer key columns over INCLUDE when the leading key has few distinct values
- correct the size estimate for low-cardinality key-only indexes
- or list this case as unsupported in v1
- **Decided (2026-09-27):** HypoPG's estimate can't be corrected from outside, but 12a already builds every index for real. So when 5a-4 declines a key-only B-tree index on a low-cardinality leading column as unused, set it aside for 12a the way GIN and GiST candidates are, instead of dropping it. 12a builds it for real, and steps 13 and 14 measure it.

- **Depends on:** 20260922-30, -32.
- **Came from:** The 20260927-6 investigation.
- **README:** 5a-1, 5a-4.
- **Status:** done

### 20260927-20. Regenerate the prompt pack: JSON-only instruction and a subtly wrong fake rewrite.

The user's first 18 replies (`correlated_exists/10a-1`, `10a-2`) showed two problems:
- **Code fences and prose:** some models wrap JSON in code fences or add prose. Add an explicit "reply with only the JSON object, no code fences or commentary" line to every LLM prompt the driver sends (5a-5, 5a-6, 6a, step 7, 10a). The API's structured output already enforces the schema, but this helps other providers. Make the replay tolerant of fences too.
- **Empty answers:** the pack's fake 6a rewrite is exactly equivalent (a MATERIALIZED CTE wrapper), so 10a has no real counterexample and models return nothing. Give each query's fake rewrite a small, plausible bug (a changed boundary, a dropped condition) that still survives step 9 often enough to reach 10a, or add one buggy rewrite alongside the equivalent one.

Regenerate the pack. Move the existing 18 replies to an `archive/` subfolder for the equivalent-rewrite prompt, so they're kept but not mixed with the new prompts. The user will redo the replies (decided 2026-09-27).

- **Depends on:** 20260922-65 part one.
- **Came from:** The user's first replies.
- **README:** 5a-5, 6a, step 7, 10a.
- **Status:** done

### 20260927-21. LLM reply parsing: pick the right object, and check the schema.

These are minor findings from the review of 20260927-20:
- `embedded_json` always starts at the first `{`, so prose like `Using {"a":1} as shown: {"indexes":[]}` yields `{"a":1}`. Try every start, and prefer the object that matches the schema. Or refuse when more than one top-level object parses.
- `Client#ask` doesn't check a parsed reply against the schema. Check at least the required keys, so a wrong object is refused as `llm_bad_response` instead of reaching callers. (Claude's structured output makes this moot today; it matters for other providers and for replay.)

- **Depends on:** 20260927-20.
- **Came from:** Review of 20260927-20.
- **README:** LLM client.
- **Status:** done

### 20260922-65. Full pipeline.

Wire every step together in the driver, from intake through the report and teardown. Run it end to end against the test harness.
- **Decided:** The end-to-end test uses a scripted fake LLM, so it runs free in rake. The scripts must be realistic, drawn from a large corpus of responses. **Before building, ask the user questions:** they'll collect responses from several different LLMs to seed the corpus.
- **Landed (part one):** The prompt pack generator, `script/prompt_pack/run.rb`, and a partial pack in `spec/fixtures/llm_corpus/`. Rerun it after 20260926-37 and keyset support land, to capture the 10a and step 11 prompts.
- **Note (2026-09-26):** The user is having another LLM build a large end-to-end query corpus: for each test, the schema, the inserts, the slow query, and the changes that make it fast. Build -65's end-to-end tests on that corpus when it arrives. Don't spend cycles writing our own fixture queries beyond the small prompt pack.
- **Decided (corpus):** Split into two parts. First, a builder generates a prompt pack: it runs the pipeline on harness fixtures and captures every real LLM prompt (5a-5, 5a-6, 6a, step 7, 10a) to files. The user pastes each prompt into 3 LLMs, 3 replies each, and saves the replies next to the prompts. The fake LLM then replays them. Queries to cover: an ORM-style join (equality plus range, ORDER BY, LIMIT), aggregates with GROUP BY/HAVING, a correlated EXISTS or IN subquery, and keyset pagination (row comparisons are unsupported in v1, so that one tests the refusal path unless it's written without a row comparison).

- **Decided (replay, 2026-09-27):** A rake spec runs the four prompt-pack queries through the full pipeline, with the fake LLM replaying the corpus. It replays every saved reply separately, not just one per LLM. A prompt with no saved replies yet falls back to the e2e runner's valid empty answer, and the output notes that.

- **Depends on:** 20260922-36, 20260922-39, 20260922-42, 20260922-49, 20260922-52, 20260922-64, 20260926-1, 20260926-2, 20260927-23.
- **README:** All.
- **Status:** done
- **Landed (part three, 2026-09-27):** `spec/pipeline_replay_spec.rb` replays the corpus through the full pipeline in rake. 20260927-23 then added driver teardown, which covers the rest. Leftovers are in 20260927-24.
- **Note:** `e2e/cases/` holds 100 cases for this test to run QUAACK against, each with its schema and data, slow query, and expected outcome (new index, rewrite, both, negative result, trap to disprove, or refusal). `ruby e2e/verify.rb` proves each case against Postgres 18. See `e2e/README.md`.
- **Note (from 20260922-66):** The enclave's `quaacks teardown --run <id>` exists. The driver has to:
  - Call it at the end of every run: on success, on abort, on exception, and on signals where possible.
  - Require the `teardown` line followed by the done line.
  - Treat `store: "already_gone"` as success.
  - On `bad_run`, `bad_store_base`, or `teardown_failed`, tell the operator to check or remove `~/.quaack/runs/<id>` by hand. The enclave never sends the path.
  - Turn `next_step: "destroy_run_server"` into a plain operator message. Nothing destroys the run server automatically.
  - Add `--keep` to the run command. It skips teardown and prints the run ID and the exact teardown command for later.

### 20260927-23. Driver calls run teardown (20260922-65, part four).

The enclave's `quaacks teardown --run <id>` exists (20260922-66), but nothing in `driver/lib` calls it. Do the driver work listed in the -66 note under 20260922-65:
- Call teardown at the end of every run: on success, on abort, on exception, and on signals where possible.
- Require the `teardown` line, followed by the done line.
- Treat `store: "already_gone"` as success.
- On `bad_run`, `bad_store_base`, or `teardown_failed`, tell the operator to check or remove `~/.quaack/runs/<id>` by hand.
- Turn `next_step: "destroy_run_server"` into a plain operator message.
- Add `--keep` to the run command. It skips teardown and prints the run ID and the exact teardown command.
Then make `spec/pipeline_replay_spec.rb` assert that each run calls teardown.

- **Depends on:** 20260922-66.
- **Came from:** Build of 20260922-65, part three.
- **README:** Teardown.
- **Status:** done

### 20260927-24. Corpus replay loose ends.

These are findings from the build and reviews of 20260922-65, part three:
- Ask numbering shifts after a disproof. The counterexample loop stops at the first round that finds a mismatch, so later 10a asks get lower numbers than the prompt pack gave them, and their replies go to the wrong asks. Key replies by rewrite and round, not by a per-step count.
- orm_join's wrong rewrite (`u.name IS NOT NULL`) can't be disproved. `users.id` is `GENERATED ALWAYS`, and 10a refuses `OVERRIDING`. Either let 10a inserts set identity keys, or change orm_join's planted bug in the generator and the corpus README.
  - **Decided (2026-09-27):** Let 10a inserts use `OVERRIDING SYSTEM VALUE`, so they can set identity keys. They only load into the throwaway arena, and step 9 fixtures already use it. Update README step 10 and the insert check.
- The drift check compares only the system prompt, and it reads `prompt.md` only from the corpus, not the planted root.
- `PipelineReplay.wrong` finds `"sql"` strings with a regex, not a JSON parse. Assert that `wrong` isn't empty wherever a variant has a wrong rewrite.

- **Depends on:** 20260922-65 part three.
- **Came from:** Build and reviews of 20260922-65, part three.
- **README:** All.
- **Status:** done

### 20260927-26. Chat-friendly versions of multi-turn prompt-pack prompts.

Multi-turn prompts in `spec/fixtures/llm_corpus` (5a-5-2, 5a-6, later 10a rounds) hold `# User`, `# Assistant`, `# User` sections. Pasted into a chat window, the model can't tell the `# Assistant` section is its own earlier turn. Make `script/prompt_pack/run.rb` also write a `chat.md` next to each multi-turn `prompt.md`: one message that quotes the earlier turn plainly ("Earlier you replied with this: ...") and then gives the follow-up. Update the corpus README to say to paste `chat.md` when it exists, and to explain that the assistant turn is a planted reply. For example, 5a-5-2's planted reply holds an unqualified index so that the replacement ask happens.

- **Depends on:** 20260922-65.
- **Came from:** User, 2026-09-27, while collecting corpus replies.
- **README:** none.
- **Status:** done

### 20260923-1. Postgres 17 parser under Postgres 18.

The newest pg_query (6.2.3) ships the Postgres 17 parser, and no Postgres 18 version exists yet. The user accepted the Postgres 17 grammar for now. When pg_query fails to parse something, abort with a message that names the parser's Postgres version, so a Postgres 18-only construct is easy to spot. When pg_query ships Postgres 18 support, upgrade it and drop the special message.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Anywhere pg_query parses SQL, including 3a, 5a-1, step 9, and the inbound checks.
- **Status:** done
- **Decided:** Step 3b doesn't parse the schema dump. It finds the subset tables and their FK parents from `pg_catalog`, and gets the subset from `pg_dump --table` for each one (see 20260922-18). So pg_query only parses queries and inbound SQL, and Postgres 18-only syntax in a dump doesn't matter.

### 20260923-2. Enclave deploys by gem install only.

The repo has one Gemfile and one lockfile for all three gems. So `bundle install` from a checkout on the jump server would install the driver gem, its LLM SDK once 20260922-6 adds it, and the dev tools. The enclave has to deploy by building and installing the `quaacks` gem on its own. Document that, and make the wrong way hard or impossible, for example by having the enclave executable refuse to run under a bundle that includes the driver.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note (from 20260922-5):** The driver runs a bare `quaacks` over non-interactive ssh (`ssh -T -o BatchMode=yes -- host 'quaacks ...'`), so `quaacks` must be on PATH for a non-interactive session. The remote login shell must also be POSIX-compatible (bash, sh, or zsh). fish and csh break the Shellwords quoting.
- **Decided:** The driver builds the `quaacks` and `quaack-protocol` gems locally, copies them to the jump server over ssh, and installs them into a user gem directory there. It checks the installed version before each run. There's no gem server.
- **Decided (2026-09-27):** A separate `quaack deploy` command does the install. `quaack run` checks the installed version and refuses on a mismatch, pointing to `quaack deploy`. Install into a user-specific gem directory, never an OS-wide one. The jump servers have gcc and make, so gems with native extensions (pg_query) install from source there.

### 20260923-17. Index shape loose ends.

Minor findings from the second review of 20260923-14:
- **Untested requires.** The three `require_relative` lines added to `enclave/lib/quaack/enclave.rb` have no test. Deleting them keeps every suite green. Add a `"quaack/enclave"` use to `standalone_require_spec.rb` that reaches `IndexCandidate`.
- **Shadowed built-in names.** The built-in aggregate and window name check refuses an unqualified call to a user function that shares a built-in's name, such as `public.lead(int)`. Postgres accepts it, and `pg_get_indexdef` prints it unqualified. So `from_ddl` returns nil for such an existing index. It's rare and harmless, since the index just can't be represented. Document it. Also add a test that a column named like a built-in, such as `lag > 0`, is accepted.
- **Proportion.** The aggregate and window check guards input the mechanical generators can't produce, because a valid query's WHERE clause can't hold those calls. It also misses set-returning functions, `DEFAULT`, and `merge_action()`. Decide whether to keep it, trim it, or finish it when 5a-5 extends the shape.
- **Redundant check.** The `!sql.strip.empty?` check in `index_candidate.rb` duplicates the parse error.

- **Depends on:** 20260923-14.
- **Came from:** Second review of 20260923-14.
- **README:** 5a.
- **Status:** done

### 20260928-3. LLM provider seam, configuration, and Anthropic auth without a key.

The driver only talks to Anthropic, through `LLM::Client`, and it requires `ANTHROPIC_API_KEY`. Many operators have an OpenAI, Google, or Groq key instead. This task makes the provider pluggable and gives it configuration. 20260928-4 adds the second provider.

- Split `LLM::Client` into a provider-neutral front and a provider adapter. The front keeps today's interface and behavior: `ask(step:, messages:, max_tokens:, system:, schema:, json:)` returns text or parsed JSON, and it owns the burndown count per attempt (15b), `ReplyJSON`, the `JSON_ONLY` instruction, the error rules (`llm_auth`, `llm_rate_limited`, `llm_unavailable`, `llm_bad_request`, `llm_bad_response`), and the guard against real clients in specs. The Anthropic adapter holds everything Anthropic-specific: request shape, structured output, stop reasons, the gem's retries, and mapping its errors to the rules.
- Configuration lives in an `llm` block in `~/.quaack/driver.json`: `provider` (`anthropic` or `openai_compatible`), `model`, `base_url`, and `api_key_env`, the name of the environment variable that holds the key. Keys never go in the file. `QUAACK_MODEL` still overrides the model, and `QUAACK_LLM_PROVIDER` and `QUAACK_LLM_BASE_URL` override the others. With no `llm` block, the driver behaves as today: Anthropic, `claude-opus-5-5`. A bad block fails with a usage error that names the key, never a value.
- Anthropic auth: stop requiring `ANTHROPIC_API_KEY`. Let the anthropic gem resolve credentials in its usual order (API key, `ANTHROPIC_AUTH_TOKEN`, then an `ant auth login` profile), and map an authentication failure to `llm_auth`. `api_key_env`, when set, still wins.
- Update README.md (requirements, configuration, and the `llm_auth` row) and DESIGN.md's "Where QUAACK runs".

- **Depends on:** none.
- **Came from:** The user, 2026-09-28. Answers already given: two adapters (Anthropic, plus one OpenAI-compatible adapter that covers OpenAI, Groq, Gemini's compatible endpoint, OpenRouter, and Ollama); configuration in driver.json with env overrides; fold in keyless Anthropic auth.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt`. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image), so run it before merging to `main`. RuboCop, the driver suite, and the boundary specs passed.

### 20260928-4. OpenAI-compatible LLM adapter.

Add the second adapter from 20260928-3: the OpenAI-compatible Chat Completions API, through the official `openai` gem, with the base URL from configuration. One adapter serves OpenAI, Groq (`https://api.groq.com/openai/v1`), Google Gemini's OpenAI-compatible endpoint, OpenRouter, and local servers such as Ollama.

- Map `system` and `messages` to chat messages, and a finish reason other than `stop` to `llm_bad_response`, as the Anthropic adapter does for stop reasons.
- With `schema`, ask for `response_format` of type `json_schema` when the provider takes it. Some providers and models don't enforce schemas. For those, rely on the `JSON_ONLY` instruction and `ReplyJSON`'s validation, and if the reply doesn't validate, re-ask once with the validation error attached, then fail with `llm_bad_response`. Each attempt counts in the burndown. Decide at build time how the adapter learns whether schema mode is supported (configuration, or falling back when the API rejects it), and say which in README.md.
- Map the gem's errors to the same rules as the Anthropic adapter. Keep retries at the gem's level, counted per attempt.
- Add a fake at this adapter's HTTP edge, like `FakeLLM`, and run the existing driver LLM specs against both adapters where the behavior is shared. No spec may reach the network. An opt-in live smoke test (with `QUAACK_ALLOW_REAL_LLM=1` and a real key) may exist, but outside `rake`.
- Add `openai` to the driver gem's dependencies. It's already on `LLM_SDK_REQUIRES`, so the enclave stays barred from it. Check that the boundary specs still pass.
- Verify, before building, what structured-output support OpenAI, Groq, and Gemini's compatible endpoint offer today. Don't rely on memory.
- Where the re-ask lives: after 20260928-3, the front runs `ReplyJSON.parse` after the adapter's `reply` returns, so a "validate, then re-ask once" loop has no home in the adapter contract. Either give the front a re-ask for adapters that don't enforce schemas, or let the adapter call `ReplyJSON` itself. Say which, and keep the burndown counting every attempt.
- Document per-provider setup in README.md, including a Groq example.

- **Depends on:** 20260928-3.
- **Came from:** The user, 2026-09-28. Answer already given: prompt, validate, and retry once when the provider can't enforce a schema.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt` after two reviews and a fix round (a 200 with no `choices` crashed the adapter). The provider docs couldn't be reached, so the structured-output check in this entry is unverified; see 20260929-1. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image), so run it before merging to `main`. RuboCop, the driver suite, and the boundary and guard specs passed.

### 20260929-3. `quaack deploy`: show progress, and diagnose PATH.

`quaack deploy` is silent until it finishes, and when `quaacks` isn't on the jump server's non-interactive PATH, it only points at DESIGN.md. The user's first real deploy ended exactly that way. Make it say what it's doing and work out the fix.

- **Progress.** Print one line on stdout as each step starts: building each gem, copying each one to the host, `gem install` on the host (saying it builds pg_query from source and can take a few minutes), and checking `quaacks` over ssh. The final "installed quaacks X on host" line stays last. Errors stay on stderr.
- **PATH diagnosis.** When the check after install can't run `quaacks`, run read-only probes on the jump server over non-interactive ssh, the same way the driver reaches it. Probes are POSIX sh, because the remote login shell runs them. Find out:
  - what `ruby -e 'puts Gem.user_dir'` prints, or that `ruby` itself isn't on the non-interactive PATH;
  - whether `<user_dir>/bin/quaacks` exists;
  - whether `<user_dir>/bin` is on the non-interactive PATH;
  - the user's login shell.

  Then print the specific fix:
  - The exact line to add, such as `export PATH="<user_dir>/bin:$PATH"`, and the file to put it in: `~/.bashrc` for bash, above any line that returns early for non-interactive shells; `~/.zshenv` for zsh; for other POSIX shells, say which file to check.
  - For a shell QUAACK doesn't support (fish or csh), say that.
  - For a `quaacks` that's on PATH but isn't what was just installed, such as a different Ruby, say that instead.
  - End with the command to check the fix: `ssh <host> quaacks --version`.
- **Never change the jump server's shell config.** Only advise; the user makes the edit.
- **Messages.** Keep them to what the probes found. They're about the jump server's setup, not production data, but print only what's needed.
- Update DESIGN.md's "Deploying the enclave" and README.md's deploy step.

- **Depends on:** 20260923-2.
- **Came from:** The user, 2026-09-29, after a first real deploy. Answers already given: diagnose and advise only (the driver keeps running a bare `quaacks`, so PATH still matters), never edit the user's shell config, and progress goes to stdout with the result.
- **Design:** Where QUAACK runs, "Deploying the enclave".
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt` after two reviews and a fix round (the gem install and check progress lines could print after their step with no test failing). New `DeployDiagnosis` probes the jump server read-only over `sh -s`. The minor findings went to 20260929-6. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image, and `deploy_spec.rb:73` expects aarch64 gems), so run it before merging to `main`. RuboCop and the driver suite otherwise passed.

### 20260929-7. Say which clients `run_server_other_clients` saw.

`quaacks run-server` fails with `run_server_other_clients` when `pg_stat_activity` shows another client backend, but the operator can't tell which one. Have the error line list them, so the operator can find and stop them.

- The error line gains a `clients` field, only for `run_server_other_clients`: an Array of `{ "pid", "backend_start" }`, one per other client backend, oldest first. `pid` is a positive Integer. `backend_start` is the UTC time the backend started, as `YYYY-MM-DDTHH:MM:SSZ`. At most 20 entries, so a crowded server can't make the line huge.
- Nothing else about a client goes out: not `usename`, `application_name`, `client_addr`, `datname`, `state`, or `query`. Those are production configuration or free text. A pid and a start time are neither.
- `clients` joins the `error` entry in `Protocol::WHITELIST`. The enclave's ErrorFilter sends it only for that rule, and only if every entry has exactly that shape. Otherwise it leaves the field out, as it does for `function`.
- The driver's reply parser accepts `clients` with the same shape check, and the driver's error message names the pids and start times.
- DESIGN.md step 4 says the error names the other clients' pids and start times, and nothing else about them.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after a real `run_server_other_clients` failure.
- **Design:** Trust boundary, step 4.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after two reviews and one fix round. Round one found two tests that stayed green with the code broken: nothing checked the oldest-first order, and nothing checked the start anchor of the start-time pattern. Round one's minor findings went to 20260929-11, round two's to 20260929-12. The full check still fails on this Mac with the two failures filed as 20260929-9 and 20260929-10. They fail the same way on unchanged main. The task's own specs, RuboCop, protocol, and the boundary specs pass.

### 20260929-9. The full check fails on a Mac whose pg_dump is older than 18.

`spec/pipeline_replay_spec.rb` runs the installed `quaacks schema-dump`, which uses whichever pg_dump is first on PATH. The test server is Postgres 18. On a development Mac whose PATH has Homebrew's `postgresql@14`, every replay fails with `pg_dump_too_old`, 198 failures on 2026-09-29 on unchanged main (a762d73).

Answers from the user, 2026-09-29:

- The test harness finds a pg_dump whose major version matches the test server's. It checks the `QUAACK_TEST_PG_BIN` directory first, if that's set, then Homebrew's libpq keg (`/opt/homebrew/opt/libpq/bin`). It puts that directory first on PATH only for the `quaacks` children it starts. The operator's own shell PATH is untouched.
- If it finds none, the specs that need one fail early, once, with a clear message naming what to install or set. They never fail 198 times with `pg_dump_too_old`.
- CLAUDE.md's Development section says the full check needs a pg_dump of the test server's major version, and how the harness finds it.
- This Mac's libpq keg was upgraded to 18.6 for this.

- **Depends on:** nothing open.
- **Came from:** The full check run for 20260929-7.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after two reviews and one fix round. Round one found two problems. First, `with_env` in the prompt pack and e2e scripts took its ENV snapshot after calling the finder, so a missing pg_dump showed up as a TypeError. Second, the test that the major version comes from the image stayed green with a hardcoded 18. The minor findings went to 20260929-14 and 20260929-15. With pg_dump 14 first on PATH, the full replay spec passes: 204 examples in about 25 minutes. The root suite is slower than before, because every replay now runs its whole pipeline. 20260929-13 aims to speed that up.

### 20260929-8. `run_server_other_clients` may count QUAACK's own session.

`RunServerCheck` tells its own sessions apart from other clients by libpq's `backend_pid`. That's the pid the server sent at connect time. Behind a pooler or proxy, such as PgBouncer, it can be a pid the pooler made up, not the server backend running QUAACK's queries. Then QUAACK's own session counts as another client, and step 4 fails with `run_server_other_clients` on a quiet server.

- Get each own pid from the server with `SELECT pg_backend_pid()` on that connection, not from libpq.
- Confirmed 2026-09-29 with 20260929-7's output. The run server on port 5431 is PgBouncer in session mode. `run_server_other_clients` named pid 58297, which was QUAACK's own session. The server log shows the check excluded `$1 = '{1235762793}'`, the pid PgBouncer made up and libpq reported. The session came from 127.0.0.1, through PgBouncer.

Answers from the user, 2026-09-29:

- Support PgBouncer in session mode in front of the run server. Each client keeps one server backend for its session, so later steps that rely on one session still work.
- Transaction and statement pooling are unsupported in v1. DESIGN.md step 4 says so. Detecting them is not required.
- Build this alongside 20260929-13, as an exception to the one-task-at-a-time rule. 13 only touches the test harness.

- **Depends on:** 20260929-7.
- **Came from:** The user, 2026-09-29, who doubted the run server really had other clients.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings, so there was no fix round. `RunServerCheck` now reads each own pid with `SELECT pg_backend_pid()`. The test image runs PgBouncer 1.26 in session mode, on demand, and the spec failed with the real error through it before the fix. DESIGN.md step 4 covers poolers. The minor findings went to 20260929-16. The builder's full check passed apart from 20260929-10.

### 20260929-13. Build the prompt-pack database once per spec process.

`PromptPack.databases` builds each replay's production database from scratch: it creates it from template0, loads `script/prompt_pack/schema.sql` and `data.sql`, and runs ANALYZE. The data script generates about 420,000 rows, which takes about 3 seconds, and the pipeline replay spec does that for each of its 39 runs. The data is the same for every query. Copying a database with `CREATE DATABASE ... TEMPLATE` takes about 0.07 seconds.

- Build the loaded, analyzed database once per spec process, on the first run that needs it, and create each run's production database as a copy of it. The racetrack database is already a copy of production, so it stays as it is.
- Every copy must hold the same schema, data, extensions, and statistics as a fresh build. A spec should prove a copy matches.
- The template database must have no connections left open when it's copied, and no replay run may change it.
- `script/prompt_pack/run.rb` uses the same helper, so it gets the same speedup.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after timing the full check.
- **Design:** none. This is test harness speed only.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings, so there was no fix round. The template is built as `pack_template_building` and renamed to `pack_template` once it's complete, and it refuses connections. ANALYZE samples randomly, so two fresh builds give different `pg_stats` for orders and line_items. So the spec checks each copy against the template exactly, and against a fresh build wherever a fresh build is deterministic. The root suite went from about 26m34s to 24m27s. The minor findings went to 20260929-17 and 20260929-18.

### 20260929-19. Schema dump selects `pg_catalog` when an extension lives there.

`SchemaDump.full_dump` adds each extension's schema to the full dump's `--schema` list. `plperl` and `plperlu` live in `pg_catalog`, so on the Canvas test database of 2026-09-29 the dump got `--schema=pg_catalog`. pg_dump then tried to dump the system catalog. It warned "typtype of data type ... appears to be invalid" for every pseudo-type, and it emitted DDL for pg_catalog's own objects, which 4a would then try to load into arena.

Answers from the user, 2026-09-29:

- Never dump a system schema: not `pg_catalog`, not `information_schema`, and not any other `pg_*` schema. `--extension=<name>` alone still gets each `CREATE EXTENSION`.

To do:

- Check that arena's load, 4a, still gets every extension it needs, including one in `pg_catalog` such as plperl.
- Add a Postgres spec with an extension in `pg_catalog`, whichever is simplest to install in the test image. Show that the dump has no `--schema=pg_catalog`, and that it loads into arena.
- Confirmed as the cause of that run's `pg_dump_failed`. The user's production role isn't a superuser. With `--schema=pg_catalog`, pg_dump fails right away with `ERROR:  permission denied for table pg_authid`. A red test should reproduce that with a non-superuser role.

- **Depends on:** nothing open.
- **Came from:** The user's first real run, 2026-09-29.
- **Design:** 3b, 4a.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. `SchemaDump.system_schema?` drops `information_schema` and every `pg_*` schema from the full dump's namespaces, while `--extension` is still passed, so plperl reaches arena. The test image now installs plperl, and a read-only-role spec reproduces the user's `permission denied for table pg_authid` before the fix. The minor findings went to 20260929-22 and 20260929-23.

### 20260929-10. The leak check sees BUNDLER_VERSION in a script's environment.

`enclave/spec/leak_check_spec.rb:374` ("runs a script the same way, with no Bundler in its environment") fails on unchanged main (a762d73) on 2026-09-29. It expected no Bundler variables and got `BUNDLER_VERSION`. A likely cause is Ruby 3.4's bundled bundler re-execing into the lockfile's bundler 4.0.15, which sets `BUNDLER_VERSION`. Find the cause, and scrub the variable, or fix the check, so a script runs with no Bundler in its environment.

- **Depends on:** nothing open.
- **Came from:** The full check run for 20260929-7.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. The cause: under `bundle exec`, Ruby 3.4's bundler 2.7.2 re-execs into the lockfile's 4.0.15 with `BUNDLER_VERSION` set. That lands in `Bundler.original_env`, which `with_unbundled_env` restores, since `unbundle_env` removes only `BUNDLE_*` keys. `IsolatedInstall#isolated_env` now unsets it. The full check passed with 0 failures. The minor findings went to 20260929-24.

### 20260923-40. Allowlist loose ends.

Still open from the reviews of 20260923-33:
- EXTRACT's field match uses Unicode `downcase`, in both `predicate_atoms.rb` and `redaction/query.rb`, so `'weeK'` with a Kelvin sign is kept. Use `downcase(:ascii)`, and print the field lowercased.
- No test pins `EXTRACT_FIELDS`.

- **Depends on:** 20260923-33.
- **Came from:** The reviews of 20260923-33.
- **Design:** Step 1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. Both EXTRACT field matches use `downcase(:ascii)`, and a kept field goes out lowercased, only on the tree copy. A Kelvin-sign `'weeK'` is redacted, and both `EXTRACT_FIELDS` sets are pinned to Postgres 18's 22 fields, checked on a real server. The minor finding went to 20260929-25.

### 20260928-6. LLM provider seam loose ends, part two.

These are minor findings from the second review of 20260928-3:
- The spec for the CLI's default client builder (`cli_run_spec.rb`, "builds the client from the block's settings") only checks `api_key_env`. A builder that drops the block's model or base_url stays green. Move the builder into a small method that takes a transport, so a spec can pass FakeLLM and assert the model and URL in `fake.asks`.
- The same spec sets `QUAACK_ALLOW_REAL_LLM=1`, which turns off the `NoNetwork` guard. Its only remaining guard is `ANTHROPIC_BASE_URL=http://127.0.0.1:9`, so a future explicit base URL could send its sentinel key to the real API from `rake`. Keep a refusal at the gem's requester in that example.
- `AnthropicAdapter` claims a given `api_key:` wins over `api_key_env`, but no spec checks it. Add one, or drop the claim.
- `quaack run` now reads driver.json. A file that exists but can't be read (EACCES) raises `Errno::EACCES` out of `DriverConfig.read`, uncaught, so the run dies with a stack trace. Rescue `SystemCallError` there as `Bad`, or as a "can't read" usage error. `start` has the same gap.

- **Depends on:** 20260928-3.
- **Came from:** Second review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. Changes: `CLI.build_client(settings, transport:)`, with a FakeLLM spec on model and URL; `NoNetwork.always_refuse`, which refuses even with `QUAACK_ALLOW_REAL_LLM=1`; a spec that a given `api_key:` wins; and an unreadable driver.json, now a clean usage error for `run` and `bad_driver_config` for `start`. The minor findings went to 20260929-27.

### 20260929-21. The full schema dump misses schemas that FK parent tables live in.

`SchemaDump.full_dump` dumps the schemas the query's tables live in, plus public. The subset follows foreign keys to parent tables in other schemas, but the full dump doesn't add their schemas. So a query on `sales.items` gets `public` and `sales`, while `sales.skus` has an FK to `audit.vendors`. Loading that full dump into arena then fails with `schema "audit" does not exist` (`arena_dump_load_failed`). The 20260929-19 builder hit this with the existing sample fixture.

This is likely to bite the user's Canvas database, where shard schemas such as `cluster44_shard_7236` may have foreign keys into other schemas.

- Add each FK ancestor's schema to the full dump's namespaces, as `ancestors` already finds them, still leaving out system schemas (20260929-19).
- Red test: the cross-schema FK fixture above, loaded into arena.

- **Depends on:** 20260929-19.
- **Came from:** The build of 20260929-19.
- **Design:** 3b, 4a.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no findings to fix. `SchemaDump.run` passes the FK ancestors, not just the query relations, to `full_dump`, so every ancestor's schema is dumped, at any depth, still without system schemas. A spec loads a two-level cross-schema chain into arena. The reviewer noted that a widely referenced parent schema, such as `auth`, is now dumped whole, and its tables must be lockable by the read-only role. Before the fix, that dump failed to load anyway. The builder's related findings went to 20260929-26.

### 20260923-22. MCV statistics loose ends.

Still open from the second review of 20260923-19:
- An invalid-UTF-8 literal on a t/f column raises `Encoding::CompatibilityError` from `strip`. It fails closed and doesn't leak.
- Optional: a real-Postgres test that pins `= false` on a nullable boolean to `freq(f)`.

- **Depends on:** 20260923-19.
- **Came from:** Second review of 20260923-19.
- **Design:** 3c.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no findings to fix. `ColumnStatistics#boolean_text` leaves an invalid-UTF-8 literal unchanged, so it misses the t/f MCVs and gets the non-MCV estimate instead of raising. The guard is defensive, since pg_query already refuses invalid UTF-8. A real-Postgres spec pins `= false` on a nullable boolean to freq(f).

### 20260923-37. Arena runner loose ends.

Still open from the second review of 20260922-46:
- `ArenaRunner` reports every 57014 as `statement_timeout`, including a self-cancel or an operator cancel. Name it `statement_canceled`, or document it. 20260926-5 fixed this for run discipline only.
- A non-StandardError from the block, followed by a failed rollback, loses the primary error. Changing `rescue Exception` to `rescue StandardError` in `in_transaction` stays green. Add a test that uses an Interrupt.
- Moving `check_fixture` after `refuse_unless_idle` stays green. It only changes which error wins when bad rows meet a busy connection.

- **Depends on:** 20260922-46.
- **Came from:** Second review of 20260922-46.
- **Design:** Step 9.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. A 57014 is `statement_timeout` only once `statement_timeout_ms` has passed since the connection call started, as in run discipline. Anything sooner is the new rule `statement_canceled`, in `arena_runner/cancel.rb`. New specs cover a self-cancel, an operator cancel, an Interrupt surviving a failed rollback, and the fixture check coming before the idle check. The minor findings went to 20260929-28 and 20260929-29.

### 20260924-1. 5a-4 loose ends.

Still open from the second review of 20260923-56:
- Changing `guarded(:cleanup_failed) { deallocate }` to another rule stays green.
- The exact-cost assertions use single-node plans only. Add one on a join.
- `CanonicalPlan` treats any `"<N>…"` index name as hypothetical, so a real index named that way is canonicalized wrong.

- **Depends on:** 20260923-56.
- **Came from:** Second review of 20260923-56.
- **Design:** 5a-4.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. New specs pin `cleanup_failed` on a failed DEALLOCATE and a join's exact root cost. CanonicalPlan now treats an index name as hypothetical only when its `<oid>` is in the map SingleCandidateTest builds from HypoPG's `indexrelid`, so a real index named `"<1>..."` no longer breaks the plan gate. An oid the map leaves out now counts as a real index instead of making the plan not comparable, which is a deliberate trade-off. The minor finding went to 20260929-30.

### 20260927-25. Teardown loose ends.

These are minor findings from the review of 20260927-23:
- A second Ctrl-C, or any other signal, during teardown in the `ensure` replaces the run's original exception. No test covers this.
- `Teardown#call` rescues only `EnclaveError`. Today the transport wraps every failure in one, but any other exception raised during teardown after a failed run would mask the run's error. Broaden the rescue, or comment why it's safe.

- **Depends on:** 20260927-23.
- **Came from:** Review of 20260927-23.
- **Design:** Teardown.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `Teardown#call` rescues any StandardError. A non-EnclaveError becomes `driver_error`, with the `quaacks teardown` hint. A signal during teardown prints the run's original error, then re-raises. The reviewer checked that printing `Class: message` for a non-EnclaveError can't carry unapproved enclave output, since the transport turns every bad reply into an EnclaveError with no cause. The minor findings went to 20260930-1.

### 20260929-17. Test the prompt-pack template's recovery from a failed build.

`PromptPack.template` in `script/prompt_pack/run.rb` builds under `pack_template_building`, renames it once the build is complete, and first drops any leftover `pack_template_building`. No test needs that. Building straight into `pack_template`, or skipping the drop, leaves the spec green. Then a data.sql or ANALYZE failure in one replay would leave a half-built template for the next replay to copy. The reviewer confirmed by hand that the real code recovers. Add a spec that plants a one-time build failure and checks that the retry produces a complete copy. Also rewrap the odd header comment at run.rb:9-10.

- **Depends on:** 20260929-13.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to fix. A new example in spec/prompt_pack_databases_spec.rb wraps `PG.connect` so the first build's ANALYZE fails once. It checks that no `pack_template` is left, then that the retry builds a complete copy. Both mutations named here go red, and it doesn't disturb the replay specs. The header comment in run.rb is rewrapped.

### 20260929-25. Pin the guard on EXTRACT field lowercasing in the query redaction.

In `Redaction::Query#lowercase_field` (enclave/lib/quaack/enclave/redaction/query.rb), dropping `&& extract_field?(constant)` leaves every spec green. Every SQL-syntax EXTRACT's first argument would then be lowercased, recognized or not, so a redacted `'Years'` would be stored as `years`. Nothing leaks, since the value is redacted either way. Make the Kelvin test in redaction_query_spec use an uppercase ASCII letter, such as `'WEEK'` with the Kelvin sign, and expect the placeholder map to keep the original case.

- **Depends on:** 20260923-40.
- **Came from:** Review of 20260923-40, round one.
- **Design:** 3g.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. The Kelvin example in redaction_query_spec now uses `'WEEK'` with the Kelvin sign, and expects the placeholder value to keep its case. Dropping the `extract_field?` guard, or reintroducing the Unicode downcase from 20260923-40, turns it red. The full rake on the branch passed with 0 failures.

### 20260929-23. Pin the underscore in `SchemaDump.system_schema?`.

Changing `start_with?("pg_")` to `start_with?("pg")` leaves every spec green. That version would silently drop a user schema like `pgbouncer` (common for PgBouncer's auth_query) or `pgaudit_log`, and the query's tables would be missing from the dump and arena. Add an example with such a schema holding a query table, and assert it stays in the namespaces and the DDL.

- **Depends on:** 20260929-19.
- **Came from:** Review of 20260929-19, round one.
- **Design:** 3b.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. A Postgres example keeps `pgbouncer` and `pgaudit_log` query tables in the dump. A new unit spec pins `system_schema?` on system and look-alike names, which were checked on a real server: Postgres reserves only a lowercase `pg_` prefix. The minor finding went to 20260930-2.

### 20260928-5. LLM provider seam loose ends.

These are minor findings from the build and review of 20260928-3:
- A set-but-empty `ANTHROPIC_API_KEY` hides other credentials. The anthropic gem treats `""` as a set key, so it skips `ANTHROPIC_AUTH_TOKEN` and profile discovery, then sends no credential header. With `ANTHROPIC_AUTH_TOKEN` also set, the run fails `llm_auth` after one counted attempt. With a valid `ant auth login` profile, it fails with "no Anthropic credentials". Refuse up front with "ANTHROPIC_API_KEY is set but empty", or pass the token or discovered credentials explicitly. Also fix the comment on `AnthropicAdapter#credentials?`, which says an empty key is sent as no header.
- `Start`'s `rescue DriverConfig::Bad` has no spec. A driver.json of `not json`, `[1]`, or `null` gives `bad_driver_config` today, but deleting the rescue keeps every spec green. Add those cases to `start_spec.rb`.
- The anthropic gem prints precedence warnings on stderr, such as "ANTHROPIC_API_KEY is set and takes precedence over ... auto-discovery", even when `api_key_env` supplied the key. They leak no values, but they mislead. Silence them or explain them.

- **Depends on:** 20260928-3.
- **Came from:** The build report and round-one review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. With no key passed, the first of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` that's set must be non-empty. Otherwise the run fails with `llm_auth: <VAR> is set but empty` before any attempt. When QUAACK passes the key, a `GivenKeyClient` subclass skips the gem's misleading precedence warning. start_spec covers `not json`, `[1]`, and `null`. The builder worked while the safety classifier was down. The reviewer confirmed the diff touches only the five files the task calls for. The minor findings went to 20260930-3.

### 20260929-15. `TestPgDump.server_major`'s regex is under-tested.

The test "reads the major version from the image's FROM line" in `spec/test_pg_dump_spec.rb` uses a fixture Dockerfile with no digits before `FROM`. So weakening the regex to `/(\d+)/` keeps it green. Put a line with a number before `FROM` in the fixture, such as `ARG PG_MAJOR=16` or a comment naming a version, and check that the test still reads the `FROM` line's major.

- **Depends on:** 20260929-9.
- **Came from:** Review of 20260929-9, round two.
- **Design:** none. Test harness only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to fix. The fixture now has a comment naming `FROM postgres:16` and an `ARG PG_MAJOR=16` before `FROM postgres:17`, so an unanchored or digit-anywhere regex reads 16 and goes red. Dropping the `\b` isn't caught. That's harmless for the real Dockerfile, which pins a plain major.

### 20260929-28. Arena runner cancel tests: pin the start time, and bound the wait.

Minor findings from the review of 20260923-37:

- No test pins that `ArenaRunner` records a statement's start time per connection call. Recording one start for the runner's whole life leaves every spec green. StepNine reuses one runner across scenarios, so after the timeout's worth of total time, an operator's cancel would read as `statement_timeout`. Add a test with a short timeout: two `pg_sleep` calls, each under it, then a self-cancel. Expect `statement_canceled`.
- In `arena_runner_postgres_spec.rb`, the operator-cancel test's canceler thread polls for the `PgSleep` wait event with no deadline. If a regression stops the INSERT from running, `canceler.join` blocks forever and the suite hangs. Give the loop a deadline.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** Step 9.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. A new test with a 2000 ms timeout runs two `pg_sleep(1.3)` calls, then a self-cancel, and expects `statement_canceled`. It goes red if the runner keeps one start time for its whole life. The operator-cancel test's poll loop now gives up after 10 s instead of hanging. It passed 10 times under heavy load with no flakes. The minor findings went to 20260930-5.

### 20260929-12. `clients` shape checks: round-two test gaps.

Minor findings from the second review of 20260929-7. The code is correct, and none of these can leak today, because the enclave builds the start time with a fixed-format `to_char`.

- Changing `\A` to `^` in the start-time pattern survives the specs, in both the enclave's ErrorFilter and the driver's reply parser. So does changing the driver's `\z` to `$`. Add cases with the start time after or before a newline to both suites.
- The driver never tests keeping exactly 20 clients. With the driver's limit at 19, a real 20-client error line would lose its `clients` field and the specs stay green.
- Whether the UTC test in `enclave/spec/run_server_check_postgres_spec.rb` catches a 12-hour clock (`HH12`) depends on the time of day the suite runs. Pin it to an afternoon hour.
- The enclave never tests its exact-class checks on an Array or Hash subclass, only on a String subclass. Loosening them to `respond_to?` survives. Egress's own plain-data check backs them up.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round two.
- **Design:** Trust boundary, step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. New tests cover four gaps. Newline cases pin the start-time anchors in ErrorFilter and the driver. The driver keeps exactly 20 clients. Array and Hash subclasses are dropped by ErrorFilter's own exact-class check. The start-time `to_char` is now the constant `BACKEND_START_SQL`, tested on a fixed afternoon timestamp, so HH12 is caught at any time of day. The minor findings went to 20260930-6.

### 20260930-4. An assertion in index_candidate_expression_spec passes a value as its failure message.

The enclave suite prints "WARNING: ignoring the provided expectation message argument(5) since it is not a string or a proc", and the same for `(:lower)`, from enclave/spec/index_candidate_expression_spec.rb:50. The line is `expect { key_column.new(expression: bad) }.to raise_error(ArgumentError, /expression/), bad`, inside a loop over bad inputs. `bad` is only meant to label which input failed, and RSpec ignores it for the non-string inputs `5` and `:lower`. The assertion still runs for every input, so nothing is untested. Pass `bad.inspect` so the label works and the warning goes away.

- **Depends on:** nothing open.
- **Came from:** The build of 20260929-15.
- **Design:** 5a-3.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. The label is now `bad.inspect`, so the warning is gone and a failure names its input. No other spec file had the warning.

### 20260930-2. Pin that `system_schema?` matches `pg_` only as a prefix.

Changing `start_with?("pg_")` to `include?("pg_")` in `SchemaDump.system_schema?` leaves every spec green. That version would drop a user schema such as `app_pg_stats`, and its query tables would be missing from the dump and arena. Add a name like `app_pg_x` to the "leaves every other schema to the user" list in enclave/spec/schema_dump_spec.rb.

- **Depends on:** 20260929-23.
- **Came from:** Review of 20260929-23, round one.
- **Design:** 3b.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. `app_pg_x` in the user-schema list turns `include?("pg_")` and `match?(/pg_/)` red.

### 20260930-3. Anthropic credential checks: minor findings.

Minor findings from the review of 20260928-5:

- `GivenKeyClient#warn_env_shadow(**)` accepts only keyword arguments. If the anthropic gem starts passing positional arguments, building the client raises ArgumentError. Use `(*, **)`. A rename is already caught, because llm_client_spec's warning example goes red.
- README.md and DESIGN.md read as if any empty Anthropic variable fails the run. Only the first of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` that's set is checked. Tighten the wording.
- When `api_key_env` names a variable that's set but empty, the message is "`<VAR>` isn't set", while the new check says "is set but empty". Make them agree.

- **Depends on:** 20260928-5.
- **Came from:** Review of 20260928-5, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. An `api_key_env` variable that's set but empty now says "is set but empty", while an unset one still says "isn't set". `GivenKeyClient#warn_env_shadow` takes `(*, **)`, pinned by a spec that calls it with positional arguments. README.md and DESIGN.md say which empty variable fails a run. The minor findings went to 20260930-8.

### 20260929-11. `run_server_other_clients` clients list: minor test gaps.

Minor findings from the first review of 20260929-7. Each is untested, but none is visible outside the enclave on a realistic setup.

- `RunServerCheck` returns nil rather than `[]` when every other client leaves between the count query and the list query. Changing that to `[]` survives the specs. ErrorFilter drops an empty Array, so nothing changes on the wire. Pin it, or drop the special case.
- In ErrorFilter's client shape check, dropping the key-order check survives the specs. A Hash with its keys reversed then goes out, and the driver drops it, because its key check cares about order. Add a reversed-key-order case, or make both sides agree on whether order matters.
- `ORDER BY pid` passes the specs as well as `ORDER BY backend_start, pid`. They differ only across pid wraparound.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round one.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `RunServerCheck` now returns `[]` rather than nil when no client is left to name, and ErrorFilter already drops an empty list. Reversed-key-order rows on both sides pin that key order matters. Two new Postgres tests shadow `pg_stat_activity` with a temp view: one where the list comes back empty after a non-zero count, and one where the older client has the higher pid. The review found that the check's unqualified catalog names can be shadowed through search_path. That went to 20260930-9.

### 20260930-7. The OpenAI-compatible adapter says "isn't set" for an empty key variable.

In driver/lib/quaack/driver/llm/openai_compatible_adapter.rb (about line 113), the key variable named by `api_key_env`, or `OPENAI_API_KEY`, is reported as "`<VAR>` isn't set" when it's set but empty. Since 20260930-3, the Anthropic adapter tells the two apart: "isn't set" versus "is set but empty". Make the OpenAI-compatible adapter match, and test both messages.

- **Depends on:** 20260930-3.
- **Came from:** The build of 20260930-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. `named_key` says "isn't set" for an unset variable and "is set but empty" for an empty one, as the Anthropic adapter does. Specs cover both the `api_key_env` variable and `OPENAI_API_KEY`, and check that no attempt is made or counted.

### 20260929-24. Scrub every Bundler variable, not a named list.

Minor findings from the review of 20260929-10:

- `IsolatedInstall#isolated_env` unsets Bundler variables by name. Another `BUNDLER_*` in a developer's shell, such as a leftover `BUNDLER_ORIG_*`, still reaches the child. The leak check then fails loudly, so nothing slips through. Unset every key matching `/\ABUNDLE/` in `ENV` and `Bundler.original_env` instead.
- `Deploy::UNBUNDLED` (driver/lib/quaack/driver/deploy.rb) and deploy_spec's `clean` env don't unset `BUNDLER_VERSION`. It's harmless today, since `gem build` ignores it and ssh doesn't forward it. Add it for consistency with deploy_diagnosis_spec.

- **Depends on:** 20260929-10.
- **Came from:** Review of 20260929-10, round one.
- **Design:** none. Test harness and deploy only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `isolated_env` unsets every `/\ABUNDLE/` key in `ENV`, and it's always computed inside `Bundler.with_unbundled_env`, where `ENV` is what the child inherits. So a separate `Bundler.original_env` scan isn't needed. `Deploy::UNBUNDLED` also drops `BUNDLER_VERSION`, and a deploy_spec example pins what `gem build` sees. The minor finding went to 20260930-10.

### 20260930-1. Teardown: capture the run's error exactly.

Minor findings from the review of 20260927-25:

- `Teardown.around` takes the run's in-flight error from `$ERROR_INFO` in its `ensure`. That's exact today, but if `around` is ever called from inside a rescue body, a successful run that gets a signal during teardown would report the outer error as the run's. Capture it explicitly, with `rescue Exception => e; run_error = e; raise`, or add a comment.
- A signal that arrives while the `rescue StandardError` clause is printing, or in `around` after `call` returns, still loses the run's error. So does a non-StandardError from the transport, such as a LoadError. Both need a tiny window or an unusual setup.

- **Depends on:** 20260927-25.
- **Came from:** Review of 20260927-25, round one.
- **Design:** Teardown.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to act on. `Teardown.around` captures the run's error with a `rescue Exception` instead of reading `$ERROR_INFO`. `call` handles signals first, then treats any other exception, such as a LoadError, as `driver_error`, which never masks the run's error. The instant-long signal windows are documented in the class comment, not closed. The reviewer noted that an `exit` from a transport during teardown now reports `driver_error`. Its status is kept when the run succeeded, and it gives way to the run's error otherwise. No transport calls `exit` today.

### 20260930-8. Anthropic credential docs and one spec line: tidy.

Minor findings from the review of 20260930-3:

- README.md:190 is one long sentence ("So does an empty `ANTHROPIC_API_KEY`, or an empty `ANTHROPIC_AUTH_TOKEN` when ..., since ..."). DESIGN.md:139's parenthetical is dense too. Both are accurate. Split them into short sentences, in the house style.
- In driver/spec/llm_client_spec.rb:415, the second assertion of the positional-arguments example checks only that `warn_env_shadow` returns nil. An override that prints and returns nil would pass it. Add `not_to output.to_stderr`, as the first assertion has.
- The class comment at anthropic_adapter.rb:16-18 has uneven line lengths after the reflow.

- **Depends on:** 20260930-3.
- **Came from:** Review of 20260930-3, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. The README and DESIGN credential text is now in short sentences, checked against the code. The positional-arguments spec also checks stderr on the keyword call, which catches an override that warns and returns nil. The adapter comment is rewrapped. The minor findings went to 20260930-12.

### 20260930-9. Qualify the catalog names the run server check reads.

`RunServerCheck`'s `CLIENTS_SQL` and `OTHER_CLIENTS_SQL` read `pg_stat_activity`, and `PLANNER_SQL` reads `pg_settings`, without `pg_catalog.`. Those unqualified names can be shadowed. In the review of 20260929-11, the reviewer set `search_path = public, pg_catalog` on the run server's database and created an empty `public.pg_stat_activity` table. The quiet check then passed with another client connected. If such a table had `pid` and `backend_start` columns, its values would go out as "clients", still in the pid and timestamp shape. The setup is unusual, but the fix is cheap.

- Qualify every catalog relation and function the run server check reads with `pg_catalog.`, and check the rest of step 4, such as `Inventory::Production`'s settings SQL, for the same gap. 20260924-24 already notes `current_setting` and `json_array_elements_text` there.
- Red test: shadow `pg_stat_activity` through the database's search_path, with another client connected, and expect `run_server_other_clients`.
- Qualifying the name breaks the temp-view technique of two tests from 20260929-11: "names no client, and still fails, when none is left to name" and "names the oldest other client first, even when its pid is the higher one". Replace it, for example by running the check's SQL constants against a stand-in source.
- Comment nits from the same review: run_server_check.rb:48's "none if none is left to name" should say "an empty list". error_filter.rb:37-39 should say the two keys must come in that order.

- **Depends on:** 20260929-11.
- **Came from:** Review of 20260929-11, round one.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. Every catalog relation and function in `RunServerCheck` and `Inventory::Production` is `pg_catalog.`-qualified, including `count(*)`, `to_char`, and the `text` cast. The one exception is `$1::json`, since `json` is a keyword. Shadow tests plant look-alikes in `public` under `search_path = public, pg_catalog` and show both still read the real catalog. The two temp-view tests now swap only the FROM clause of the real constants. The follow-ups went to 20260930-13 and 20260930-14.

### 20261001-1. `quaack run` prints the LLM error's detail.

When an LLM call fails, `quaack run` prints only the rule, such as `quaack run failed: llm_bad_request`, so the operator can't tell why the API refused. The detail is already on `LLM::Error#message` (the provider's own error text; for `llm_auth` it's just the status). Print the whole message for `LLM::Error`, such as `quaack run failed: llm_bad_request: <provider's message>`. Keep printing only the rule for enclave errors. The detail comes from the LLM provider and is printed on the laptop, so it doesn't cross the trust boundary. Update the comment above `run_command` and DESIGN.md wherever it says a run failure prints only its rule.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, blocked on an unexplained `llm_bad_request` during an end-to-end test.
- **Design:** The `quaack run` command.
- **Status:** done

### 20261001-2. A failed LLM call says which step it was and how big the request was.

A run against Groq failed with "Please reduce the length of the messages or completion", and nothing said which step overflowed or what filled the request. When an LLM call fails, add to the `LLM::Error` message: the step (such as `5a-5`), `max_tokens`, the system prompt's size in characters, and each message's role and size. When a message holds a JSON payload (the ```json block the steps send), also give each top-level key's size in characters, largest first. Report only sizes, roles, step names, and key names, never content. Do this once, in `LLM::Client`, so every step and adapter gets it.

- **Depends on:** 20261001-1.
- **Came from:** The user, 2026-10-01, blocked on a context-length 400 from Groq during an end-to-end test.
- **Design:** The `quaack run` command; LLM client.
- **Status:** done

### 20261001-3. Trim the LLM payloads to fit a 131k-token window.

A run against Groq (`openai/gpt-oss-120b`, 131k tokens) overflowed at 5a-5. The size report from 20261001-2 showed 550k characters: mechanical_results 322k, schema 154k, stats 52k, and plan 14k. The user settled the cut on 2026-10-01:

- **mechanical_results:** Every candidate keeps its DDL, its sources, whether the planner used it, its total cost per literal, its size, and any refusal. Only the baseline and the single best candidate keep full plans. The best candidate is one the planner used, with the lowest total cost summed over the literals.
- **Schema:** Send only the query's own tables (the run's `relations`), not their FK parents, plus the indexes and constraints on them. Strip pg_dump's noise: SET and set_config lines, comments, COMMENT ON, ownership, grants, and sequence statements. Keep types, enums, and domains. Use pg_query to split and classify the statements. The stored `schema_subset` stays whole, since fixtures and arena need the FK parents.
- **Stats:** Send only the columns of the query's own tables, to match the schema.

Apply the same trimming to the 6a payload (`rewrite_payload`) wherever it sends the same sections. Update DESIGN.md (the 5a-5 and 6a payloads) to say what's sent.

- **Depends on:** 20261001-2.
- **Came from:** The user, 2026-10-01.
- **Design:** 3b, 5a-5, 6a.
- **Status:** done

### 20261001-8. `quaack run` shows its progress.

`quaack run` is silent until it finishes or fails, so the operator can't tell what it's doing or how much is left. Print a progress line to stderr as each step starts, naming the step and where it falls in the run, such as `quaack: [5/18] 5a-5 generator three (LLM)`. Also print a line when a step is skipped because a resumed run already has its output, such as `quaack: [3/18] index-search: already done, skipping`, and when an LLM ask starts and each time it's retried. Lines carry only step names, counts, and timings, never data from the enclave. Stdout stays as it is today. Match the style of `quaack deploy`'s progress lines (20260929-3). Open question to settle before building: should a step that takes a long time also print how long it has been running, or is the start line enough?

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, during an end-to-end test.
- **Design:** The `quaack run` command.
- **Status:** done

### 20261001-9. The full schema dump always includes the `dba` schema.

Arena failed to load 3b's full dump with `arena_dump_load_failed`: the dump holds functions that reference the `dba` schema, which the dump didn't include. To unblock the end-to-end test, `quaacks schema-dump` always adds `dba` to the namespaces it passes to `pg_dump --schema`, like `public`, but only when production has a schema of that name, so a database without one still works. The subset that reaches the LLM doesn't change. Update DESIGN.md 3b. 20261001-10 replaces this with a general fix.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, blocked on arena_dump_load_failed during an end-to-end test.
- **Design:** 3b.
- **Status:** done

### 20261001-12. `quaack run`'s progress lines say in plain English what each step does, and 12a shows each index it builds.

The progress lines from 20261001-8 work, but they use DESIGN.md's step IDs (`5a-5 generator three`, `4b arena-setup`), which mean nothing to someone who hasn't read DESIGN.md. Rewrite each step's line in plain English, keeping the ID in parentheses at the end, such as `quaack: [2/17] Asking the LLM for index ideas the mechanical search missed (5a-5)`. Do the same for the lines for each rewrite and for the LLM ask lines. A second ask in the same step, such as 5a-5's replacement round, should say what it is (`asking again for replacements`) and not repeat the first line.

12a (`index-build`) can take a long time. Have it report each index as it starts, such as `quaack: [10/17] building index 1/23: CREATE INDEX quaack_505c… ON cluster44_shard_7236.submissions USING btree (id, assignment_id)`. The DDL shown must be the redacted form the enclave already lets out (CandidateDdlRedaction: `?` in place of any constant that isn't a low-cardinality MCV), never the stored DDL with its literals. That needs the enclave to send a progress message for each index while it works, and the driver to print it as it arrives, not after the step exits. Today the transport reads the whole reply after the process ends, so this means the transport has to stream. Any message that arrives early must be one of a small, fixed set of progress types, and it carries only what's listed here.

- **Depends on:** 20261001-8.
- **Came from:** The user, 2026-10-01, during an end-to-end test.
- **Design:** The `quaack run` command, 12a, the transport.
- **Status:** done

### 20260929-27. LLM seam: minor findings.

Minor findings from the review of 20260928-6:

- No spec checks that `NoNetwork.always_refuse` resets its flag after an exception inside the block. A reset only on normal exit stays green. That fails safe (the guard stays stricter), but add one example that raises inside the block, then checks that a request reaches the closed port with the opt-in set.
- `DriverConfig.read` treats an unreadable `~/.quaack` directory (mode 000) as a missing driver.json, since `File.file?` returns false. `run` then silently uses the default Anthropic settings, and `start` says `no_driver_config`. Refuse an existing but unreadable `~/.quaack` like an unreadable file. 20260929-4 touches the same code.

- **Depends on:** 20260928-6.
- **Came from:** Review of 20260928-6, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-10-01):** Landed on `main` after one review with no blocking findings. `DriverConfig.read` now stats driver.json: a missing path (ENOENT, ENOTDIR) still counts as no config, but any other error, or something that isn't a regular file, is refused with "can't read ~/.quaack/driver.json". A spec pins that `NoNetwork.always_refuse` resets after a block that raises. The follow-ups went to 20261001-14 and 20261001-15.

### 20260930-11. A `bedrock` LLM provider: Anthropic models on AWS Bedrock.

The driver's `llm` block accepts only `anthropic` and `openai_compatible`, so QUAACK can't call Anthropic models on AWS Bedrock with AWS credentials. The anthropic gem already ships `Anthropic::BedrockClient`, which signs requests with SigV4 using the standard AWS credential chain. It needs the `aws-sdk-bedrockruntime` gem.

Answers from the user, 2026-09-30:

- Add a third provider, `"provider": "bedrock"`, backed by `Anthropic::BedrockClient` through a new adapter behind the provider-neutral client, like the other two.
- Credentials come from the standard AWS chain: environment variables, `~/.aws` profiles, and SSO. A Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK` also works, since the client reads it itself. QUAACK stores no credentials.
- The llm block takes optional `aws_region` and `aws_profile`, plus the usual `model` and `base_url`. `model` is required, since Bedrock model IDs vary by region and inference profile, so there's no default. Check the new keys the way the block's existing keys are checked. A bad value is a usage error naming the key, never the value.
- Map the client's errors onto the existing rules: `llm_auth`, `llm_rate_limited`, `llm_unavailable`, `llm_bad_request`, `llm_bad_response`. That includes AWS credential errors raised before a request is sent, so no SDK exception escapes.
- Add `aws-sdk-bedrockruntime` as a driver dependency only. The enclave must never depend on it: add its require name to `LLM_SDK_REQUIRES` in spec/support/boundary.rb, and keep the boundary specs green.
- No spec may reach AWS. Keep the `NoNetwork` guard working for the new client's requests, and fake at the transport edge as the other adapters' specs do.
- Document it in README.md's LLM setup section and DESIGN.md's LLM client section.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-30.
- **Design:** Where QUAACK runs, LLM client.
- **Status:** done
- **Note (landed 2026-10-01):** Landed on `main` after one review with no blocking findings. `BedrockAdapter` resolves AWS credentials through the standard chain, or takes `AWS_BEARER_TOKEN_BEDROCK`, and maps credential and request failures onto the existing rules without a cause. The llm block takes `aws_region` and `aws_profile`. `aws-sdk-bedrockruntime` is a driver dependency only. The follow-ups went to 20261001-16.

### 20261001-21. Mechanical rewrite rules.

**Needs a design. The user, 2026-10-01: settle this before the report work (20261001-17 to -20). It's a critical part they expected to exist already.** QUAACK has no mechanical rewrite rules, and DESIGN.md never had any. The two mechanical generators (5a-1, 5a-2) propose indexes only. Rewrites come from the LLM (6a) and the operator (step 7) and nowhere else, so a weak model means few rewrites, or none. In run 20261001T210856Z-3b7041a3 the LLM gave one, and step 8 found it planned exactly like the original. The README's opening ("QUAACK has mechanical rules to generate candidates that should help") reads as if rewrites were covered. Fix it either way.

The idea: a generator of sound, catalog-checked transformations that runs in the enclave before 6a, as 5a-1 and 5a-2 run before 5a-5. Each rewrite it makes carries its rule's name and its assumptions in 6b's vocabulary, and goes through steps 8 to 14 like any other. The report then says which rule proposed what.

What rules could do for that run's query: `assignments.id` is the primary key, so `a.id IN (SELECT a2.id FROM assignments a2 JOIN ... WHERE P)` names the same row twice. A rule can drop the inner `assignments`, move its predicates to the outer one, and leave `EXISTS (... WHERE s2.assignment_id = a.id ...)`. That's most of the rewrite the user wrote by hand. The hand rewrite goes one step further and folds the subquery's own join to `submissions` into the outer one, which is right only if a content participation always belongs to its submission's own user. No constraint says so, so no sound rule can assume it, and step 9 or 10 would likely disprove it if the operator submitted it. Whether an operator should be able to assert an invariant the schema doesn't state is a separate question.

- **Depends on:** None.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 6. Needs a new section.
- **Open questions:** Which rules are in version 1. Whether rules chain. Whether the LLM is told what the rules already made. Whether operators can assert invariants.
- **Status:** done
- **Note (2026-10-01):** The user approved the five starting rules, chaining, and running rule-made rewrites through steps 9 and 10, and asked that adding rules stay easy. The design is DESIGN.md 6c. The work is 20261001-22 to -28. Operator-asserted invariants are left for later.

### 20261001-22. 6c: the rule generator, and `key_in_self_join`.

Build DESIGN.md 6c's generator in the enclave gem, with its first rule.

- A rule is one object: a name, a description, and a method from a pg_query parse tree and catalog facts to zero or more rewritten trees, each with its assumptions in 6b's vocabulary. The generator holds a list of rules and knows nothing about any one of them. Adding a rule is one file and one line.
- The generator chains: breadth first, list order, at most two rules deep, duplicates by deparsed SQL dropped, at most five kept.
- `key_in_self_join`, as 6c's table says, including the `UNION ALL` arms.
- `quaacks rewrite-rules --run <run ID>`: runs the generator on the redacted query, puts each result through `rewrite-check`'s checks (inbound, 6b, structural), stores survivors as `rewrite_<n>` with `"source" => "rule"` and `"rules" => [names]`, writes `rewrite_rules_applied`, adds it to `status`, and sends one `rewrite_outcome` each. 6a's and step 7's entries get `"source"` too (`llm`, `operator`).
- Test on real Postgres that each rule's output returns the same rows as its input, on data that would expose a wrong one, and that the rule doesn't fire when the key isn't unique or is nullable.

- **Depends on:** None open.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after two reviews with no blocking findings. `RewriteRules.generate` chains a list of rules; a rule has `name`, `description`, and `rewrites(parse, catalog)`. `key_in_self_join` fires only on a top-level AND condition and refuses anything not clearly safe. `quaacks rewrite-rules` shares `RewriteCheck.check` with `rewrite-check`, and every stored rewrite now has a `source`. The builder changed 6c: a rule may run on its own output, and the marker holds the duplicate and over-cap counts. Adding a rule is one file and two lines. The follow-ups went to 20261002-1.

### 20261001-23. 6c: run the rules from `quaack run`, and count them.

The driver calls `rewrite-rules` before 6a unless `rewrite_rules_applied` is stored. A rerun stores its rewrites again, so the marker is the only guard; the marker has no per-rule counts, which 15b's row needs. Record the 6c burndown stage (add `6c` to the protocol's stages). `report-payload` sends each rewrite's source and rule names, and flags a rule-made rewrite that steps 9, 10, or 14c disproved as a QUAACK bug. Extend the replay spec to cover a rule-made rewrite end to end. Reword the README's opening and step list to say rules propose rewrites too.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c, 15b.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. `quaack run` calls `rewrite-rules` before 6a, with no LLM call. A rerun of the step changes nothing. The 6c burndown record counts results by their last rule. `report-payload` sends each rewrite's `source` and `rules`, and `rule_bugs`: rule-made rewrites that step 9, step 10, or a real 14c mismatch disproved. A 14c timeout or `unsupported_order` isn't one. The replay spec runs a rule-made rewrite end to end. The follow-ups went to 20261002-2.

### 20261001-25. 6c rule: `not_in_to_not_exists`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. The rule fires only on a top-level ANDed `x NOT IN (SELECT y ...)` or `NOT (x IN ...)`, with x and y plain qualified columns the catalog proves not null, neither on the nullable side of an outer join. The correlation is `x = y`. A subquery table that shadows the outer one gets a fresh alias. It refuses `<> ALL`, row-valued NOT IN, and set-operation or grouped subqueries. Three helpers moved into `Tree`. The follow-ups went to 20261002-3.

### 20261001-26. 6c rule: `distinct_join_to_exists`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. `SELECT DISTINCT` of one table's plain columns or its `*` over inner or cross joins becomes that table with one `EXISTS` holding every condition that reads the others, without the DISTINCT. It fires only when the select list holds a single-column key the catalog proves unique and not null; LIMIT or OFFSET only when the ORDER BY names that key. `Catalog#columns` lists a table's columns; `Tree.tables?` moved from `key_in_self_join`. The follow-ups went to 20261002-4.

### 20261001-24. 6c rule: `or_to_union`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after two reviews with no blocking findings. A top-level OR whose arms read different tables or subqueries becomes a UNION of one arm each, every arm selecting the columns the query uses plus a unique not-null key of each FROM table; the select list, aggregates, DISTINCT, ORDER BY, LIMIT and OFFSET read that UNION as a derived table, so duplicate join rows survive and `count(*)` stays right. It refuses GROUP BY, outer joins, composite keys, same-table ORs, and columns UNION can't compare. At landing its `Catalog#columns` merged with 20261001-26's (now `columns` and `column_names`) and the shared helper is `Tree.tables?`. The follow-ups went to 20261002-5.
