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
