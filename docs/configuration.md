# Configuration.

QUAACK reads two config files. The driver reads `~/.quaack/driver.json` on your laptop. The enclave script, `quaacks`, reads `~/.quaack/config.json` on the jump server. This page describes every key of both.

## driver.json.

`~/.quaack/driver.json` is one JSON object. `quaack start` reads `jump_command`. `quaack run` reads the LLM settings. `quaack start`, `quaack setup`, and `quaack run` read `enclave_timeout_seconds`.

A missing file counts as no config, so `quaack start` fails with `no_driver_config`. A file that isn't valid JSON, isn't an object, can't be read, or is a symlink to a missing file fails with `bad_driver_config`, naming the file and the problem, such as `bad_driver_config: /Users/me/.quaack/driver.json: no jump_command`.

### Top-level keys.

| Key | Type | Required | Default |
| --- | --- | --- | --- |
| `jump_command` | string | yes | none |
| `enclave_timeout_seconds` | number | no | `3600` (one hour) |
| `llm` | object | no | Anthropic with `claude-opus-5-5` |
| `llms` | array of objects | no | none |
| `llm_routing` | object | no, and only with `llms` | see [llm_routing](#llm_routing) |

Use `llm` or `llms`, never both. Both is a usage error: `use llm or llms in ~/.quaack/driver.json, not both`. An `"llm": null` beside `llms` counts as both.

#### jump_command.

A shell command that prints the ssh host of the jump server for a production server. It must be one non-blank line. `{server}` in the command becomes the server name you pass to `quaack start`.

```json
{ "jump_command": "case {server} in eu-*) echo jump-eu ;; *) echo jump-us ;; esac" }
```

#### enclave_timeout_seconds.

How long each enclave call may run, in seconds, before the driver kills it. It must be a positive number. A big schema can need more than an hour, mostly for `index-build`. For one run, `quaack run --enclave-timeout-seconds <n>` overrides it, with a plain number of seconds, such as `5400` or `90.5`. `quaack deploy` keeps its own limits.

```json
{ "jump_command": "echo jump1.prod.example.com", "enclave_timeout_seconds": 14400 }
```

### One provider: the llm block.

The `llm` block picks one LLM provider for every ask. Every key is optional. Without the block, the driver asks Anthropic's API with `claude-opus-5-5`.

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

Never put a key itself in the file. Put it in an environment variable, and name that variable in `api_key_env`.

| Key | Type | Providers | Default | What it does |
| --- | --- | --- | --- | --- |
| `provider` | string | all | `anthropic` | Which API to call: `anthropic`, `openai_compatible`, `bedrock`, or `copilot_cli`. `openai_compatible` covers OpenAI, Groq, Gemini, OpenRouter, Ollama, and any other server that speaks OpenAI's Chat Completions API. `bedrock` is Claude on AWS Bedrock. `copilot_cli` runs a local Copilot CLI command. |
| `model` | string | all | `claude-opus-5-5` for `anthropic`, and `claude-opus-5.5` for `copilot_cli` | The model to ask. Required for `openai_compatible` and `bedrock`. |
| `base_url` | string | `anthropic`, `openai_compatible`, and `bedrock` | the provider's own | Where to send requests, such as a gateway, or which OpenAI-compatible provider. An `http` or `https` URL. Give the API root, not a URL that ends in `/chat/completions`. Without it, `anthropic` uses `ANTHROPIC_BASE_URL` if set, and `bedrock` uses `ANTHROPIC_BEDROCK_BASE_URL` if set. `openai_compatible` ignores `OPENAI_BASE_URL`. |
| `api_key_env` | string | `anthropic` and `openai_compatible` | the provider's usual lookup | The name of the environment variable that holds the key. When it's set, the driver uses only that variable, and fails with `llm_auth` if it's empty. Without it, `anthropic` looks up `ANTHROPIC_API_KEY`, then `ANTHROPIC_AUTH_TOKEN`, then an `ant` profile, and `openai_compatible` uses `OPENAI_API_KEY`. |
| `max_retries` | whole number, 0 to 10 | `anthropic`, `openai_compatible`, and `bedrock` | the gem's default, 2 | How many times the provider's gem retries a 408, 409, 429, or 5xx after the first attempt. 0 turns retries off. |
| `aws_region` | string | `bedrock` | `AWS_REGION`, `AMAZON_REGION`, `AWS_DEFAULT_REGION`, or your AWS profile's region | The AWS region to call, such as `us-east-1`. |
| `aws_profile` | string | `bedrock` | the AWS SDK's usual lookup | The AWS profile, in `~/.aws`, whose credentials to use. |
| `command_template` | array of strings | `copilot_cli` | a locked-down `copilot` prompt-mode command | The command to run for each ask, as an argv array, run without a shell. It must hold `{prompt_file}` and `{model}`. `{prompt_dir}` is also available. |
| `timeout_seconds` | positive number | `copilot_cli` | `600` | How long each command run may take, in seconds. |
| `token_limit_param` | string | `openai_compatible` | `max_completion_tokens` | The name the token limit goes under: `max_completion_tokens` or `max_tokens`. Set `max_tokens` for Ollama. |

A key that doesn't apply to the block's provider is a usage error. So is an unknown key, or a value of the wrong type. `quaack run` then exits with 64, and the message names the key, never its value, such as `llm.model in ~/.quaack/driver.json is required unless the provider is anthropic`.

#### Environment overrides for the llm block.

These variables override the `llm` block for one run. An empty one counts as unset.

| Variable | Overrides |
| --- | --- |
| `QUAACK_MODEL` | `model` |
| `QUAACK_LLM_PROVIDER` | `provider` |
| `QUAACK_LLM_BASE_URL` | `base_url` |

When `QUAACK_LLM_PROVIDER` switches to a provider other than the block's, the driver ignores the whole block for that run. It still checks each key of the block for the block's own provider, so a mistake shows now. A `base_url` or `api_key_env` in the block is meant for the block's provider, and the new provider's key must never go to it. The model and base URL then come only from `QUAACK_MODEL` and `QUAACK_LLM_BASE_URL`, or the new provider's defaults. So `openai_compatible` and `bedrock` need `QUAACK_MODEL`, or the run exits with 64.

```sh
QUAACK_MODEL=claude-sonnet-5-5 quaack run --run $RUN
```

### Several providers: the llms list.

A run can use more than one LLM provider. Different models propose different rewrites, index ideas, and counterexamples. Each provider also has its own rate and daily limits, so spreading asks across them stretches free tiers.

To use several providers, put an `llms` list in place of the `llm` block. Each entry takes the same keys as the `llm` block, with the same rules for each provider, plus a required `name`.

```json
{
  "jump_command": "echo jump1.prod.example.com",
  "llms": [
    { "name": "opus", "provider": "anthropic" },
    { "name": "groq", "provider": "openai_compatible",
      "base_url": "https://api.groq.com/openai/v1",
      "api_key_env": "GROQ_API_KEY", "model": "llama-3.3-70b-versatile" },
    { "name": "copilot-gpt", "provider": "copilot_cli", "model": "gpt-5.5" }
  ],
  "llm_routing": {
    "mode": "round_robin",
    "counterexample_pairing": "prefer_different",
    "steps": {
      "llm-rewrites": { "fan_out": true },
      "llm-counterexamples": { "providers": ["opus", "copilot-gpt"] },
      "winner-summary": { "providers": ["groq"] }
    }
  }
}
```

Then set each key's variable, such as `export GROQ_API_KEY=...`, before `quaack run`.

The rules for the list:

- It holds one to nine entries, and each one is an object.
- `name` is required. It's 1 to 32 lowercase letters, digits, `_`, or `-`, and no two entries share one. It shows up in progress lines, error messages, and the report, so it must not hold anything secret.
- A provider type may appear more than once. Each entry is its own provider, so two `copilot_cli` entries with different models are two providers.
- A bad key names the entry's position, counting from 0, such as `llms[2].model in ~/.quaack/driver.json is required unless the provider is anthropic`.
- `quaack run` builds a client for every entry before it touches the jump server. So a bad entry, or credentials an entry can't find, stops the run at once, even when the other entries are fine. The message names the entry, such as `llm_auth: groq: GROQ_API_KEY is not set`.

A lone `llm` block, or no block, works as a list of one entry, named after its provider, such as `anthropic`.

#### Environment overrides for the llms list.

`QUAACK_LLM` keeps only the entries it names, in the order it gives, for one run. Separate the names with commas and no spaces:

```sh
QUAACK_LLM=groq,opus quaack run --run $RUN
```

An unknown or repeated name is a usage error. Without `llms`, `QUAACK_LLM` may only name the one provider, such as `anthropic`.

`QUAACK_MODEL`, `QUAACK_LLM_PROVIDER`, and `QUAACK_LLM_BASE_URL` don't apply to `llms`. Setting one with `llms` is a usage error that says to use `QUAACK_LLM` instead.

#### llm_routing.

`llm_routing` says how steps use the list. It needs `llms`: without one, it's a usage error, since one provider has nothing to route. Every key is optional.

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `mode` | `round_robin` or `failover` | `round_robin` | How each unit picks a provider from its step's pool. |
| `counterexample_pairing` | `any`, `prefer_different`, or `require_different` | `any` | Whether llm-counterexamples avoids the provider that wrote the rewrite. |
| `steps` | object, by step name | `{}` | Routing for one step at a time. |

Each key of `steps` is an LLM step: `llm-index-ideas`, `llm-index-refine`, `llm-rewrites`, `operator-rewrites`, `llm-counterexamples`, `rewrite-llm-index-ideas`, `rewrite-llm-index-refine`, or `winner-summary`. Each value is an object with these keys, each optional:

| Key | Type | What it does |
| --- | --- | --- |
| `providers` | array of entry names | Pins the step to these entries, in this order. Each must be a different name from `llms`. |
| `mode` | `round_robin` or `failover` | Overrides `llm_routing.mode` for this step. |
| `fan_out` | `true` or `false` | Asks every healthy provider in the pool, not just one. Only `llm-rewrites`, `llm-index-ideas`, and `rewrite-llm-index-ideas` take it. On any other step it's a usage error, even as `false`. |

#### How asks are routed.

An **ask** is one request to an LLM. A **unit** is one ask, or a run of asks that must stay on one provider, so a model never sees another model's reply as its own. llm-index-ideas and rewrite-llm-index-ideas keep the first ask and its replacement round together. llm-counterexamples keeps one rewrite's rounds, up to three, together. Every other ask is a unit of one.

Each step has a **pool**: the providers it may use. That's the step's pinned `providers`, if it has them, or else every entry, in list order. Either way, the entries `QUAACK_LLM` drops are left out. A pinned step that `QUAACK_LLM` leaves empty is a usage error.

The mode then picks the provider for each unit:

- `round_robin` starts each unit on the next healthy provider after the one the last unit started on. One cursor turns across the whole list for the run, so asks spread evenly. A resumed run starts the cursor over.
- `failover` starts each unit on the pool's first healthy provider. The rest of the list are backups.

Both modes fail over when a unit's first ask fails, after the provider's own retries:

- `llm_rate_limited` and `llm_unavailable` mark the provider down for the rest of the run, and the unit starts again on the next healthy provider.
- `llm_auth` drops the provider for the rest of the run, with a loud progress line, since its credentials need fixing. The unit starts again on the next healthy provider.
- `llm_bad_response` tries the next healthy provider, but doesn't mark this one down. Later units may still use it.
- `llm_bad_request` doesn't fail over. It fails the step.

When no healthy provider in the pool is left, the step fails with the last failure's rule, and the message lists what was tried.

A later ask in a unit can't move to another provider. When one fails with a rule that fails over, the provider is marked down or dropped as above. Then llm-index-ideas and rewrite-llm-index-ideas keep their first-round ideas and skip the replacement round. llm-counterexamples starts the rewrite's remaining rounds fresh on another provider, and the rounds still count toward the limit of three.

#### Fan-out.

A step with `"fan_out": true` runs its unit once on every healthy provider in its pool, one after another, and takes the union of the answers. Mode doesn't apply to it, and its branches don't fail over. A branch that fails is dropped, and the step goes on with the rest. The step fails only when every branch fails, or when one fails with `llm_bad_request`.

Fan-out doesn't raise any limit. llm-rewrites still sends at most five rewrites in all, taking each branch's first, then each branch's second, and so on. llm-index-ideas still sends at most five ideas per test the same way. Fan-out does multiply the step's calls by the size of its pool, which is why it's off by default.

#### Adversarial pairing.

`counterexample_pairing` makes llm-counterexamples use a provider other than the one that wrote the rewrite, so the model that hunts for counterexamples isn't grading its own work.

- `any` picks as for any other step.
- `prefer_different` drops the rewrite's author from the pool, then picks as usual. If nothing healthy is left, it uses the author, and the report says the pairing wasn't met.
- `require_different` does the same, but with nothing healthy left, the step fails with `llm_unavailable`, naming the rewrite and its author. It needs at least two providers in llm-counterexamples' pool, or it's a usage error at startup.

An entry counts as the author if it wrote the rewrite, or if it has the same `model` string as the entry that did. Two spellings of one model, such as `claude-opus-5-5` and `claude-opus-5.5`, count as different models. Pairing applies only to llm-rewrites' rewrites. Rule-made rewrites and your own rewrites have no author, so they pick as with `any`.

The order is: the pool comes from pinning or the whole list, pairing filters it, and then fan-out runs a branch on each healthy provider left, or the mode picks one.

### Credentials.

The driver never stores a key, and a key never goes in `driver.json`. Each provider finds its credentials like this:

- `anthropic` uses the variable `api_key_env` names, if it's set. Otherwise it takes the first of these that's set: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or a profile such as the one `ant auth login` saves. `ANTHROPIC_PROFILE` picks a profile other than the active one.
- `openai_compatible` uses the variable `api_key_env` names, or `OPENAI_API_KEY`.
- `bedrock` uses your AWS credentials. See [AWS Bedrock](#aws-bedrock).
- `copilot_cli` uses the Copilot CLI's own login.

With no credentials, `quaack run` fails with `llm_auth` before it touches the jump server. So does an empty variable. For Anthropic, the first of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` that's set hides everything after it, even when it's empty, so unset an empty one.

### OpenAI-compatible providers.

With `"provider": "openai_compatible"`, the driver talks to OpenAI's Chat Completions API, through the official `openai` gem, at `base_url`. It sends the key from the variable `api_key_env` names, or from `OPENAI_API_KEY` when it names none, as a bearer token. If that variable is unset or empty, `quaack run` fails with `llm_auth` before it makes any call. Give a `model` too: there's no default.

These were checked against each provider's docs on October 7, 2026, but providers change their models often, so check yours.

| Provider | `base_url` | `api_key_env` | `model`, for example |
| --- | --- | --- | --- |
| OpenAI | leave it out | leave it out (`OPENAI_API_KEY`) | `gpt-4.1` |
| Groq | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` | `llama-3.3-70b-versatile` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `GEMINI_API_KEY` | `gemini-3.8-flash` |
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

then `export GROQ_API_KEY=...` before `quaack run`. Give the API root as `base_url`, not the full endpoint: the driver adds `/chat/completions` itself, so a `base_url` that ends in it is a usage error. Ollama needs no key, but the driver still wants one, so set the variable to anything, such as `export OLLAMA_API_KEY=ollama`. The driver sends its token limit as `max_completion_tokens`, which Ollama ignores, so for Ollama add `"token_limit_param": "max_tokens"` to the block. Without it, a reply from Ollama has no token limit.

The models are examples. Use one your account can call, and **make it a strong model**: QUAACK asks for careful SQL work, and a small model is mostly a waste of time and tokens.

**Reasoning models need headroom.** A reasoning model, such as OpenAI's `gpt-5` or `o3`, or Gemini's thinking models, spends its token limit on thinking as well as on the reply. QUAACK asks for at most 4000 or 8000 tokens a reply, so a long think can use them all up and leave no reply, and the run stops with `llm_bad_response: the reply stopped for length`. That's why the table's OpenAI example is `gpt-4.1`, which doesn't reason. If you use a reasoning model and see that error, pick a model that reasons less, or not at all.

**Structured output.** At several steps, QUAACK asks for JSON in a fixed shape, and checks every reply. A reply in the wrong shape gets one more try. If the model gets it wrong twice, the run stops with `llm_bad_response`. Strong models rarely do.

> **Your other OpenAI settings stay with OpenAI.** The `openai` gem reads `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, and `OPENAI_CUSTOM_HEADERS`. The driver sends what they hold only when `base_url` is OpenAI's own (`api.openai.com`), never to Groq, Gemini, or any other provider. It ignores `OPENAI_BASE_URL`: only `base_url`, or `QUAACK_LLM_BASE_URL`, says where requests go.

### AWS Bedrock.

With `"provider": "bedrock"`, the driver asks Claude on AWS Bedrock, through the `anthropic` gem's Bedrock client, which calls Bedrock's InvokeModel API and signs each request with your AWS credentials. QUAACK stores no credentials. It finds them the way the AWS CLI and SDKs do:

1. A Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK`, if it's set. It's sent as a bearer token, and nothing below is looked at.
2. The profile `aws_profile` names, from `~/.aws/config` and `~/.aws/credentials`: static keys, SSO (run `aws sso login` first), an assumed role, or a `credential_process`.
3. Otherwise the AWS SDK's own chain: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (with `AWS_SESSION_TOKEN` for temporary ones), the profile `AWS_PROFILE` names or the default one, then a container or EC2 instance role.

Finding none, a profile that can't be loaded, or an empty `AWS_BEARER_TOKEN_BEDROCK` makes `quaack run` fail with `llm_auth` before it touches the jump server. So does a Bedrock API key with `aws_profile` set, since they name different credentials: it's a usage error, exit 64. The credentials are read once, when the run starts, so an SSO session that expires partway through fails that run with `llm_auth`. Log in again, and start a new run.

Give a `model`, since there's no default: Bedrock's model IDs vary by region and by inference profile. Use the ID the Bedrock console shows for your region, such as `anthropic.claude-opus-5-5`, or a cross-region inference profile such as `us.anthropic.claude-opus-5-5`. With no region anywhere, `quaack run` exits with 64. So does an `AWS_REGION`, `AMAZON_REGION`, or `AWS_DEFAULT_REGION` that isn't a region, when there's no `aws_region`. The driver checks the first of them that's set, in that order, since that's the one the AWS SDK uses. If that one is empty, the AWS SDK skips the others, and so does the driver. `base_url` is for a private endpoint, and a Bedrock API key needs no region when there's a `base_url`. With no `base_url` or `QUAACK_LLM_BASE_URL`, the `anthropic` gem sends to `ANTHROPIC_BEDROCK_BASE_URL` when that's set. The driver doesn't check that variable, and still needs a region with it.

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

### GitHub Copilot CLI.

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


## config.json on the jump server.

`~/.quaack/config.json` on the jump server holds what the enclave needs to know. It's one JSON object, and every key is optional. A missing file is an empty config. A file that's a symlink, isn't a regular file, can't be read, is larger than 64 KiB, isn't valid JSON, or has a value of the wrong type fails with `bad_config`. Keys it doesn't know are left alone.

```json
{
  "memory_command": "aws rds describe-db-instances --db-instance-identifier {host} --query 'DBInstances[0].DBInstanceClass' --output text | ./instance-class-to-bytes",
  "run_server_command": "/opt/dba/make-quaack-run-server {server} {run}",
  "destroy_command": "/opt/dba/destroy-quaack-run-server {run}",
  "pii_columns": ["*.users.email", "*.users.*name", "billing.*.card_*"],
  "cardinality_threshold": 50,
  "extra_dump_schemas": ["dba"],
  "baseline_cap_seconds": 3600
}
```

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `memory_command` | one-line string | none: memory is recorded as unknown | Prints production's instance memory, such as `64GB`. `{host}` is production's host. |
| `run_server_command` | one-line string | none: you pass the run server as flags to `quaack setup` or `quaack run` | Builds or finds the run server, and prints `{"host": ..., "port": ..., "racetrack_db": ..., "arena_db": ...}`. `{server}` is the production server name, and `{run}` is the run ID. It gets an hour. |
| `destroy_command` | one-line string | none: QUAACK reminds you to destroy the run server yourself | Destroys the run server at the end of a run. It must succeed if the server is already gone. |
| `pii_columns` | array of strings | `[]` | `schema.table.column` patterns for columns that hold personal data. Each has three non-empty parts. `*` matches within one part. Case is ignored. |
| `cardinality_threshold` | positive whole number | `50` | The line between few and many distinct values. Any text column with this many distinct values or more counts as personal data. |
| `extra_dump_schemas` | array of schema names | `[]` | Schemas the schema dump adds whole, for objects Postgres records no dependency on, such as what a SQL function with a string body reads. A name the production database lacks fails with `unknown_extra_dump_schema`. |
| `baseline_cap_seconds` | positive whole number | `3600` | The ceiling on each baseline run of the original query. A run that hits it fails with `baseline_original_exceeded_cap`. |

Personal-data columns never have their common values, or how often those values appear, sent to the LLM. Only columns with fewer distinct values than the threshold, such as `status` or `country`, ever have their values sent.
