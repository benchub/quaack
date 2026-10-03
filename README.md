<p align="center">
  <img src="docs/quaack-logo.jpg" alt="QUAACK: Query Upgrade Automation Assisted by Chaos and Knowledge" width="560">
</p>

# QUAACK

QUAACK is a pipeline that optimizes one Postgres query. You provide it the query and some information about the environment it ran in. QUAACK gives you back an HTML report: the indexes and rewrites that make it faster, which have been proven on a full-size copy of real data on real hardware, ranked by how much work those changes saved. And in the sad case when nothing helps, the report says why.

QUAACK has mechanical rules that propose both indexes and rewrites of the query, which need no LLM. Additionally, it uses an LLM to come up with crazy ideas that *just might work*. Of course, the LLM never sees your data. In fact, your data never leaves your production environment.

> **Status.** QUAACK is at version 1 and ready for its first real runs. Two rough edges you'll hit right away:
>
> - Between `quaack start` and `quaack run`, you run eleven setup commands by hand on the **jump server**. A single `quaack setup` command is on the backlog (task 20260928-1). The walkthrough below shows the manual steps.
> - QUAACK handles ordinary `SELECT` queries on plain tables. It refuses anything else. See [What QUAACK won't do](#what-quaack-wont-do).

**Contents:**
[Why QUAACK?](#why-quaack)
[How it works](#how-it-works)
[What you need](#what-you-need)
[One-time setup](#one-time-setup)
[Tuning a query](#tuning-a-query-a-walkthrough)
[More examples](#more-examples)
[Reading the report](#reading-the-report)
[When it fails](#when-a-run-fails)
[What QUAACK won't do](#what-quaack-wont-do)

## Why QUAACK?

When a query is slow, you usually do some combination of these things:

- **Use your brain.** Unlock that professional pride and try to be better than Postgres' online optimizer by applying your superior intellect (and/or contextual knowledge).
- **Ask an index advisor.** (Dexter, pganalyze's Index Advisor, or HypoPG by hand). It suggests indexes, based on what the planner *estimates* they'd cost.
- **Paste the query into an LLM chat.** You get clever rewrites, but you've just sent your query, possibly with its real constants, to a third party. And even then, that LLM doesn't have a good sense for the data distribution of your environment. *And* you don't have any reason to believe the query is actually *correct*.
- **Use an equivalence checker like QED.** You give it two queries, and it tries to *prove* they always return the same results. That's great, but it doesn't come up with the rewrite, nor does it say anything about speed.

QUAACK does all of that, **and** it checks its work. A few things set QUAACK apart:

**It measures, it doesn't estimate.** QUAACK builds the indexes and runs the queries on a restored copy of your real production data. It looks at blocks read, and counts a plan that reads more than 5% fewer blocks as a win over the status quo. It intentionally uses real data over synthetic data, as synthetic data can take a long time to build and provide a false optimization target.

**It tries to break every rewrite.** A faster query that returns different rows is useless. QUAACK builds small test tables aimed at each part of your `WHERE` clause, and asks the LLM for test data that would prove any rewrite candidate to be wrong. Then it compares the results on real production data too. This is testing, not proof, so it's weaker than QED's guarantee, but on the other hand, you don't have to supply the rewrite, and QED's conservative rules might discount perfectly fine rewrites.

**It doesn't overfit to one value.** A query that's slow for `account_id = 17` might be fine for most accounts. QUAACK utilizes PostgreSQL planner stats to test every rewrite candidate with three sets of literal values: the slow ones from your plan, a worst case, and a typical case. A candidate has to win on the slow values, and can't be worse on the others.

**QUAACK was written with PII safety in mind.** Your literals, your rows, and the values in your statistics stay inside the production network. The LLM sees table and column names, types, indexes, plans with the values taken out, and summary numbers like "71% of rows share one value". The code enforces this. It isn't a convention people have to remember.

**It says so when nothing helps.** If no candidate wins, a details report explains which rewrites were disproved, which indexes the planner ignored, and which ones you already have.

## How it works.

QUAACK comes in two halves, because PII is important.

```mermaid
flowchart TB
    %% Define custom styles
    classDef workstation fill:#f4f9ff,stroke:#0055a4,stroke-width:2px,rx:5,ry:5
    classDef network fill:#fff8f0,stroke:#d84315,stroke-width:2px,rx:5,ry:5,stroke-dasharray: 5 5
    classDef server fill:#ffffff,stroke:#757575,stroke-width:1px,rx:5,ry:5
    
    %% Updated label style: added a stroke (border) and a white background
    classDef labelNode fill:#ffffff,stroke:#555,stroke-width:1px,rx:5,ry:5,color:#333

    subgraph laptop["💻 Your workstation"]
        quaack["<b>quaack</b><br/>(orchestrates, talks to the LLM, writes the report)"]
        llm{{"LLM portal"}}
        
        %% The label node will now render with a visible border inside the workstation
        edge_lbl["SSH pipeline<br/>---<br/>passes commands and redacted information"]:::labelNode
        
        quaack <--> llm
        
        %% Lengthened bidirectional arrow to push the label to the right
        quaack <--> edge_lbl
    end
    class laptop workstation

    subgraph enclave["🔒 Production network"]
        subgraph jump["Jump server"]
            quaacks["<b>quaacks</b><br/>(does all the database work)"]
            store@{ shape: docs, label: "state files" }

            quaacks <--> store
        end
        class jump server
        
        prod[("Production<br/>(read only)")]
        
        subgraph runsrv["Run server, built once per run"]
            racetrack[("Racetrack:<br/>restore of production for performance testing")]
            arena[("Arena:<br/>empty tables for correctness testing")]
        end
        class runsrv server
    end
    class enclave network

    %% Connect the label node outward to the jump server
    edge_lbl <--> quaacks
    
    prod ---> quaacks
    quaacks ---> racetrack
    quaacks ---> arena
```

- **`quaack`**, on your laptop, runs each step in order and makes every LLM call. It never holds a production value.
- **`quaacks`** (the "s" is for "server"), on the jump server, does everything that touches a database. It has no memory between calls. It keeps its working state files in `~/.quaack/runs/<run ID>/` on the jump server, and everything it prints passes through one filter that only lets out things on an allowlist.
- **The racetrack** is a full restore of production. QUAACK measures there, because only real data has production's real layout on disk.
- **The arena** is an empty copy of the schema for correctness testing. QUAACK loads small test tables into it, always inside a transaction that it rolls back.

### QUAACK's pipeline

1. **Collect.** Read the schema, planner statistics, and settings from production (read only). Take the literal values out of the query and the plan, so that the LLM only sees `$1`, `$2`, and so on. Make a note of which columns look like personal data, so that even their statistics stay back.
2. **Check the copy.** Plan the query on the racetrack. If the plan doesn't match production's, stop. Tuning against a copy that behaves differently is a waste of time.
3. **Propose indexes.** Two rule-based generators read the query and the plan. Then an LLM makes its own suggestions, which might include things the mechanical generators don't know how to work with: partial indexes, expression indexes, BRIN, and operator classes. Each idea is tried with HypoPG, as a hypothetical index, which is free. Ideas the planner won't use are dropped. The LLM sees how its ideas did, and gets one chance to fix things that didn't pan out.
4. **Propose rewrites.** First, QUAACK's own rewrite rules read the query. Each rule is a change that can't alter the result, given facts the schema states, such as a key being unique, and that Postgres's planner doesn't always make for itself. A rule only fires when the schema proves those facts. Then the LLM suggests rewrites, and remarks what each suggestion assumes, such as "this column is never NULL". QUAACK checks those claims against the schema, for the rules' rewrites and the LLM's alike. You can add your own rewrites from your big brain too. Each rewrite gets its own index search, since a rewrite may want different indexes.
5. **Try to break the rewrites.** Build test data in the arena aimed at every condition in the query: rows that just match, rows that just miss, NULLs, duplicates, orphans, and empty tables. Then ask the LLM up to three times for data that would provide different answers from the original query and the rewrite candidate. Any difference kills the rewrite.
6. **Measure.** Build the surviving indexes for real on the racetrack, hidden from the planner except when being measured. Run the original and every query candidate with each of the three value sets, three times each, and count the blocks they hit.
7. **Recheck for accuracy on real data.** Run the winners once more, this time comparing the actual rows returned against the original query on full production data. The previous accuracy checks were against small sets of carefully chosen synthetic data.
8. **Report.** Rank the winners, explain them, and show where every idea dropped out.
9. **Clean up.** Delete the run's files on the jump server, and destroy the run server if you've told QUAACK how.

### What to expect.

- **A run takes minutes to hours.** Most of that is building real indexes and running your slow query many times on the racetrack. A query that takes a minute will be run dozens of times.

  Depending upon your environment, restoring and analyzing production data might add more hours to this time.
- **"Faster" means fewer blocks read, not fewer milliseconds.** Blocks are stable and comparable. Timing isn't. Fewer blocks almost always means faster, and it always means less pressure on the cache.
- **Rewrites are tested hard, not proven.** QUAACK checks each rewrite several different ways, but a test can still miss a case. Read a winning rewrite before you ship it. The report lists any condition in your query that the tests never managed to exercise.
- **A partial index only helps if your app sends a constant.** If a winning index has a `WHERE` clause, check that your app writes that value into the SQL. If the app sends it as a bind parameter, a generic plan can't use the partial index.
- **QUAACK never changes production.** It reads production inside read-only transactions. Everything it builds, it builds on the run server. Applying a fix is up to you.

## What you need

**On your laptop:**

- A checkout of this repo and Ruby 3.4. On a Mac with Homebrew, `ruby@3.4` is keg-only, so put it first on `PATH`: `export PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH`.
- Access to an LLM: Claude through the Anthropic API (an API key, or a login with the `ant` command-line tool), Claude on AWS Bedrock (your AWS credentials), or any OpenAI-compatible API, such as OpenAI, Groq, Gemini, OpenRouter, or a local Ollama. See [Give the driver access to an LLM](#3-give-the-driver-access-to-an-llm).
- ssh access to the production jump server, without a password prompt (i.e. use keys or an agent).

**On the jump server:**

- Ruby 3.4, `gem`, `gcc`, and `make` in your `$PATH`. `quaack deploy` will compile the pg_query gem there.
- `pg_dump`, at least as new as production's Postgres.
- A libpq setup that connects to production and to the run server as you: `~/.pgpass`, a service in `~/.pg_service.conf`, or `PG*` environment variables. QUAACK stores no passwords.
- A POSIX login shell (bash, sh, or zsh).

**Production:** Postgres 17 or later.

**A run server,** one per run, that you build:

- The same Postgres major version and extensions as production, plus [HypoPG](https://github.com/HypoPG/hypopg) built and available for `CREATE EXTENSION`.
- A **racetrack database** restored from a production backup that shows the query performing the same way.
- The same planner and locale settings as production. QUAACK checks every one and refuses a mismatch.
- A superuser login for you, autovacuum off, and nothing else connected.
- A name for the **arena database.** QUAACK will create it, drop it, and recreate it on a rerun, but you need to provide the name. It refuses to touch an existing database of that name that it didn't create.

## One-time setup.

### 1. Install the driver on your laptop.

```sh
git clone https://github.com/benchub/quaack.git
cd quaack
bundle install
bundle exec quaack --version
```

Run `quaack` from the checkout with `bundle exec`. The rest of this README just writes `quaack`.

### 2. Tell the driver how to find your jump server.

Create `~/.quaack/driver.json`:

```json
{ "jump_command": "echo jump1.prod.example.com" }
```

`jump_command` is a shell command that prints the ssh host of the jump server for a production server. `{server}` in the command becomes the server name you pass to `quaack start`. With one jump server, a plain `echo` is enough. With several, map the server to a host:

```json
{ "jump_command": "case {server} in eu-*) echo jump-eu ;; *) echo jump-us ;; esac" }
```

### 3. Give the driver access to an LLM.

The driver makes every LLM call from your laptop. By default it asks Claude, and finds Anthropic credentials the way Anthropic's own tools do, taking the first of these that's set:

1. An API key in `ANTHROPIC_API_KEY`.
2. A bearer token in `ANTHROPIC_AUTH_TOKEN`.
3. A profile, such as the one `ant auth login` saves under `~/.config/anthropic`. `ANTHROPIC_PROFILE` picks a profile other than the active one.

If you're already logged in with `ant`, there's nothing to do. With none of them, `quaack run` fails with `llm_auth` before it touches the jump server. So does an empty `ANTHROPIC_API_KEY`. An empty `ANTHROPIC_AUTH_TOKEN` fails too when `ANTHROPIC_API_KEY` is unset. The first of the two that's set hides everything after it, even when it's empty. Unset the empty one instead.

To change the model, the provider, or where the key comes from, add an `llm` block to `~/.quaack/driver.json`. Every key is optional:

```json
{
  "jump_command": "echo jump1.prod.example.com",
  "llm": {
    "provider": "anthropic",
    "model": "claude-opus-5-5",
    "base_url": "https://llm-gateway.example.com",
    "api_key_env": "QUAACK_ANTHROPIC_KEY"
  }
}
```

| Key | What it does | Default |
| --- | --- | --- |
| `provider` | Which API to call: `anthropic`, `openai_compatible` for OpenAI, Groq, Gemini, OpenRouter, Ollama, and any other server that speaks OpenAI's Chat Completions API, `bedrock` for Claude on AWS Bedrock, or `copilot_cli` for a local Copilot CLI command. | `anthropic` |
| `model` | The model to ask. Required for `openai_compatible` and `bedrock`. | `claude-opus-5-5` for `anthropic`; `claude-opus-5.5` for `copilot_cli` |
| `base_url` | Where to send requests, such as a gateway, or which OpenAI-compatible provider. An `http` or `https` URL. Not for `copilot_cli`. | The provider's own, or `ANTHROPIC_BASE_URL` or `OPENAI_BASE_URL` |
| `api_key_env` | The name of an environment variable that holds the key. When it's set, the driver uses only that variable, and fails with `llm_auth` if it's empty. Only for `anthropic` and `openai_compatible`. | The lookup above for `anthropic`, `OPENAI_API_KEY` for `openai_compatible` |
| `aws_region` | For `bedrock` only: the AWS region to call, such as `us-east-1`. | `AWS_REGION`, `AWS_DEFAULT_REGION`, or your AWS profile's region |
| `aws_profile` | For `bedrock` only: the AWS profile, in `~/.aws`, whose credentials to use. | The AWS SDK's usual lookup |
| `command_template` | For `copilot_cli` only: an argv array, run without a shell, with `{prompt_file}` and `{model}` placeholders. `{prompt_dir}` is also available. | A locked-down `copilot` prompt-mode command |
| `timeout_seconds` | For `copilot_cli` only: a positive number of seconds for each command run. | `600` |

Never put a key itself in the file. These environment variables override the file for one run: `QUAACK_MODEL` for `model`, `QUAACK_LLM_PROVIDER` for `provider`, and `QUAACK_LLM_BASE_URL` for `base_url`. An empty one counts as unset. A bad value, in the file or a variable, makes `quaack run` exit with 64 and a message that names the offending key or variable.

#### OpenAI-compatible providers.

With `"provider": "openai_compatible"`, the driver talks to OpenAI's Chat Completions API, through the official `openai` gem, at `base_url`. It sends the key from the variable `api_key_env` names, or from `OPENAI_API_KEY` when it names none, as a bearer token. If that variable is unset or empty, `quaack run` fails with `llm_auth` before it makes any call. Give a `model` too: there's no default.

| Provider | `base_url` | `api_key_env` | `model`, for example |
| --- | --- | --- | --- |
| OpenAI | leave it out | leave it out (`OPENAI_API_KEY`) | `gpt-5` |
| Groq | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` | `llama-3.3-70b-versatile` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `GEMINI_API_KEY` | `gemini-2.5-pro` |
| OpenRouter | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | `anthropic/claude-opus-4.1` |
| Ollama, on your laptop | `http://localhost:11434/v1` | `OLLAMA_API_KEY` | `qwen2.5-coder:32b` |

For example, for Groq:

```json
{
  "jump_command": "echo jump1.prod.example.com",
  "llm": {
    "provider": "openai_compatible",
    "base_url": "https://api.groq.com/openai/v1",
    "api_key_env": "GROQ_API_KEY",
    "model": "llama-3.3-70b-versatile"
  }
}
```

then `export GROQ_API_KEY=...` before `quaack run`. Ollama needs no key, but the driver still wants one, so set the variable to anything, such as `export OLLAMA_API_KEY=ollama`.

The models are examples. Use one your account can call, and **make it a strong model**: QUAACK asks for careful SQL work, and a small model is mostly a waste of time and tokens.

**Structured output.** At several steps, QUAACK asks for JSON in a fixed shape, and checks every reply. A reply in the wrong shape gets one more try. If the model gets it wrong twice, the run stops with `llm_bad_response`. Strong models rarely do.

> **Privacy: other OpenAI settings go to every provider.** The `openai` gem reads `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, and `OPENAI_CUSTOM_HEADERS`, and sends what they hold to whatever `base_url` you use, not just to OpenAI. So a custom header carrying a secret, or your OpenAI organization and project IDs, would reach Groq, Gemini, or whichever provider you point QUAACK at. Unset those variables before `quaack run` unless your provider is OpenAI.

#### AWS Bedrock.

With `"provider": "bedrock"`, the driver asks Claude on AWS Bedrock, through the `anthropic` gem's Bedrock client, which calls Bedrock's InvokeModel API and signs each request with your AWS credentials. QUAACK stores no credentials. It finds them the way the AWS CLI and SDKs do:

1. A Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK`, if it's set. It's sent as a bearer token, and nothing below is looked at.
2. The profile `aws_profile` names, from `~/.aws/config` and `~/.aws/credentials`: static keys, SSO (run `aws sso login` first), an assumed role, or a `credential_process`.
3. Otherwise the AWS SDK's own chain: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (with `AWS_SESSION_TOKEN` for temporary ones), the profile `AWS_PROFILE` names or the default one, then a container or EC2 instance role.

Finding none, a profile that can't be loaded, or an empty `AWS_BEARER_TOKEN_BEDROCK` makes `quaack run` fail with `llm_auth` before it touches the jump server. So does a Bedrock API key with `aws_profile` set, since they name different credentials: it's a usage error, exit 64. The credentials are read once, when the run starts, so an SSO session that expires partway through fails that run with `llm_auth`. Log in again, and start a new run.

Give a `model`, since there's no default: Bedrock's model IDs vary by region and by inference profile. Use the ID the Bedrock console shows for your region, such as `anthropic.claude-opus-5-5`, or a cross-region inference profile such as `us.anthropic.claude-opus-5-5`. With no region anywhere, `quaack run` exits with 64. `base_url` is for a private endpoint, and a Bedrock API key needs no region when there's a `base_url`.

```json
{
  "jump_command": "echo jump1.prod.example.com",
  "llm": {
    "provider": "bedrock",
    "model": "us.anthropic.claude-opus-5-5",
    "aws_region": "us-east-1",
    "aws_profile": "bedrock"
  }
}
```

Your AWS identity needs `bedrock:InvokeModel` on the model, and your account needs access to the model in that region. If AWS refuses either, the run fails with `llm_auth`.

#### GitHub Copilot CLI.

With `"provider": "copilot_cli"`, the driver runs a local command once for each LLM ask and reads the answer from stdout. The default command runs `copilot` from `PATH` in prompt mode with `--model`, `-p`, and `-s`, and writes the QUAACK prompt to a private 0600 file in an otherwise empty temporary current directory. That directory is removed after the ask.

The default command locks Copilot down with `--disable-builtin-mcps`, `--no-ask-user`, `--no-custom-instructions`, `--disallow-temp-dir`, `--available-tools=view`, `--allow-tool=read({prompt_dir})`, and denials for shell, write, and URL tools. The prompt file is inside `{prompt_dir}`, which is also the command's current directory, so Copilot can still read that file through the explicit `read({prompt_dir})` allowance. The child process also unsets `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`.

> **Danger: global Copilot instructions can break QUAACK replies.** QUAACK often needs bare JSON. Global custom instructions can change the reply's format, such as pushing prose or code fences around the JSON. That will usually end the run with `llm_bad_response`, and could be worse if it changes the model's behavior in a subtler way. The default command passes `--no-custom-instructions`, and the Copilot CLI command reference says that flag disables `AGENTS.md` and related files and always takes priority. The docs do **not** explicitly say whether it covers user-level `~/.copilot/copilot-instructions.md` and `~/.copilot/instructions/**`, so the flag may or may not be enough. Keep global instructions out of the way for QUAACK, or run a canary that proves they don't reach this provider before relying on it for production runs.

```json
{
  "jump_command": "echo jump1.prod.example.com",
  "llm": {
    "provider": "copilot_cli",
    "timeout_seconds": 900
  }
}
```

To use another wrapper, set `command_template` as an argv array. It must include `{prompt_file}` and `{model}`:

```json
{
  "llm": {
    "provider": "copilot_cli",
    "command_template": ["/usr/local/bin/copilot", "--model={model}", "-s", "-p", "Please follow my prompt in {prompt_file}"],
    "timeout_seconds": 600
  }
}
```

The CLI cannot enforce JSON schemas itself, so QUAACK includes the schema in the prompt file and checks the answer. A missing command, timeout, or non-zero exit is `llm_unavailable`; a distinctive not-logged-in message is `llm_auth`; empty stdout is `llm_bad_response`.


### 4. Install the enclave script on the jump server.

```sh
quaack deploy --host jump1.prod.example.com
# quaack deploy: building quaack-protocol-0.1.0.gem
# quaack deploy: building quaacks-0.1.0.gem
# quaack deploy: copying quaack-protocol-0.1.0.gem to jump1.prod.example.com
# quaack deploy: copying quaacks-0.1.0.gem to jump1.prod.example.com
# quaack deploy: running gem install on jump1.prod.example.com. It builds pg_query from source, which can take a few minutes.
# quaack deploy: checking quaacks on jump1.prod.example.com
# quaack deploy: installed quaacks 0.1.0 on jump1.prod.example.com
```

This builds the `quaacks` gems from your checkout, copies them over ssh, and installs them into your own gem directory on the jump server. It doesn't use sudo to install them for everybody. **Never run QUAACK from a git checkout on the jump server, because the repo's bundle includes the LLM half. To keep from leaking data, `quaacks` refuses to run if it finds that half beside it.**

The driver runs `quaacks` over non-interactive ssh, so your user gem `bin` directory must be in your `$PATH` for non-interactive shells. On the jump server, `ruby -e 'puts Gem.user_dir'` prints the gem directory: `~/.gem/ruby/3.4.0` if you have a `~/.gem`, and otherwise `~/.local/share/gem/ruby/3.4.0`. Add its `/bin` to `PATH` in `~/.bashrc`, above any line that returns early for non-interactive shells, or in `~/.zshenv`.

If `quaacks` isn't on that `PATH`, `quaack deploy` looks into why, without changing anything on the jump server, and tells you what to change. For bash, that looks like this:

```
quaack deploy failed: installed quaacks 0.1.0 on jump1.prod.example.com, but quaacks isn't installed on jump1.prod.example.com, or isn't on PATH for non-interactive ssh there.
jump1.prod.example.com's login shell is bash, and /home/you/.local/share/gem/ruby/3.4.0/bin, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to ~/.bashrc on jump1.prod.example.com, above any line that returns early for non-interactive shells:
  export PATH="/home/you/.local/share/gem/ruby/3.4.0/bin:$PATH"
Check with: ssh jump1.prod.example.com quaacks --version
```

It also tells you if `ruby` itself isn't on that `PATH`, if another `quaacks` or another Ruby comes first, or if your login shell is fish or csh, which QUAACK doesn't support. Then check from your laptop:

```sh
ssh jump1.prod.example.com quaacks --version
```
#### Upgrading
Re-run `quaack deploy` whenever you update your checkout. `quaack start` and `quaack run` refuse to talk to an out-of-date `quaacks`, and tell you to deploy.

### 5. Configure the jump server (optional, but recommended).

`~/.quaack/config.json` on the jump server holds anything the enclave needs to know. Every key is optional.

```json
{
  "memory_command": "aws rds describe-db-instances --db-instance-identifier {host} --query 'DBInstances[0].DBInstanceClass' --output text | ./instance-class-to-bytes",
  "run_server_command": "/opt/dba/make-quaack-run-server {server} {run}",
  "destroy_command": "/opt/dba/destroy-quaack-run-server {run}",
  "pii_columns": ["*.users.email", "*.users.*name", "billing.*.card_*"],
  "cardinality_threshold": 50
}
```

| Key | What it does | Without it |
| --- | --- | --- |
| `memory_command` | Prints production's instance memory, such as `64GB`. `{host}` is production's host. | Memory is recorded as unknown. |
| `run_server_command` | Builds or finds the run server, and prints `{"host": ..., "port": ..., "racetrack_db": ..., "arena_db": ...}`. `{server}` is the production server name and `{run}` the run ID. It gets an hour. | You pass the run server as flags to `quaacks run-server`. |
| `destroy_command` | Destroys the run server at the end of a run. It must succeed if the server is already gone. | QUAACK reminds you to destroy it yourself. |
| `pii_columns` | `schema.table.column` patterns for columns that hold personal data. `*` matches within one part. Case is ignored. | Only the automatic rule applies: any text column with 50 or more distinct values counts as personal data. |
| `cardinality_threshold` | Moves that line of 50. | 50. |

Personal-data columns never have their common values or how often those values appear sent to the LLM. Only columns with fewer distinct values than the threshold, like `status` or `country`, ever have their values sent.

## Tuning a query: a walkthrough.

Say this query is slow on `prod-db-1`:

```sql
SELECT id, kind, created_at
FROM public.events
WHERE account_id = 17
  AND created_at >= '2025-06-01 00:00:00+00'
  AND created_at < '2025-06-08 00:00:00+00'
ORDER BY created_at, id;
```

`events` has 500,000 rows, and only `account_id` has an index. The index finds the account's 500 events, then a filter throws away all but about 10 of them.

### Step 1. Save the query and its plan on the jump server.

Both files hold real values, so they stay on the jump server. ssh in and save the query as `~/slow/events.sql`. Then capture its plan from production:

```sh
ssh jump1.prod.example.com
mkdir -p ~/slow && cd ~/slow
# save the query as events.sql, then:
( echo 'EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)'; cat events.sql ) \
  | psql -h prod-db-1 -XAtq -o events-plan.json
```

`EXPLAIN ANALYZE` really runs the query, so this takes as long as the query does. Capture the plan with the same settings the app uses. If the app sets `work_mem` or `search_path`, set them in the same session first. `SETTINGS` records them, and QUAACK uses them.

### Step 2. Start the run from your laptop.

```sh
quaack start --server prod-db-1 --query slow/events.sql --plan slow/events-plan.json
# 20260928T201702Z-3f9a1c2e
```

The paths are on the jump server. A relative path starts from your home directory there, so `slow/events.sql` means the jump server's `~/slow/events.sql`. Don't write `~/slow/...`: your laptop's shell turns `~` into your laptop's home directory before `quaack` sees it. QUAACK checks both files, starts a run, and prints the **run ID**. Every later command takes it.

QUAACK runs every candidate as if `now()` and `current_date` were the moment you ran `quaack start`. If your query uses them, start the run soon after you capture the plan. (`quaacks intake` takes a `--captured-at` time, but `quaack start` can't pass it through yet. That's backlog task 20260928-2.)

### Step 3. Set up the run on the jump server.

Until `quaack setup` exists, run these on the jump server, in this order. Each prints a line when it finishes, and stops with a rule name if it can't go on.

```sh
RUN=20260928T201702Z-3f9a1c2e

quaacks inventory --run $RUN        # production's version, settings, and memory

# With run_server_command in your config:
quaacks run-server --run $RUN
# ...or, name the run server yourself:
quaacks run-server --run $RUN --host runsrv-7.prod.example.com --port 5432 \
  --racetrack-db racetrack --arena-db quaack_arena

for step in qualify schema-dump statistics volatility classify redact literals anchor racetrack-setup; do
  quaacks $step --run $RUN || break
done
```

What each one does:

| Command | What it does |
| --- | --- |
| `inventory` | Reads production's version, extensions, settings, and locale. |
| `run-server` | Checks that the run server matches production: version, extensions, settings, locale, superuser, and quiet. |
| `qualify` | Adds the schema to every table name, and refuses views, partitioned tables, and the like. |
| `schema-dump` | Dumps the schema of the tables the query touches. |
| `statistics` | Reads planner statistics and existing indexes for the query's tables. |
| `volatility` | Refuses the query if it calls a function with side effects, such as `random()`. |
| `classify` | Decides which columns hold personal data, and which statistics may go to the LLM. |
| `redact` | Swaps every literal for `$1`, `$2`, and so on. |
| `literals` | Picks the worst-case and typical values to test with, alongside the slow ones. |
| `anchor` | Pins `now()` and friends to the time the plan was captured. |
| `racetrack-setup` | Installs HypoPG and QUAACK's clock function on the racetrack. |

### Step 4. Run it.

Back on your laptop, with access to an LLM set up (see [setup step 3](#3-give-the-driver-access-to-an-llm)):

```sh
quaack run --run 20260928T201702Z-3f9a1c2e --keep
# ./quaack-20260928T201702Z-3f9a1c2e.html
# 20260928T201702Z-3f9a1c2e done
```

It prints the report's path, then `<run ID> done`. Open the HTML file in a browser.

While it runs, it shows its progress on stderr: a line as each step starts and ends, such as `quaack: [6/18] Asking the LLM for rewrites of the query (6a)` and `quaack: [6/18] Done in 42s (6a)`, a line for each step a resumed run skips, and a line for each LLM ask and retry. A step that runs past 30 seconds prints `Still working` with its time every 30 seconds. The lines carry only step names, counts, and timings.

`--keep` skips the cleanup at the end, so you can re-run or look around, and QUAACK prints the teardown command to use later. It's a good idea on your first few runs. Without it, QUAACK deletes the run's files when the run ends, whether it succeeded or failed, and destroys the run server if you set `destroy_command`.

For this query, the report's top answer is one index:

```sql
CREATE INDEX ON public.events (account_id, created_at) INCLUDE (kind);
```

It cuts the slow values from about 509 blocks to single digits, and it's no worse for the other values. See [Reading the report](#reading-the-report) for how that looks.

### Step 5. Clean up.

If you used `--keep`, tear the run down when you're done:

```sh
ssh jump1.prod.example.com quaacks teardown --run 20260928T201702Z-3f9a1c2e
```

That deletes the run's files on the jump server, and runs `destroy_command` if you set one. Otherwise, destroy the run server yourself. Every copy of production data from the run lives in one of those two places.

## More examples.

### Put the report somewhere else.

```sh
quaack run --run $RUN --out ~/reports/events-slow-week.html
```

### Test your own rewrite.

You may already have an idea. Write it with the same `$1`, `$2` placeholders QUAACK uses, since your laptop never sees the real values. To see the redacted query and learn which number is which, ask the jump server:

```sh
ssh jump1.prod.example.com quaacks rewrite-payload --run $RUN \
  | jq -r 'select(.type == "rewrite_payload") | .query'
# SELECT id, kind, created_at FROM public.events WHERE account_id = $1
#   AND created_at >= $2 AND created_at < $3 ORDER BY created_at, id
```

That output holds shapes only, so it's safe on your laptop. Put one or more rewrites in a file, each ending in `;`:

```sql
-- my-rewrites.sql
SELECT id, kind, created_at
FROM public.events
WHERE account_id = $1
  AND created_at >= $2 AND created_at < $3
ORDER BY created_at, id
LIMIT 1000;

WITH mine AS MATERIALIZED (
  SELECT id, kind, created_at FROM public.events WHERE account_id = $1
)
SELECT id, kind, created_at
FROM mine
WHERE created_at >= $2 AND created_at < $3
ORDER BY created_at, id;
```

```sh
quaack run --run $RUN --rewrites my-rewrites.sql --keep
```

Your rewrites go through the same tests as the LLM's. Above, the first rewrite adds a `LIMIT` the original doesn't have, so QUAACK will prove it wrong. The second returns the same rows, but still reads all 500 of the account's rows, so it won't beat the new index and won't be ranked. There's one difference: if the LLM thinks your rewrite relies on something the schema doesn't guarantee, you get a warning in the report instead of a rejection, since you may know something the schema doesn't.

QUAACK reads and parses the file before it contacts the jump server, so a typo fails straight away.

### Resume after a failure.

With `--keep`, a failed run leaves its work behind. Fix the problem and run the same command again. QUAACK skips every step whose output it already has.

```sh
quaack run --run $RUN --keep
# quaack run failed: run_server_connection_failed
# ... fix the network ...
quaack run --run $RUN --keep
```

### Use a different model.

The driver uses `claude-opus-5-5` by default. Set `model` in the `llm` block of `~/.quaack/driver.json` (see [setup step 3](#3-give-the-driver-access-to-an-llm)) to change it for good, or `QUAACK_MODEL` for one run:

```sh
QUAACK_MODEL=claude-sonnet-5-5 quaack run --run $RUN
```

### Two runs at once.

Each run has its own ID, its own files, and its own run server, so separate queries don't get in each other's way. Start each with `quaack start`, and run each with its own ID.

## Reading the report.

The report is one HTML file with these sections, in order. The example below is shortened, and its numbers are illustrative, from the walkthrough's query.

### Overall ranking.

| # | Candidate | Slow blocks | Sum across literals | Index footprint |
| --- | --- | ---: | ---: | ---: |
| 1 | `original:top:1` | 4 | 20 | 15,112 kB |
| 2 | `original:top:2` | 19 | 83 | 11,776 kB |
| 3 | `original:combination` | 4 | 20 | 26,888 kB |

The winner is first. Each **candidate** is your query, or a rewrite, with a set of new indexes:

| Label | Means |
| --- | --- |
| `original` | Your query, unchanged, with no new indexes. This is the baseline. |
| `original:top:1` | Your query with the best new index, or indexes, QUAACK found for it. `:top:2` and `:top:3` are the runners-up. |
| `original:combination` | Your query with the top indexes together, when using them together beat using any one. |
| `rewrite_2` | The second rewrite, with no new indexes. |
| `rewrite_2:top:1` | The second rewrite with its own best indexes. |

- **Slow blocks:** blocks read with the values from your slow plan. This is the number you most want down.
- **Sum across literals:** blocks read, added up over the slow, worst-case, and typical values.
- **Index footprint:** disk space for the candidate's new indexes. When two candidates tie on blocks, the smaller footprint wins.

Only candidates that pass the **minimax rule** are ranked. A candidate must be *better* on the slow values, meaning more than 5% fewer blocks, and *no worse* on every other value set, meaning no more than 5% more blocks. The report lists any candidate that was excluded, and why.

### Why the winner reads fewer blocks.

> `original:top:1` reads 4 blocks on the slow literal set, against 509 for the original (99% fewer).
>
> Original plan: Sort (10 rows) › Index Scan on public.events using events_account_id_idx (500 rows, selectivity 0.1%)
>
> Winner's plan: Index Only Scan on public.events using quaack_5d1e07b2 (10 rows, selectivity 0.0%)

This part is generated from the measurements and plans, not written by the LLM. Compare the two plans. Here, the old plan read 500 rows to keep 10, one heap page each. The new index finds exactly the 10 rows, in order, and never visits the table.

### One section per candidate.

**`original:top:1`**

```sql
SELECT id, kind, created_at FROM public.events WHERE account_id = $1
  AND created_at >= $2 AND created_at < $3 ORDER BY created_at, id
```

| Literal set | Blocks | Hit | Read | Verdict | Stability |
| --- | ---: | ---: | ---: | --- | --- |
| slow | 4 | 4 | 0 | better | |
| worst_case | 12 | 9 | 3 | better | |
| typical | 4 | 4 | 0 | better | |

Indexes: `quaack_5d1e07b2`

- **Literal sets:** `slow` is the values from your plan. `worst_case` uses the most common values from the statistics, which match the most rows. `typical` uses middle-of-the-road values.
- **Blocks** is the total. **Hit** and **Read** split it by whether the block was already in memory. Blocks matter most. Hit and Read show whether a win saves disk reads or just saves work in memory.
- **Verdict** is `better`, `no_worse`, or `worse`, against the original on the same values.
- **Stability** says `unstable` if the block count moved between the three runs. That usually means the plan changed between runs, so be wary of that row.
- **Source,** on a rewrite, says where it came from: `made by QUAACK's rule key_in_self_join` for one of QUAACK's own rewrite rules (two rules applied in a row are both named, in order), `proposed by the LLM`, or `your own rewrite`. Every rewrite goes through the same tests, whatever its source.
- **Untested atoms,** when listed, are conditions in the `WHERE` clause that the test data never managed to exercise, such as `o.status = $1`. A rewrite that changed such a condition wasn't really checked there. Read those rewrites extra carefully.

A rewrite's SQL uses the same placeholders as the redacted query. Put your real values or bind parameters back in the same spots.

### QUAACK bug: a rule made a wrong rewrite.

You should never see this section. It appears at the very top of the report, above the ranking, when a test proved one of the rules' own rewrites wrong, such as "rewrite_1, made by QUAACK's rule key_in_self_join, was disproved in step 9". QUAACK's rules are meant to be sound, so that's a bug in the rule, not a finding about your query. The tests did their job: the rewrite was dropped, and the rest of the report still holds. Please report it, with the names of the rules.

Only a test that found different results counts. A rule's rewrite that timed out in the final check on production data isn't listed here: a timeout means the rewrite was too slow there, not that it's wrong. A rewrite that was only dropped for planning the same way as the original isn't listed here either. That happens when Postgres already makes the rule's change by itself, and it says nothing about whether the rule is right.

### Proposed indexes.

| Name | DDL | Built size | Existing index covering it | Existing indexes it makes redundant |
| --- | --- | ---: | --- | --- |
| `quaack_5d1e07b2` | `CREATE INDEX ON public.events (account_id, created_at) INCLUDE (kind)` | 15,112 kB | | `events_account_id_idx` |
| `quaack_9b20c4aa` | `CREATE INDEX ON public.events (account_id, created_at)` | 11,776 kB | | `events_account_id_idx` |

The **built size** is real: QUAACK built the index on the racetrack. **Makes redundant** lists your existing indexes that the new one covers, which you could drop after checking that nothing else needs them.

To ship an index, build it on production yourself, usually with `CREATE INDEX CONCURRENTLY`, and give it a proper name. The `quaack_` name is only for the run.

### Why nothing beat the original.

This section appears only when no candidate won. It lists:

- **Rewrites disproved,** and what disproved them, such as "rewrite_1: disproved in step 9 by scenario S2". Scenarios are kinds of test data: `S0` empty tables, `S1` rows that just match and just miss, `S2` NULLs, `S3` duplicate join keys, `S4` rows with no join partner, `S5` extreme values, `S6` groups of one, many, and none. A rewrite disproved in step 10 was caught by LLM-written test data. Each rewrite is listed with its source.
- **Indexes the planner declined,** because it never chose them, even hypothetically.
- **Proposed indexes that already existed,** and which existing index covers each. If QUAACK's best idea is an index you already have, the query isn't slow for lack of an index.
- **Rewrites that passed the tests but lost,** because they weren't enough faster, tied with something smaller, or returned different results on production data.

"Nothing helps" is a real answer. It often means the query is already as good as its indexes allow, and the fix is in the app: fetch less, or cache it.

### Burndown.

The last section shows how much work QUAACK did and where ideas dropped out. It has a table for index ideas and one for rewrites. For each stage, it shows how many ideas came in, how many were added, how many were dropped and why, and how many went on. The rewrite table's first row, `6c`, is QUAACK's own rewrite rules: how many rewrites each rule made, and how many were dropped as a duplicate of another, as over the limit of five, or for failing the schema checks. After those comes a list of totals: LLM calls, hypothetical plans, real indexes built, measurement runs, and test data loads.

Read it when the result surprises you. If the LLM proposed five rewrites and all five failed the schema checks, the problem is different than if all five were disproved by NULLs.

## When a run fails.

QUAACK prints `quaack start failed: <rule>` or `quaack run failed: <rule>`, and exits with status 1. When an LLM call fails, `quaack run` adds the provider's error after the rule, as in `quaack run failed: llm_bad_request: <detail>`. The detail comes from the LLM provider, outside the privacy line. A usage mistake, such as an unknown run ID, an unreadable rewrites file, or a bad `llm` block in `~/.quaack/driver.json`, exits with 64. Messages name a **rule**, never a value, host, or password. That's deliberate: error messages cross the privacy line too.

Common rules:

| Rule | What it means | What to do |
| --- | --- | --- |
| `unsupported_construct` | The query uses SQL QUAACK doesn't handle yet. | See [What QUAACK won't do](#what-quaack-wont-do). |
| `view_relation`, `inheritance_parent`, and other `..._relation` rules | The query reads something other than a plain table. | Not supported in v1. |
| `volatile_function` | The query calls a function with side effects, such as `random()` or `nextval()`. | Not supported. Results couldn't be compared. |
| `plan_gate_mismatch_likely_stale_statistics` | The racetrack plans the query differently from production. | Usually the restore is older than production's latest `ANALYZE`. Restore a newer backup, then start a new run. |
| `run_server_guc_mismatch`, `run_server_...` | The run server doesn't match production, or isn't quiet. | Fix the run server's settings, or stop whatever else is connected. |
| `production_connection_failed` | `quaacks` couldn't connect to production. | Check your libpq setup on the jump server: `psql -h <server>` should just work. |
| `pg_dump_too_old` | The jump server's `pg_dump` is older than production. | Install a newer client. |
| `llm_auth` | The driver found no Anthropic credentials, the variable `api_key_env` names (or `OPENAI_API_KEY`, for `openai_compatible`) is unset or empty, a profile couldn't be read, the AWS credential chain found nothing (for `bedrock`), or the API refused the credentials. | Set the key's variable, or for Anthropic run `ant auth login`. For Bedrock, check your AWS credentials, for example with `aws sts get-caller-identity`, or run `aws sso login`. See [setup step 3](#3-give-the-driver-access-to-an-llm). |
| `no_driver_config`, `jump_command_failed` | The driver can't find your jump server. | Check `~/.quaack/driver.json`. |
| `bad_config` | `~/.quaack/config.json` on the jump server isn't valid, or is a symlink. | Fix it. |
| A version mismatch message | `quaacks` on the jump server doesn't match your checkout. | Run `quaack deploy --host <jump server>`. |

## What QUAACK won't do.

In version 1, QUAACK refuses these, rather than give an answer it can't back up:

- **Anything but a `SELECT`.** No `INSERT`, `UPDATE`, `DELETE`, `SELECT ... INTO`, or `FOR UPDATE`.
- **Anything but plain tables.** No views, materialized views, partitioned tables, foreign tables, or tables with inheritance children.
- **Functions with side effects,** anywhere in the query.
- **Less common SQL:** `GROUPING SETS`, `ROLLUP`, `CUBE`, `TABLESAMPLE`, `SIMILAR TO`, `JSON_TABLE` and the SQL/JSON functions, XML functions, `CYCLE` and `SEARCH` on recursive CTEs, and a few others. Joins, subqueries, CTEs, `UNION`, `CASE`, aggregates, window functions, `IN`, `ANY`, `LIKE`, `BETWEEN`, and `IS NULL` all work.
- **Production older than Postgres 17.**
- **Queries that already use `$1`-style parameters.** Capture the query with its real values.

Some limits are in the design itself:

- **One query per run.** QUAACK doesn't weigh what an index costs every other query, beyond reporting its size and what it makes redundant.
- **It doesn't apply anything.** You decide what ships, and build it yourself.
- **The schema counts as shape.** QUAACK sends table and column definitions to the LLM. It assumes your schema's `CHECK` constraints, defaults, and comments don't hold personal data. If yours do, don't use QUAACK on that schema yet.
- **The racetrack must be a real restore.** QUAACK never generates data for measurement, because made-up data doesn't have production's layout on disk.

## Going deeper.

- [DESIGN.md](DESIGN.md) is the full design: every step, every rule, and exactly what may cross the privacy line.
- [BACKLOG.md](BACKLOG.md) is the work that's left. [BACKLOG-COMPLETE.md](BACKLOG-COMPLETE.md) is the work that's done.
- [e2e/](e2e/README.md) holds 100 real-world slow queries, with what QUAACK should find for each, proven against Postgres.
- [CLAUDE.md](CLAUDE.md) covers development: Ruby 3.4, Docker for tests, and `bundle exec rake` as the one check.
