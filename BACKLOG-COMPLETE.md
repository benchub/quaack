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
