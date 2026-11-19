# Agents

This plugin gives one bar icon and one panel for all AI coding subscriptions on the computer.
The panel only shows data. It watches the usage records that `omarchy-agent-usage-update`
writes to `~/.local/state/omarchy/agents/usage/`, and it shows the records that it finds there.

- `Panel.qml` controls the bar button and the popup.
- `Main.qml` finds and watches the records. It also does the optional aggregation from other
  devices.
- `Agent.qml` watches the file of one record.

## Panel

The panel shows all subscriptions on one page. The limits are first.

- **Hero**: The agents robot, and a line that changes between the token totals of all agents.
  The line shows the tokens this week and today, the most used model, the busiest day, and the
  prompts and sessions of today. In its corner, + adds a subscription and >_ starts the default
  agent.
- **One section for each subscription**:
  - An agent gets a section if it has limits, a balance, a plan or accounts to show. An agent
    with only local history adds data only to the line in the hero.
  - The section shows the mark, the name and the plan of the agent. Then it shows one compact
    line for each limit window: the meter and the time until the reset. Move the pointer on the
    meter to see the exact percentage.
  - An allowance for one model on the same clock (the Claude Fable weekly limit) is a tick on
    the meter of that window. It does not get its own line. The tooltip of the row gives its
    name.
  - If a Claude, Codex or Grok sign-in is expired or missing, a _Sign-in required_ link shows.
    Use it to sign in to that account again from the panel.
  - For other problems, the last known limits stay. Examples are a paused token, the sign-in of
    a different agent, or an endpoint that did not answer. A small info mark shows next to the
    name. Its tooltip tells you why the limits are not current and what to do. The tooltip of
    each meter tells you the age of the data.
- **Accounts**: An agent can have more than one subscription account (refer to
  `omarchy agent account`). The panel then shows each account.
  - Each account has its name and plan on one line, and its own limit lines. Move the pointer
    on the line to see the email.
  - An _ACTIVE_ label shows the account that new sessions use. The other accounts have a _Use_
    link.
  - When the pointer is on the line, Autoswitch also shows. When the active account gets to its
    threshold, Autoswitch moves new sessions to a different account automatically.
  - While Autoswitch is on, it replaces Use. Use then shows only when the pointer is on the line.
    Click Autoswitch again to go back to notifications.
  - Click a name to change the name of the account.
- **Balance**: Prepaid agents show a credit ledger in place of limits. The ledger has a fuel
  gauge meter that decreases toward empty, the remaining credit, and the funded and spent
  amounts.
- **Make something cool**: Starter prompts (a new theme, a plugin or an app). They start the
  default agent on the task through `omarchy agent prompt`.
- **Adding a subscription**: Click the + in the corner of the hero.
  - The page then shows Claude Code, Codex and Grok as large marks, three in a row. The first
    mark has the focus. The line in the hero shows Add an account.
  - The + becomes an X. The X goes back.
  - If you cannot add an agent, its mark is dim. Move the pointer on it to see why.
  - For an additional account, the panel asks for a name first. Push Enter to sign in.
  - The panel then runs `omarchy-agent-account-add --events` and follows it. It shows the
    status and the code that Grok asks you to confirm in the browser. If the Claude page shows
    a code and does not complete, the panel gives a field to paste that code. It also gives a
    link to open the sign-in page again.
  - Push Esc or click the X to stop the login.
  - When the browser gets the focus, the panel can close. The sign-in continues, and its result
    comes as a notification.

The icon is always in the bar. On a computer with no agent, use the panel to set up an agent.
It opens on the same selection of Claude, Codex or Grok. If no default agent is set, the first
agent that you sign in to becomes the default agent.

An agent shows after you enable it in the settings and it has recorded usage, on this computer
or on a synced computer. If you install a CLI during the session, it shows at the next refresh.
To remove the widget, run `omarchy plugin disable omarchy.agents`.

## Data

Each agent is one JSON record in `~/.local/state/omarchy/agents/usage/`.
`omarchy-agent-usage-update` writes the records. That command runs one
`omarchy-agent-usage-<agent>` collector for each agent. The widget starts the command on its
refresh timer and when you ask for a refresh. The widget reads all records in the directory,
independent of the program that wrote them.

To add an agent, you do not change the QML.

1. Supply a collector that follows the contract in [`docs/agent-usage-collectors.md`](../../../docs/agent-usage-collectors.md).
   The `claude` collector is the reference.
2. Build it on the shared functions in `collectors.py`, next to this README.

The panel then gets a new section. An `assets/<id>.svg` mark is optional. If the mark needs a
dark variant for light surfaces, add an `assets/<id>-light.svg` file. If there is no mark, the
panel uses the bar glyph.

| Collector | Limits | Local stats |
|---|---|---|
| `claude` | Anthropic's OAuth usage endpoint (5-hour session, 7-day weekly, and any model-scoped windows) | `~/.claude/projects` transcripts, pi/omp sessions and opencode sessions on an Anthropic provider, plus `stats-cache.json` and `history.jsonl` as fallback |
| `codex` | The Codex app-server's `account/rateLimits/read`, every bucket (general windows plus any model's own), plus an individual spend cap and its reported reset time when present | native Codex CLI session files on the built-in `openai` provider, pi/omp sessions on `openai-codex`, and opencode sessions on the `openai` provider |
| `grok` | The credits endpoint behind Grok's `/usage` view (the billing period's included usage), plus the monthly included quota of a unified-billing account | Each session's `usage.json` (the ledger `grok usage` prints: tokens by model per finished turn, one turn per typed prompt, a fork's copied turns counted once), plus `summary.json` for sessions |
| `kimi` | Kimi Code quotas (5-hour session, weekly, and monthly allowances) | Kimi Code's per-agent `wire.jsonl` session logs under its home on Kimi's routes, pi, omp, and opencode sessions on the Kimi Code plan (`kimi-coding`, `kimi-code`, `kimi-code-plan-global`, `kimi-code-plan-cn`) or Moonshot's API (`moonshotai`, `moonshotai-cn`, `moonshot`), plus Claude Code turns sent to Kimi's or Moonshot's API or answered by a `kimi-*` or `moonshot*` model |
| `cursor` | Cursor's dashboard RPCs: the included total for the billing month, with the auto-model, named-model, and on-demand meters attached to it | the same dashboard RPCs, one call per day for the last week |
| `grokbot` | Grok Bot's weekly included usage from Cursor's `GetSandUsageStatus` RPC, asked as the Cursor sign-in | none; limit only |
| `copilot` | Account-wide AI credit allowance (GitHub quota endpoint, or estimated locally) | the Copilot CLI session store's `assistant_usage_events`, with `~/.copilot/session-state` transcripts as fallback |
| `muse` | The client's key endpoint (session + weekly percents), else local metering only — never estimated | native `muse` CLI session files, with prompt and session counts from its `session-index.db`, plus pi/omp and opencode sessions on the `meta` provider and omp's `muse-code` |
| `agy` | Google's Cloud Code API (`loadCodeAssist` for the plan, `retrieveUserQuotaSummary` for the 5-hour and weekly windows and any touched Claude/GPT allowance), asked with the sign-in agy, omp, pi, or opencode's Antigravity plugin keeps | `history.jsonl`, `conversation_summaries.db`, and each conversation's `transcript.jsonl` under `~/.gemini/antigravity-cli/` (`AGY_DIR`), plus pi, omp, and OpenClaw sessions on the `google-antigravity` provider and opencode's `antigravity-` models |
| `kimchi` | The plan, prepaid credits, and any spend budgets from the gateway's `/v1/credits` and `/v1/budget`, the endpoints Kimchi's own status line reads | Kimchi's pi session files under `~/.config/kimchi/harness/sessions` (`KIMCHI_CODING_AGENT_DIR`): tokens by model per assistant reply on Kimchi's own `kimchi` and `kimchi-dev` routes; a session `--provider openrouter` is OpenRouter's, and one on a custom provider counts nowhere. Also pi/omp sessions and opencode replies on those provider ids, and Claude Code turns and Codex rollouts sent to Kimchi's gateway (`llm.kimchi.dev`, `llm.eu.kimchi.dev`), as `kimchi claudecode` and `kimchi codex` set them up |
| `hermes` | None (Hermes has no subscription of its own) | `state.db` in Hermes' home and in each named profile under its root's `profiles/`, read-only, scanned once per refresh window: the sessions Nous Portal billed, and those from before Hermes kept the route |
| `devin` | The daily and weekly quota (plus credit buckets on credit plans) from the GetUserStatus answer the Devin CLI caches in `$XDG_CACHE_HOME/devin/cli/user_status.*.bin`; no network call | the CLI's `$XDG_DATA_HOME/devin/cli/sessions.db` (per-message metrics and `prompt_history`), plus pi/omp and opencode sessions on the `devin` provider |
| `vibe` | None (Mistral publishes no usage limits) | Vibe's Unified Harness store under `~/.vibe/logs/session/unified` and older releases' per-session `meta.json` under `~/.vibe/logs/session` (`VIBE_HOME`), only sessions on a Mistral-served model, plus pi/omp and opencode sessions on the `mistral` provider |
| `qwen` | None (neither Qwen Code nor Alibaba publishes a way to read a Coding Plan or Token Plan quota) | Session transcripts under `~/.qwen/projects/*/chats` (`QWEN_HOME`, `QWEN_RUNTIME_DIR`, `advanced.runtimeOutputDir`): billed API responses on Alibaba's routes and typed prompts, plus pi, omp, and opencode sessions on Alibaba's Coding Plan, Token Plan, and Qwen OAuth providers |
| `opencode` | OpenCode Go's usage endpoint (rolling + weekly + monthly), with an API key or the Console session; a key without a Go plan shows local usage alone | pi and omp sessions (profiles included) on the Zen and Go providers, plus opencode's own `message` and `session_message` stores |
| `zai` | Z.ai's coding-plan monitor endpoint (5-hour session + 7-day weekly), for keys that carry a GLM Coding Plan | pi, omp, and opencode sessions on Z.ai's and Zhipu's providers (`zai`, `zhipu`, pi's `zai-coding-cn`, omp's `zhipu-coding-plan`, opencode's `zhipuai`, `zai-coding-plan` and `zhipuai-coding-plan`; `glm-*` models), plus Claude Code turns sent to Z.ai or answered by a `glm-*` model |
| `ollama` | Ollama Cloud's balance endpoint (5-hour session + 7-day weekly on a legacy plan, or the monthly included credits), plus any purchased credits left as a balance | pi, omp, and opencode sessions on the `ollama-cloud` provider, plus cloud-tagged models reached through the local daemon's `ollama` provider (Codex `--oss` rollouts included), Codex rollouts on a `model_providers` entry at ollama.com, and Claude Code turns sent to ollama.com or answered by a cloud-tagged model |
| `minimax` | MiniMax Token Plan API (5-hour session + 7-day weekly) | MiniMax Code's session files under `~/.minimax/v2/sessions`, plus pi, omp, and opencode sessions on a MiniMax provider, and Claude Code turns sent to MiniMax or answered by a `MiniMax-*` model |
| `openrouter` | Prepaid balance from `/credits`, key-limit meter from `/key`, each kept stale past a failed check | opencode and pi/omp sessions on the OpenRouter provider, Kimchi sessions run with `--provider openrouter`, DeepSeek Harness's `openrouter` route, MiniMax Code custom providers at openrouter.ai, and Claude Code turns sent to OpenRouter, with or without a key, or the `/activity` billing API with a management key |
| `deepseek` | Live prepaid balance from `GET https://api.deepseek.com/user/balance`, kept stale past a failed check, with the optional `fundedAmount` estimate for the funded-versus-spent line | pi/omp session files (profiles included) whose assistant messages ran on the deepseek provider, opencode sessions on a deepseek provider, DeepSeek Harness (`dsh`) session logs on its DeepSeek routes, and Claude Code turns sent to DeepSeek or answered by a `deepseek-*` model |
| `fireworks` | Prepaid balance: the live ledger when the key can read it, else configured funding minus rated account costs; kept stale past a failed check | Fireworks billing API, grouped by day and model for the last 30 days, cached per key and account |
| `synthetic` | Synthetic's `GET /v2/quotas`: rolling five-hour requests, weekly credits, hourly search, free tool calls | pi/omp sessions and opencode messages on the `synthetic` provider; Claude Code, MiniMax Code and Codex sent to `api.synthetic.new`, and Claude Code replies by `hf:`/`syn:` models with no override |
| `local` | None (self-hosted work has no meter) | Codex rollouts, pi/omp sessions and opencode messages on a local runtime, a provider named in `local.json`, or a Codex provider whose `base_url` is on the LAN, never a provider id another collector counts, plus Claude Code turns while `ANTHROPIC_BASE_URL` is self-hosted (not Claude models or cloud-tagged ones), and Kimi Code, Qwen Code, Hermes and Mistral Vibe requests sent to a self-hosted base URL |

All collectors follow the same rules. Thus the same situation shows the same for each agent:

- A collector uses a recent answer again for 15 seconds, unless you push refresh.
- Each credential or account keeps its own last good answer.
- After a failed check, the collector keeps the last good answer. Move the pointer on it to see
  its age. Windows that reset after that answer show zero.
- If the collector cannot reach an endpoint, it tries again soon.
- An agent that the computer does not use stays out of the panel.

The collectors count each token one time, under the provider that bills it. They divide pi, omp
and opencode sessions by provider into the related collector.

- The usage of a pi compaction counts. omp records only the size of the context before and
  after a compaction, not the usage of its summary request. Thus the tokens do not include the
  omp compactions.
- The collectors read pi and omp sessions from all profiles. They also read
  `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR` and a `settings.json` `sessionDir`, in
  addition to the defaults, when these are set. The copied messages of a forked session count
  one time.
- The collectors read opencode from its `message` store and its V2 `session_message` store, in
  the database that `OPENCODE_DB` names. A message that is in the two stores counts one time.
  The copied history of a fork does not count.

On a computer without the home, the CLI or the usage of an agent, the collector prints an empty
record. The panel ignores it. If the computer has them but no sign-in, the record tells you that
it waits for a sign-in. The sections below tell you where the sign-in and the data of each agent
come from.

`~/.local/state/omarchy/agents/accounts/<claude|codex|grok>.json` can register more than one
account. Then the `claude`, `codex` and `grok` records also contain
`accounts: [{ id, label, email, plan, active, primary, limits, stale, fetchedAt, retryAdvised, usageStatusText, authHelpText }]`
and `accountSwitch: { mode, threshold }`.

- The collector asks for each account with its own sign-in. Each account keeps its own last
  limits in the cache. Codex runs one app-server for each account home.
- The top-level `limits` and `tierLabel` of the record continue to describe the active account.
- The local statistics stay one set, because all accounts use the history of the primary home.
- After each run, `omarchy-agent-usage-update` gives the new limits to
  `omarchy-agent-account-state autoswitch`. When the active account goes past its threshold,
  that command sends a notification or changes the account. If the active account changed, it
  collects the record again.

### Claude Code

The limits come from the Anthropic OAuth usage endpoint. The collector asks with the access token
that the Claude Code CLI keeps in `.credentials.json` below `CLAUDE_CONFIG_DIR` (the default is
`~/.claude`). The plan comes from the CLI profile. If not, it comes from the credentials.

- Only the CLI refreshes that token. If the token expires, the panel shows "Limits paused" and
  keeps the last numbers until Claude Code runs again.
- If the refresh token expires, the panel shows "Sign-in expired".
- Without credentials, the panel tells you. It then shows only local statistics.

The local statistics come from the CLI transcripts below `projects/`. If necessary, they come
from `stats-cache.json` and `history.jsonl`. The days in the cache are UTC dates that stop at
yesterday. Thus its daily tokens are approximate and almost never include today. The statistics
also include pi and omp sessions (with `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`)
and opencode sessions on the `anthropic` provider.

Only the usage that Anthropic served counts here. The collector that bills the other usage
counts it with the same rule (`claude_code_owner` in `collectors.py`), with the prompts that it
answered.

- Claude Code sends to the host that `ANTHROPIC_BASE_URL` names. Z.ai, Ollama, MiniMax,
  DeepSeek, Kimi, OpenRouter, Alibaba's Model Studio ([Qwen](#qwen-code)),
  [Synthetic](#synthetic) and [Kimchi](#kimchi) (`kimchi claudecode`) tell you to point it at
  their APIs.
- A transcript does not record where it was sent. Thus, while the `env` in `settings.json` (or
  the environment) points `ANTHROPIC_BASE_URL` at the host of one of those providers, all replies
  belong to that provider. This includes earlier replies.
- If not, the model that answered decides:
  - A Claude model belongs to Claude, also through a proxy or a local gateway.
  - An Ollama `:cloud` tag belongs to Ollama Cloud.
  - With a self-hosted base URL (Ollama's `localhost:11434`), all other models belong to the
    `local` collector.
  - With no override, `glm-*` belongs to Z.ai, `MiniMax-*` to MiniMax, `deepseek-*` to
    DeepSeek, `kimi-*` and `moonshot*` to Kimi, and `hf:*` and `syn:*` to Synthetic.
- All other models with no override (`qwen3-coder`) do not count. A model that is not Claude,
  behind a host that the collector cannot identify, also does not count.
- The `stats-cache.json` fallback removes models that are not Claude in the same way. The other
  collectors read only the transcripts.

A reply counts one time, by its message id and its request id. This is also true in the
transcripts that a resume or a fork copies it into.

- A `/btw` side question replays the message of its parent in a sidechain, as a full copy with a
  new request id. This copy counts under the parent.
- The reply of a subagent counts, also when a gateway gave it the message id of its parent.

A prompt is a message that a person sent. It is a user line in the main thread. These user lines
are not prompts:

- The result of a tool.
- A meta line of Claude Code.
- A compaction summary.
- A task notification.
- The output of a local command.
- A built-in command that runs locally (`/model`, `/clear`, `/compact`, `/exit`). This includes
  all commands that Claude Code answers with a `local-command-stdout` or `-stderr` line.


- A prompt that you type during a turn also counts. Claude Code puts it in a queue as a
  `queued_command` attachment.
- A custom slash command or a skill asks the model, thus it counts.
- Each prompt counts one time, by its uuid. A resumed or forked transcript keeps the uuid. Thus
  the API requests of a tool loop are tokens, not prompts.

Some requests have no reply line. These are a compaction, the session title, and side queries,
for example from Haiku. (For a compaction, a `compact_boundary` line records only the size of the
context.) Some replies show
less usage than the real usage. A subagent can write its reply with only its `message_start`
usage (`stop_reason` null, a few output tokens), and its real output is never written.

Claude Code 2.1.278 and later write `cost-state` lines in some sessions, not in all sessions.

- These lines give the running totals for each model of the cost lineage of a process. A lineage
  is identified by its `startTime`, which a resume or `--fork-session` keeps.
- The usage in these totals that is more than the replies of the sessions in the lineage
  (subagents included) also counts. It counts one time for each lineage, under the collector that
  bills that model. It counts on the day of the first cost-state that contains it, not on the day
  of the requests.
- A process that still runs counts that usage when it saves its cost the next time.
- Sessions before 2.1.278 have no cost-state, and some later sessions also have none. For these
  sessions, the tokens do not include the compactions. They also do not include the full usage of
  the subagent replies that show less usage.

All collectors that read the transcripts use one shared index of them. One collector updates the
index at a time. The other collectors wait for it and then read it. If the index already contains
all transcripts in their current state, the collectors read it without a wait.

### Codex

The limits and the plan come from the app-server of the Codex CLI (`codex app-server`,
`account/rateLimits/read`). The collector starts it in the home of each account (`CODEX_HOME`,
the default is `~/.codex`). Thus it answers for that login and refreshes its tokens there.

- The collector reads all rate-limit buckets: the general windows, and the allowance of each
  model. A model allowance shows next to the window with the same period.
- An individual spend cap, for example the cap of a Business seat, has its own "Spend limit"
  meter. The meter shows the part of the cap that is spent, with the reset time that the
  app-server reports, because the cap has no period. A spend cap can come without a rate window.
- The plan shows with the name that the Codex `/status` command uses (`pro` is Pro 200, `promax`
  is Pro 500, `team` is Business). A plan that is newer than that table keeps its wire name.
- If a home has no `auth.json` below the file store and no `CODEX_ACCESS_TOKEN`, the panel shows
  "Waiting for auth". The collector does not start the app-server.
- An API-key login has no plan limits to read. This is `auth_mode` `apikey` in `auth.json`, or,
  with no `auth_mode`, an `OPENAI_API_KEY` there, with or without ChatGPT tokens, as Codex reads
  it. For this login, the collector does not start an app-server. The panel shows only local
  statistics, with no sign-in.

Each login keeps its last good limits, by the workspace and the user in `auth.json` (or by the
access token). The collector cannot identify a keyring login, thus a keyring login keeps no
limits. If an app-server stops or cannot reach OpenAI, the collector tries again soon.

The local statistics come from these sources:

- Native session files on the built-in `openai` provider.
- pi and omp sessions on `openai-codex` (with `PI_CODING_AGENT_DIR` and
  `PI_CODING_AGENT_SESSION_DIR`).
- opencode sessions on `openai`, from the two message stores of opencode and the database that
  `OPENCODE_DB` names.

The tokens of a native session are its responses. From Codex 0.163, each response is one
`token_usage_record` line, and this includes a remote compaction. Before that, each
`token_count` event gives the last request. Interactive Codex sends thread-title requests, but
it writes them to no rollout. Thus their tokens, which are small, are missing. `codex exec` sends
no thread-title requests.

The prompts of a native session are the prompts that you typed (a `UserMessage` item, or a
`user_message` event in a legacy rollout). The requests that answered them are not prompts. The
thread of a subagent or a guardian has no typed prompts and starts no session. Its tokens count
under the session that started it (its `session_id`, or else its `parent_thread_id`).

Codex CLI can use all OpenAI-compatible backends. Examples are `--oss`, or a custom
`model_provider` in `config.toml` for Ollama, LM Studio or a gateway. Those rollouts are in the
same sessions directory as the rollouts on OpenAI.

- The Codex collector ignores a rollout if its first `session_meta.model_provider` is not the
  built-in `openai` provider.
- Rollouts from before Codex recorded that field have no provider. They continue to count.
- An ignored rollout can use a `model_providers` entry whose `base_url` is the API of a provider:
  Z.ai, OpenRouter, DeepSeek, Moonshot or Kimi, Alibaba's Model Studio, MiniMax, ollama.com,
  [Synthetic](#synthetic), or the gateway of [Kimchi](#kimchi) as `kimchi codex` sets it up. That
  rollout counts under the collector of that provider, independent of the id of the entry.
- A rollout on your own hardware counts under Local models.
- A rollout behind a gateway that no collector can identify does not count.

Codex also sends the built-in `openai` provider to the URL that `openai_base_url` in
`/etc/codex/config.toml` or `config.toml` gives. (`OPENAI_BASE_URL` in the environment has no
effect.) Those rollouts still name only `openai`.

- While that `openai_base_url` names the API of a provider, all built-in rollouts count under the
  collector of that provider. This includes earlier rollouts.
- The `<name>.config.toml` of a profile applies only to a run with `--profile`. Thus its
  `openai_base_url` decides only for the model that it sets, if that model is not an OpenAI model
  and not the model that `config.toml` sets. A profile that names the API of a provider moves
  only the rollouts of that model.
- Behind all other base URLs, the OpenAI models (`gpt-*` but not `gpt-oss`, `*codex*`, `o3`)
  continue to count here, because a proxy can send them on to OpenAI. All other models count
  under Local models if the URL is self-hosted. They do not count if the URL is a gateway that no
  collector can identify.
- The current configuration decides. When you remove the key, all built-in rollouts belong to
  Codex again.

### Grok

The plan comes from the settings that Grok keeps in its home (`GROK_HOME`, the default is
`~/.grok`). The limit comes from the credits endpoint that the Grok `/usage` view reads. The
collector asks with the sign-in of each account from `auth.json`.

- An expired access token with a live refresh token is usual. Grok renews it when it starts.
  Until then, the panel shows "Limits paused" and keeps the last credits as stale.
- A refused sign-in, or a sign-in older than 30 days, shows "Sign-in expired".
- The local statistics come from the `usage.json` and `summary.json` of each session. A turn is a
  typed prompt, but not in the session of a subagent. The turns that a fork copies from its
  source count one time.
- If sessions are on the disk, Grok is in use, also without a sign-in.

### Kimi

Kimi reads `KIMI_API_KEY` first. Then it reads `credentials/kimi-code.json` below an explicit
`KIMI_CODE_HOME`.

- Without that override, it uses `~/.kimi-code/credentials/kimi-code.json` first. If necessary,
  it uses the `credentials/kimi-code.json` of the legacy kimi-cli below `KIMI_SHARE_DIR` (or
  `~/.kimi`) for compatibility.
- An explicit home never uses the sign-in of a different home.
- Kimi is in use when it has a credential or a Kimi home. A home without a sign-in waits for one.
  A computer with neither stays hidden.

The local statistics come from the log that Kimi Code 2.x keeps for each agent of a session,
subagents included. The log is at `sessions/<workspace>/<session>/agents/<agent>/wire.jsonl`
below its home (`KIMI_CODE_HOME`, or else `~/.kimi-code`).

- Each `usage.record` is one billed model request. This includes compactions.
- Each `turn.prompt` or `turn.steer` that a person typed is a prompt. This includes slash
  commands.
- A fork copies the log of its source before it marks it as forked. Thus the copies count one
  time, under the session of the source.

A request counts here when Kimi billed it.

- The collector finds the model alias through `config.toml`: the provider of `[models.<alias>]`,
  its `base_url` or the `*_BASE_URL` in its `env` table, or the `base_url` of the model.
- The API of Kimi or Moonshot, a `kimi` provider with no `base_url`, or an alias that the
  configuration does not name belongs to Kimi.
- A request on a server that you operate counts under Local models. A request on the API of
  Anthropic, OpenAI or Google, or on a gateway, does not count.
- Each prompt goes with the next request for it, answered or not. If there is none, it goes with
  the alias of its agent. Thus a prompt that your own server refused also counts under Local
  models.
- The log records only the alias. Thus the current `config.toml` also decides for all earlier
  requests.
- The collector does not read the session logs of the legacy kimi-cli.

pi, omp and opencode sessions on the Kimi Code plan also count: the `kimi-coding` provider of
pi, the `kimi-code` provider of omp (the `api.kimi.com/coding/v1` of the plan), and the
`kimi-code-plan-global` and `kimi-code-plan-cn` providers of models.dev. The pay-as-you-go API
of Moonshot (`moonshotai`, `moonshotai-cn`, omp's `moonshot`) also counts here, but these limits
do not meter it.

Claude Code turns also count here, by the [Claude Code](#claude-code) rule. These are turns sent
to `api.kimi.com`, `api.kimi.ai` or `api.moonshot.*`, or answered by a `kimi-*` or `moonshot*`
model with no `ANTHROPIC_BASE_URL`. That usage alone puts Kimi in use.

The token refresh works as follows:

- The collector refreshes expired tokens while it holds the renewable directory lock of the
  current CLI at `<home>/oauth/kimi-code.lock`. Legacy credentials use the file lock next to them.
- It writes the new token pair in one atomic operation with private permissions.
- It reads the credentials again after the exchange. Thus a sign-in or a logout that completed
  during the request has priority.
- If it cannot get the lock, it does not refresh.
- It sends credentials only to trusted Kimi HTTPS hosts, and it does not follow redirects.
- A refused token or refresh shows Sign-in expired. Run `kimi login`, or update or remove an
  overriding `KIMI_API_KEY`.
- The cache identity follows the token of the request. A refresh that this collector does keeps
  the earlier limits of the same account.
- Different credentials or endpoints never use the same cached quota.

### Cursor

Cursor keeps no token counts on the disk. Thus all data comes from the dashboard RPCs that the
Cursor CLI calls. The collector asks with the first of these that is available:

1. `CURSOR_AUTH_TOKEN`.
2. With `CURSOR_API_KEY` exported, the access token that the CLI got for that key. The collector
   never sends the key itself.
3. The sign-in that `cursor-agent login` keeps in `~/.config/cursor/auth.json`.
4. The sign-in of the editor in `~/.config/Cursor/User/globalStorage/state.vscdb` (read-only).

- `CURSOR_API_ENDPOINT` moves the endpoint. It must use https. Plain http is permitted only to
  this computer.
- If a sign-in is expired, the collector uses the next sign-in that is not expired. If all are
  expired, the limits show "Limits paused" until the CLI or the editor renews its token.
- A computer with Cursor installed but with no sign-in tells you that it waits for a sign-in. A
  computer without Cursor stays out of the panel.

The collector keeps the week of tokens for 20 seconds (15 minutes on a refresh near the limit).
After a failed check, it keeps the last good meters, plan and week of tokens of the account. The
tokens by day and by model cover the last seven local days, with one aggregation call for each
day.

The meters are the percentages of Cursor. Thus they always agree with the Cursor dashboard.

- The included total is the Monthly row. The auto-bucket meter, the named model meters and the
  on-demand budget use the same billing cycle. They show in its tooltip.
- The collector never divides spend into an allowance. The bonus usage that the model providers
  give is spend with no allowance. Thus dollars over the plan limit show much more than 100%,
  but the meters of Cursor do not.
- The on-demand meter is different. It is a real ratio: the dollars spent against the on-demand
  limit that the account sets.

### Grok Bot

Grok Bot runs on a Cursor account, but its weekly allowance has a separate meter from the Cursor
plan. The `GetSandUsageStatus` RPC of the dashboard tells how much of the included usage of this
week is used, when it resets, and the Grok plan.

- The collector asks as the same account that the Cursor collector reads. It finds the account
  in the same way: `CURSOR_AUTH_TOKEN`, the token for `CURSOR_API_KEY`, then the `auth.json` of
  the CLI, then the `state.vscdb` of the editor (read-only).
- Grok Bot keeps no data that the collector can count on the disk. Thus the record contains only
  the limit.
- An account without a Grok Bot allowance, or a computer without a Cursor sign-in, stays out of
  the panel.

### Copilot

GitHub has no supported usage API for personal accounts. Its Copilot REST endpoints are only for
organizations or enterprises. Thus the token sections come from the data that the Copilot CLI
keeps below `~/.copilot` (or `COPILOT_HOME`).

- Its session store (`session-store.db`) records each billed request in an
  `assistant_usage_events` table. Each row has the day, the model, the session, the token split
  and the cost. The cost is in nano AI units (1e9 nano units = 1 AI credit ≈ $0.01).
- A row is a billed request, not a prompt. A current CLI marks the requests that a typed prompt
  started (`initiator` "user", while the follow-up calls of the agent are "agent"). Those are the
  prompts. The counts of an older store stay out of the prompt totals of the panel.
- A request to a custom provider (BYOK, `COPILOT_PROVIDER_BASE_URL`) has no GitHub usage report,
  thus Copilot does not count it. The store does not tell where it went, thus it does not count.
- For CLI versions with an older store, the session transcripts below `session-state` supply the
  data. Their `session.shutdown` events contain the same token split and cost for each model.

The monthly meter is the account-wide allowance of AI credits from the internal quota endpoint of
GitHub. This is the same endpoint that the editor plugins ask. It counts all computers, IDEs and
agents on the entitlement, and it gives the plan and the reset date.

- It needs a token from `COPILOT_QUOTA_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN` or `gh auth token`.
- It runs only where you used the Copilot CLI. Thus a computer with a `gh` sign-in but no Copilot
  stays out of the panel.
- Each account keeps its own last answer. The answer for `gh` is kept by the user that its
  `hosts.yml` names. Thus an answer that the collector uses again does not run `gh`.
- Without a token, the section tells you that it waits for a sign-in.
- If the collector cannot ask the endpoint, a budget in `~/.config/omarchy/agents/copilot.json`
  gives a meter with the label "(est.)". This meter uses only the CLI spend of this computer:

```json
{
  "monthlyCredits": 1500,
  "remote": true
}
```

Set `remote` to `false` to stop the quota probe and the sign-in reminder. Set it to `true` to run
the probe also without a Copilot CLI home. The estimated window resets on the 1st of each month
at 00:00 UTC, which is the boundary that GitHub uses.

### Muse

Muse reads native CLI sessions from `$XDG_DATA_HOME/muse/sessions`. The default is
`~/.local/share/muse/sessions`, and `MUSE_DATA_DIR` can change it.

- The real prompt and session counts come from the `session-index.db` of the CLI, next to the
  sessions.
- If the index is missing, or has no row for a session yet, the completions replace it.
- The index keeps the running prompt count of each session. Thus the prompts of today are the
  increase of each count since the last scan before today.
- pi, omp and opencode sessions on the `meta` provider also count, and the `muse-code` provider
  of omp (its Muse Code sign-in).
- Muse Spark through the OpenCode Zen gateway counts in the `opencode` record.
- The OAuth token comes from `MUSE_AUTH_PATH` when it is set. If not, it comes from
  `~/.config/muse/auth.json`, which `muse login` makes. The collector only reads this file. It
  never refreshes or writes it.
- A Muse CLI on the computer without a login waits for one.

The subagent logs of a session add to the session. Each billed call of a child agent also counts.
Most child agents keep their own log. For a child agent without a log (a skill reminder), the
collector counts the `goal_usage_attribution` record that the log of the session keeps for it.
This usage counts on the model of the session, and it answers no prompt.

The collector asks the key endpoint of the client for the session and weekly percentages of the
subscription, with their reset times. These are the same values that the `/usage` overlay of the
TUI shows.

- The key minting gives the same result each time (the same Model API key comes back on each
  call). Thus polling is safe.
- The token goes only in the `Authorization` header. The collector does not keep the token or the
  returned key.
- `MUSE_KEY_ENDPOINT` moves the endpoint. It must use https. Plain http is permitted only to this
  computer.
- Pay-as-you-go accounts have no subscription windows and no plan name. Thus the tab shows the
  measured local usage with no meters. It never estimates the usage and never sets it to zero.
- An active plan that returns no `subs_usage` operates in the same way, but the tab keeps the plan
  name. Muse Code Power Usage answers like this on each probe.

### Antigravity

The id of the record is `agy`, which is the name that the default agent uses. The collector asks
the Google Cloud Code API for the plan and the limits, with an Antigravity sign-in on the
computer. It looks for these sign-ins:

- The sign-in that `agy` keeps in the Secret Service keyring (service `gemini`, username
  `antigravity`). Without a keyring, the sign-in is in `antigravity-oauth-token` below `AGY_DIR`.
- The `google-antigravity` sign-in of omp in `~/.omp/agent/agent.db`.
- The sign-in of pi in `auth.json` (below `PI_CODING_AGENT_DIR` when it is set).
- The `google` sign-in of opencode, only when the `antigravity-accounts.json` of the Antigravity
  plugin is there.

The collector asks with the most recently refreshed token first. If Google refuses a token, it
uses the next token. It only reads those stores.

- An expired token shows the last limits as paused until the harness that owns it runs again.
- For an expired omp sign-in, the collector asks through `omp usage`, which renews it.
- Each Google account keeps its own last answer. Thus the limits of a different account never
  show in its place.
- `CLOUD_CODE_URL` moves the endpoint. It must use https.

The local statistics count the history prompts of `agy` and its conversations. The conversation
of a subagent counts toward the conversation that started it. They also count the tokens that
each transcript step reports, under the model that the step or the last Model Selection names.
The Antigravity answers that pi, omp, OpenClaw (`OPENCLAW_STATE_DIR`) and the opencode plugin
recorded also count. A forked copy counts one time. No other collector counts these.

### Kimchi

Kimchi reads `KIMCHI_API_KEY` first, then the key in `~/.config/kimchi/config.json`.

- It asks the gateway that its region names (or `KIMCHI_BASE_URL`).
- For a self-hosted login, the gateway is `<selfHostedUrl>/llm` (or `KIMCHI_SELF_HOSTED_URL`).
  With no saved host, the collector does not ask. It never sends that key to the public gateway.
- Its sessions follow `KIMCHI_CODING_AGENT_DIR`.

The balance and the budgets show as follows:

- The credits answer gives the remaining amount but not the purchased amount. Thus the balance
  shows the remaining amount without a funded meter.
- The cap of a spend budget is the amount that you can spend, not the amount that you purchased.
  Thus it never replaces the purchased amount.
- Each budget is a limit line that resets at the end of its period. Its title is Monthly or
  Weekly when the period is a month or a week. Each capped provider in it is a tick on that line,
  or its own line in a period of a different length.
- Each endpoint has its own fallback. If the collector cannot reach one endpoint, its last answer
  stays next to the new answer of the other endpoint.
- A refused key shows Sign-in expired. Sign in again through the Kimchi CLI.
- Sessions on the disk without a key wait for a key.
- An account with no credits keeps its balance and shows Out of credits in the urgent color. Its
  help text tells you that the gateway limits its rate until it has credits again.

Only sessions on the gateway routes of Kimchi count here.

- A session that ran with `--provider openrouter` counts under OpenRouter.
- A session on a custom provider in `harness/models.json` does not count.
- The usage that other agents send through the Kimchi gateway also counts here, with all models,
  Claude and Kimi models included:
  - pi and omp sessions and opencode replies on the `kimchi`, `kimchi-dev` or
    `kimchi-experimental` provider.
  - Claude Code and Codex as `kimchi claudecode` and `kimchi codex` configure them.
- `kimchi claude` points only the Claude Code that it starts at the gateway, through its
  environment. Thus the collector cannot identify those transcripts, and they count by the name of
  their model (for example, a `kimi-*` reply under Kimi). To make them count here, run
  `kimchi claudecode` one time.
- The collector does not identify the host of a self-hosted Kimchi gateway as Kimchi. Thus Claude
  Code or Codex sent there counts as through any other gateway.

### Hermes

Hermes Agent keeps its sessions in `state.db` in its home and in each named profile below the
`profiles/` directory of its root. The home is `HERMES_HOME` with `~` and `$VAR`s expanded, or
else `~/.hermes` plus `HERMES_DATA_DIR_SUFFIX`.

- The root is the default home, unless `HERMES_HOME` is outside it. In that case, a
  `<root>/profiles/<name>` home makes `<root>` the root. All other homes are their own root.
- The root is the default profile. Thus its own `state.db` counts, also while `HERMES_HOME` points
  at a named profile.
- The collector also reads all of the default home `~/.hermes`: its own `state.db` and its
  `profiles/`.

The collector reads them read-only: the sessions, the user prompts, and the token usage for each
session and model. This includes chats that came through messaging gateways. The tokens of a
session count on the day that the session started.

Hermes records the provider and the base URL that billed each session and request.

- The tab counts the sessions that Nous Portal billed, and the sessions from before Hermes kept
  the route. A session with no route goes where its first request went.
- A server that you operate counts under Local models.
- All other providers do not count. This includes the `custom` gateways of Hermes.

Hermes has no subscription. Thus the tab shows only local statistics. Without a `state.db`, the
tab stays hidden. If the collector cannot read a database, the tab shows "Hermes unavailable".
Move the pointer on it to see the file and the error. The other profiles continue to count.

### Devin

The Devin quota comes from the cache that the Devin CLI writes each time that it starts:
`$XDG_CACHE_HOME/devin/cli/user_status.*.bin` (`DEVIN_CACHE_DIR`). The cache contains the
GetUserStatus answer that the CLI got. These are the same numbers that its `/usage` command shows.
The collector never sends a request of its own.

- Of the caches that the CLI got after the last write of `credentials.toml`, the newest is used.
  Thus after a sign-in to a different account, the quota of the earlier account never shows.
  Until the CLI runs again after a sign-in, the panel tells you this.
- A cache that is older than fifteen minutes still shows. It has the stale mark and its age. A
  window that reset after the cache shows zero.
- The daily and weekly windows show, unless the plan hides them.
- The prompt, flow and flex credits of a credit plan show as meters that reset at the end of the
  plan period.

The local statistics come from the `$XDG_DATA_HOME/devin/cli/sessions.db` of the CLI
(`DEVIN_DATA_DIR`), read-only. The tokens by model come from the metrics of each assistant
message. The prompts and sessions come from `prompt_history`.

- Some builds kept `cli_sessions.db` or `sessions.db` directly below `$XDG_DATA_HOME/devin`. The
  collector reads them only when the database of the CLI is not there. They keep one lifetime
  total for each session. This total counts on the last active day of the session.
- pi, omp and opencode sessions on the `devin` provider also count.

### Mistral Vibe

Vibe saves sessions below `~/.vibe/logs/session`. `VIBE_HOME` or `session_logging.save_dir` in the
`config.toml` of Vibe can move them.

- The current Vibe runs all sessions on its Unified Harness. It keeps each session below
  `unified/<session id>/`. The running token totals are in the public state of the generation that
  `CURRENT` names, with its journal added. The `meta.json` of the session names the alias of the
  model. The collector finds the model through the models and providers of `config.toml`, before
  the built-in default of Vibe.
- Older releases wrote one `session_*` folder for each session. Its `meta.json` contains the
  running totals and the full configuration of the run. These sessions continue to count.

Vibe also uses other providers, for example a local llama.cpp server by default. Thus a session
counts only when its model is served by the Mistral API: a provider with the `mistral` backend of
Vibe or a mistral.ai host.

- A session on a self-hosted `api_base` counts under Local models.
- A session on the host of a different provider, or on a gateway, does not count.
- For a Unified Harness session, the provider comes from the current `config.toml`. Thus the
  current file also decides for earlier sessions. An older folder keeps the configuration of its
  run.

The totals count on the day that a session started. The totals of a subagent count on the session
that started it. The prompts are the user messages that Vibe did not add itself. In a fork, the
copied history does not count. pi, omp and opencode sessions on the `mistral` provider also count
here.

The plan is the plan that Vibe last kept from the whoami answer of Mistral in
`whoami_cache.json`, with the name that Vibe uses. Mistral publishes no usage limits. Thus the
section shows only local statistics.

### Qwen Code

Qwen Code writes each session to `projects/<project>/chats/<session>.jsonl` below `~/.qwen`
(`QWEN_HOME`). `QWEN_RUNTIME_DIR` or the `advanced.runtimeOutputDir` setting can move it.

- Each billed API response is a telemetry line there, with the model and the token counts of the
  provider. Qwen Code makes its own usage statistics from the same lines, and the collector reads
  them with the same rules. The prompt count includes its cached part. Thinking is added to the
  output only where the provider counts it separately.
- The typed prompts come from the user lines. The repeated lines of a branched session count one
  time.

A reply counts here when Alibaba billed it. Qwen Code records only its auth type. Thus the
collector finds the destination as follows:

1. The `baseUrl` of the model in the `modelProviders` of `settings.json`.
2. If there is none, the base URL that Qwen Code gets from the environment: `OPENAI_BASE_URL`, or
   `ANTHROPIC_BASE_URL` for its Anthropic auth type. The collector reads these from
   `QWEN_HOME/.env`, `~/.qwen/.env` or `~/.env`, and from the `env` of `settings.json`. It cannot
   read the own `.env` of a project or the `--openai-base-url` flag.

Then:

- The Alibaba hosts (`*.aliyuncs.com`, `*.alibabacloud.com`, `qwen.ai`) and a Qwen OAuth reply
  belong to Qwen.
- A reply on a server that you operate counts under Local models.
- A reply on the API of Anthropic, Gemini or Vertex AI, on the host of a different provider, or on
  a gateway, does not count.
- An OpenAI-compatible reply with no base URL that the collector can read does not count. Qwen
  Code sends these to the OpenAI API by default. The collector cannot read an `OPENAI_BASE_URL`
  that only a shell profile exports. To make its replies count, set it in one of those files.
- Each prompt goes with the next request for it, answered or not. If there is none, it goes with
  the model that `settings.json` selects (`security.auth.selectedType` and `model.name`). Thus a
  prompt that your own server refused also counts under Local models.
- The current settings and `.env` files also decide for all earlier replies.

pi, omp and opencode turns that the Qwen plans of Alibaba bill also count here, on exact provider
ids:

- The Model Studio Coding Plan: `alibaba-coding-plan` (opencode and omp) and
  `alibaba-coding-plan-cn` (the mainland-China plan of opencode).
- The Token Plan: `alibaba-token-plan` (opencode and omp), `alibaba-token-plan-cn` (opencode), or
  `qwen-token-plan`, `qwen-token-plan-cn` and `qwen-token-plan-individual` (pi).
- The Qwen OAuth sign-in of omp: `qwen-portal`.

The pay-as-you-go `alibaba` and `alibaba-cn` keys of Alibaba have no plan. They do not count.
Claude Code sent to the Anthropic-compatible endpoint of Model Studio (an Alibaba host in
`ANTHROPIC_BASE_URL`) also counts here, by the [Claude Code](#claude-code) rule.

There is no meter. Alibaba shows the 5-hour, weekly and monthly request quotas of a Coding Plan
only on its console page. It has no documented API to read them, and Qwen Code reads none. Thus
nothing waits for a credential, and the tab shows only sessions and tokens.

### OpenCode

One record covers the OpenCode subscription, Zen and Go together: the usage on the `opencode` and
`opencode-go` providers.

- opencode sessions on an Anthropic or OpenAI provider stay in the `claude` and `codex` records.
  Thus nothing counts two times.
- The collector reads the two message stores of opencode (`message` and the V2
  `session_message`). It removes duplicates by message id, and it does not count the copies that a
  fork makes. It uses the database that `OPENCODE_DB` names, when it is set.

The Go meters use the first of these credentials that works:

1. `OPENCODE_API_KEY` or `OPENCODE_GO_API_KEY`.
2. The keys that opencode keeps in its database and in `auth.json`.
3. The keys of pi (below `PI_CODING_AGENT_DIR` when it is set).
4. The keys of omp.
5. The OpenCode Console session. The collector asks the Console endpoint with its workspace id.

- If a credential is refused, the collector uses the next credential. If all are refused, the
  record asks for a new sign-in.
- A rate-limited window shows as full.
- A key without a Go plan (Zen pay-as-you-go) causes no problem. The panel shows only the local
  token usage, and the collector does not ask with that key again for one hour.
- Without a key, the local usage shows in the same way.

### Z.ai

The Z.ai limits need a key that has a GLM Coding Plan.

- A pay-as-you-go key reports "no coding plan". This causes no problem. The panel shows only
  local statistics. The collector asks with that key again only one time each hour. A failed
  check does not show a message.
- The key comes from the first of these: `~/.config/omarchy/agents/zai.json`, then `ZAI_API_KEY` /
  `ZHIPU_API_KEY` in the environment, then the `.env` of pi/omp, then the key that pi or omp saved
  in `auth.json`.
- For the China host (`open.bigmodel.cn`), set `platform` to `"zhipu"` in the configuration.

The local statistics count these:

- pi, omp and opencode sessions on the providers of Z.ai and Zhipu (`zai`, `zhipu`,
  `zai-coding-cn`, `zhipu-coding-plan`, `zhipuai`, `zai-coding-plan`, `zhipuai-coding-plan`).
- Claude Code turns sent to `api.z.ai` or `open.bigmodel.cn`, or answered by a `glm-*` model with
  no `ANTHROPIC_BASE_URL`, by the [Claude Code](#claude-code) rule.
- MiniMax Code replies on a custom provider (its Z.AI preset) at those hosts.

### Ollama Cloud

Ollama Cloud reads `OLLAMA_API_KEY` first. Then it reads `apiKey` in
`~/.config/omarchy/agents/ollama.json`. Then it reads the key that pi or omp used to sign in, in
`~/.pi/agent/auth.json` (or below `PI_CODING_AGENT_DIR`) or `~/.omp/agent/auth.json`. Each key
keeps its own last good limits and plan.

The balance endpoint of Ollama (`/api/balance`) reports these values:

- For a legacy plan: the session and weekly windows, as the remaining percentage, with their reset
  times.
- For a current plan: the included credits as a balance against the monthly allowance. This shows
  as an Included credits meter that resets at the end of the period.
- Credits that you purchased in addition to the plan (`purchased.balance_usd`, the unexpired
  credits that remain) show as a balance of the remaining amount. The answer does not tell the
  purchased amount. Thus there is no low-balance alarm.

The limits cover the full account: all models that the key can use. The local statistics count
these:

- pi, omp and opencode sessions on the `ollama-cloud` provider.
- Cloud-tagged models (`glm-4.6:cloud`, `gpt-oss:120b-cloud`) through the `ollama` provider of the
  local daemon. These models also run on the Ollama servers.
- The same models from Codex `--oss` rollouts, with the prompts typed in them, and all models on a
  Codex provider with the name `ollama-cloud`.
- Claude Code turns sent to `ollama.com` or answered by a cloud-tagged model, by the
  [Claude Code](#claude-code) rule.

To count only the Claude models that Ollama Cloud serves, set a model prefix in
`~/.config/omarchy/agents/ollama.json`:

```json
{
  "modelPrefix": "claude",
  "apiKey": ""
}
```

`modelPrefix` limits the local statistics to the models with a name that starts with the prefix.
An empty prefix means all models. `apiKey` is a separate key. The collector uses it when
`OLLAMA_API_KEY` is not set.

### MiniMax

MiniMax reads `MINIMAX_API_KEY` first. Then it reads the API key or the OAuth session that the
`mmx` CLI of MiniMax saved, if you use it. Then it reads the key that opencode, pi or omp keeps
when MiniMax has a sign-in there.

- The collector reads a key only from the provider ids of MiniMax. It never reads a similar id,
  for example a custom gateway.
- The host follows the source of the key:
  - The key of `mmx` uses the host that `mmx` asks: its `base_url`, then its OAuth resource URL,
    then its region. `MINIMAX_REGION` overrides the region.
  - An opencode, pi or omp key on a `minimax-cn` provider uses the China host.
  - All other keys use the global `https://api.minimax.io`.
  - `MINIMAX_BASE_URL` overrides all of these.
- The quota request never follows a redirect. Thus the key stays with the MiniMax host.
- The windows are the windows of the `general` quota, or of the first model that is not a media
  model. The collector ignores models that mmx shows as not in the plan.
- A window that MiniMax marks as exhausted shows as full, independent of its percentage. An
  unlimited window shows no meter.

The local statistics count the sessions of MiniMax Code below `MINIMAX_DATA_DIR`,
`MAVIS_DATA_DIR` or `~/.minimax`. User messages are prompts, and assistant replies are tokens.

- Only replies on the routes of MiniMax (`minimax` and `minimax_api`) count, with the prompts that
  they answered.
- MiniMax Code has custom providers (`custom_provider:<name>`), with its Z.AI and OpenRouter
  presets. The operator of the `options.baseURL` of that provider in `config.yaml` bills a reply
  on it:
  - At the MiniMax host, it counts here.
  - At the hosts of Z.ai, Ollama Cloud, DeepSeek, Kimi or OpenRouter, it counts under their
    collectors.
  - On this computer or the LAN, it counts under Local models.
  - On a gateway that the collector cannot identify, or on a provider that is not in the
    configuration now, it does not count.
  - The current configuration also decides for all earlier replies.
- pi, omp and opencode sessions on a MiniMax provider also count.

Without a key, the panel still shows that local usage. It waits for a key to show the limits.

### OpenRouter

OpenRouter reads the first of these keys:

1. `OPENROUTER_API_KEY`.
2. The key that opencode keeps in `~/.local/share/opencode/auth.json`.
3. The key that pi (`~/.pi/agent/auth.json`, with `PI_CODING_AGENT_DIR`) or omp
   (`~/.omp/agent/auth.json`) saved when OpenRouter has a sign-in there.
4. `apiKey` in `~/.config/omarchy/agents/openrouter.json`.

- Without a key, the local pi, omp and opencode usage on the OpenRouter provider still shows. The
  panel waits for a key to show the balance and the meter.
- You can set a management key in `OPENROUTER_MANAGEMENT_KEY`, or as `managementKey` in that
  file. Get it from `openrouter.ai/settings/management-keys`. The token history then comes from
  the account-global `/activity` API, not from the local scan. Alone, a management key also reads the
  balance, with no key-limit meter.
- The documentation of OpenRouter says that only a management key can use `/credits`. If an
  inference key gets the answer 403, the panel shows its key-limit meter without a balance. This
  is not a sign-in problem. If you also have a management key, that key reads the balance.

The collector reads the prepaid ledger from `GET /api/v1/credits`
(`remaining = total_credits - total_usage`). It reports it as a live balance that is not an
estimate.

- The collector asks that endpoint one time for each refresh, with the management key if there is
  one.
- With only an inference key, it asks until OpenRouter refuses the key in that way. The panel then
  shows no balance, not a refused key. The collector does not ask again for one day.
- A key with a credit limit also gets a key-limit meter from `GET /api/v1/key`. The meter
  decreases, and its label tells how frequently the limit starts again.
- Each key keeps its own last good meter and balance.

The token history has two levels. The type of key selects the level automatically:

```json
{
  "apiKey": "",
  "managementKey": ""
}
```

- Without a management key, the tokens come from these sources:
  - The local opencode database (`providerID == "openrouter"`, read-only).
  - pi/omp sessions with assistant messages on the `openrouter` provider, and Kimchi harness
    sessions that ran with `--provider openrouter`.
  - DeepSeek Harness attempts on its pi-ai `openrouter` route.
  - MiniMax Code replies on a custom provider at `openrouter.ai`.
  - Claude Code turns while `ANTHROPIC_BASE_URL` points at `openrouter.ai`, by the
    [Claude Code](#claude-code) rule.
- With `OPENROUTER_MANAGEMENT_KEY` (or `managementKey` in `~/.config/omarchy/agents/openrouter.json`),
  the last 30 days come from `GET /api/v1/activity`. These are account-global tokens by day and by
  model, and they cover all computers and clients. That record contains `"scope": "account"` and
  `hasPromptStats: false`, as Fireworks does. Thus the synced aggregation merges it by the widest
  value. It does not add it.

### DeepSeek

DeepSeek reads the first of these keys:

1. `DEEPSEEK_API_KEY`.
2. The key that pi keeps in `~/.pi/agent/auth.json` (below `PI_CODING_AGENT_DIR` when it is set).
3. The `~/.omp/agent/auth.json` of omp. The collector never uses a `!command` or `$VAR` entry.
4. The key that opencode keeps in its own `auth.json` when DeepSeek has a sign-in there.
5. The key that DeepSeek Harness keeps in `$DSH_HOME/.credentials.yaml` (or the `.env` next to
   it). `$DSH_HOME` is `~/.dsh` by default.

- Each key keeps its own last balance.
- DeepSeek gives one balance for each currency (CNY or USD). The panel shows the balance that has
  credit, or the first balance when none has credit.
- DeepSeek can tell that the balance does not cover API calls (`is_available` false). In that
  case, or when the credit is spent, the status shows Out of credits in the urgent color.

The local usage also counts these:

- The session logs of dsh below `$DSH_HOME/sessions` on its DeepSeek routes
  (`deepseek-official`, `deepseek-account`, and the `deepseek` route of its pi-ai adapter). The
  history that a forked session gets from its source does not count.
- Claude Code turns sent to `api.deepseek.com` or answered by a `deepseek-*` model, by the
  [Claude Code](#claude-code) rule.

The other pi-ai routes of dsh are billed by their provider. Its `openrouter` route counts under
OpenRouter. A gateway that you declare manually does not count.

The `fundedAmount` estimate is in `~/.config/omarchy/agents/deepseek.json`, with the same shape
that the fireworks collector uses. Without it, the panel shows the live remaining credit and does
not show the funded-versus-spent line.

### Fireworks

Fireworks reads the first of these:

1. `FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID`.
2. `~/.fireworks/auth.ini`, which `firectl set-api-key` makes.
3. The key that pi keeps in `~/.pi/agent/auth.json` when Fireworks has a sign-in there (with
   `PI_CODING_AGENT_DIR`, and the literal and `$ENV_VAR` key forms of pi).
4. The key that opencode keeps in `~/.local/share/opencode/auth.json`.

The collector first asks the `:getBalance` endpoint of the account for the real prepaid ledger.

- That endpoint exists, but it needs a permission. In August 2026, no API key from the console has
  that permission. Fireworks possibly keeps it for the dashboard session.
- The probe stays because it costs little. If Fireworks gives keys access, the live value shows
  automatically.
- Until then, the collector estimates the balance from the configuration in
  `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

To configure the estimate:

1. Set `fundedAmount` to the purchased credits.
2. Optionally, set `fundedAt` to the purchase date. Without a date, the collector uses the time
   that the account was made.

The collector subtracts the rated account costs. The panel shows the result as an estimate.

- For a later top-up, increase `fundedAmount` by the new credit and keep the original `fundedAt`.
  Thus the funding and the spend cover the same period.
- `accountId` is necessary only when one API key can use several accounts.
- Without a `fundedAmount`, the tab still shows the token usage, but no balance.
- With a live ledger, `fundedAmount` is optional. It only adds the meter and the spent-of-funded
  line below the real value.

Each API key keeps the last good usage rows and balance of its account. A different key or
account never shows them. The collector reads the usage again a maximum of one time each
20 seconds (15 minutes on the refresh of the panel near the limit). A refused key shows as an
expired sign-in. With no key, the tab stays hidden. Its statistics come from the billing API of
the account. Thus they already include the pi and opencode usage of this computer, and no local
scan adds them again.

### Synthetic

Synthetic reads `SYNTHETIC_API_KEY` first. Then it reads the key that pi keeps in
`~/.pi/agent/auth.json` (with `PI_CODING_AGENT_DIR` and `$ENV_VAR` keys), then the
`~/.omp/agent/auth.json` of omp, then the `auth.json` of opencode.

- The collector asks the documented `GET https://api.synthetic.new/v2/quotas`. This request does
  not count against the quotas.
- The rolling five-hour request limit and the weekly credits come back a small amount at a time.
  Thus they show the used amount with no reset time.
- The hourly search and the free tool calls reset when Synthetic tells that they renew.
- An account without the credit system shows the documented subscription request bucket.

The local statistics count these:

- pi and omp sessions and opencode messages on the `synthetic` provider.
- Through `scan_routed()`, the Claude Code, MiniMax Code and Codex usage sent to the Synthetic API
  at `api.synthetic.new`. This is its Anthropic-compatible `/anthropic` and its OpenAI-compatible
  `/openai/v1`, as its guides set them up.
- Claude Code replies by an `hf:` or `syn:` model with no `ANTHROPIC_BASE_URL` override.

### Local models

The Local models section counts work that ran on hardware that you own. These are Codex rollouts,
pi and omp sessions, and opencode messages with one of these providers:

- A well-known local runtime (Ollama, LM Studio, llama.cpp, vLLM, ...).
- A provider that `~/.config/omarchy/agents/local.json` names.
- A Codex `model_providers` entry with a `base_url` on a loopback, private, link-local or LAN
  address.

```json
{ "providers": ["homelab", "my-gateway"] }
```

A Codex rollout records the id of its provider but not the URL that it used. Thus the collector
keeps each `model_providers` endpoint that it saw in `/etc/codex/config.toml`, `config.toml` or the
`<name>.config.toml` of a profile. It keeps them in
`~/.local/state/omarchy/agents/local-codex-providers.json`.

- The history of a provider stays local after the provider is removed from the configuration.
- All provider collectors read the same map. Thus an entry at the API of a provider counts there,
  also after it is removed from the configuration.
- The collector never sees a provider that you give only with `codex -c model_providers...` or in
  the `.codex/config.toml` of a project. Name such a provider in `local.json`.

This collector is the exact complement of the provider collectors:

- A provider id that a different collector counts never counts here, independent of
  `local.json`. That collector counts it, one time.
- The exception is a Codex `model_providers` entry. Its `base_url` decides, independent of its id.
  Thus an entry with a claimed id on your own hardware counts here. An example is the
  `kimchi codex` setup of a self-hosted Kimchi gateway.
- The Codex collector keeps all rollouts on the built-in `openai` provider. The exception is the
  models that a self-hosted `openai_base_url` served (refer to [Codex](#codex)).
- Two providers are claimed only for some models, and only those rows are not counted here:
  - The cloud models of Ollama (a `:cloud` or `-cloud` tag) run on the Ollama servers, also
    through the local daemon. Thus they count under Ollama Cloud.
  - The Antigravity plugin of opencode records a `google` provider with `antigravity-` models. The
    Antigravity collector counts them.

The prompts of a Codex rollout are the prompts that you typed. The thread of a subagent or a
guardian starts no session. The collector reads them as the Codex collector does.

These also count here:

- Claude Code, while `ANTHROPIC_BASE_URL` is self-hosted (Ollama's `http://localhost:11434`, a
  computer on the LAN). This is by the [Claude Code](#claude-code) rule. It applies to all models
  except Claude models and cloud-tagged models. A local gateway sends Claude models on to
  Anthropic.
- MiniMax Code replies on a custom provider with a self-hosted `baseURL`.
- By the same rule, Kimi Code, Qwen Code, Hermes and Mistral Vibe requests with a self-hosted
  recorded base URL. The collector of each agent reads them.

There are no limits and no balance.

## Interactions

- **Bar icon**: left = panel, right = start agent, middle = refresh. The icon becomes urgent
  when an account that new sessions use is at 90% of a window, or when a prepaid balance has only
  10% left.
- **Panel**:
  - The arrows (or `h`/`j`/`k`/`l`) move a cursor across all items that do something, row by
    row. These items are the buttons of the hero, the header of each agent, and each account that
    you can change to. On an account, the cursor goes to Use, with Autoswitch to its left. The
    last items are the starter tiles, or the agents to add.
  - Ctrl+Up/Down (or Ctrl+`k`/`j`) moves the agent of the cursor up or down the page. To do the
    same, drag an agent by its mark. The header where it will go is highlighted.
  - The panel keeps the order in `~/.local/state/omarchy/agents/order.json`.
  - The pointer moves the same cursor.
  - Enter does the action of the cursor. If no item is highlighted, Enter refreshes.
  - `r` refreshes, Tab moves to the next bar panel, and Esc closes the panel.
- **Accounts**:
  - `1`–`9` go to an account in all agents. Enter makes that account active. The selection alone
    does not change the account.
  - `m` sets automatic switching on or off for the agent of the selected account.
  - When an agent with several accounts has its active account within 15 points of its switch
    threshold (80% by default), the limits refresh every three minutes.
- **IPC**: `omarchy-shell omarchy.agents <open|close|toggle|refresh>`.

## Settings

The settings are in the entry of the widget in `~/.config/omarchy/shell.json`. To set the
top-level keys, use `omarchy bar set omarchy.agents <key> <value>`:

| Key | Default | Function |
|---|---|---|
| `refreshIntervalSec` | `900` | The time between the updates of the usage records |
| `syncMode` | `"Off"` | `"On"` writes the snapshot of this computer and merges the other snapshots |
| `syncDir` | `""` | A folder that Syncthing, Dropbox, rsync, … synchronizes |
| `syncFileName` | `<hostname>.json` | The snapshot file of this computer |
| `syncDeviceId` | hostname | A stable device name in the snapshot |

Numbers need `--json`. If not, they go into `shell.json` as strings:

```bash
omarchy bar set omarchy.agents refreshIntervalSec 300 --json
omarchy bar set omarchy.agents syncDir '~/Sync/agent-usage'
```

The enablement of each agent is nested. `set` writes its key literally and does not follow a
dotted path. Thus give the full `providers` object as JSON, or change `shell.json` directly:

```bash
omarchy bar set omarchy.agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": false },
  "fireworks": { "enabled": true },
  "kimchi": { "enabled": true }
}' --json
```

`enabled` is `true` by default for all agents that the collectors find. To hide an installed
subscription, set it to `false`. The collectors also ignore disabled agents when they update the
records.

With `syncMode` on, the panel merges all `*.json` snapshots in `syncDir`.

- Thus today, the last 7 days and the all-time totals cover all computers that you use for code.
- The panel joins active days by date. It does not add them.
- Rate limits stay with each account. The panel never merges them.
- A record can declare `"scope": "account"` when its statistics are account-global, not local to
  the computer (the billing API of Fireworks). The panel merges these by the widest value and
  does not add them. Thus the same account, synced from two computers, does not count two times.

NOTE: The "all-time" totals are not always complete. The Codex collector reads only native
session files that changed in the last 30 days. Fireworks asks its billing API only for the last
30 days. Thus their totals and day counts cover only that period. The totals of Claude and Muse
cover all sessions that are still on the disk.
