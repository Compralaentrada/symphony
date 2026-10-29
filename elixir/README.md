# Symphony runtime (Elixir)

This directory contains the Elixir/OTP service used by the Compralaentrada project. It coordinates
work from GitHub Projects v2 across configured repositories and runs the Build → QA → Review
pipeline with Codex.

The checked-in [`WORKFLOW.md`](WORKFLOW.md) is configured for this repository's pilot. Review its
Project, repository profiles, credentials, and Codex permissions before using it on another
installation.

## How it works

1. Reads eligible issues from the configured tracker. The current pilot uses GitHub Projects v2;
   adapters are also available for GitHub Issues, Linear, Jira Cloud, Asana, and GitLab.
2. Creates an isolated workspace for each issue. GitHub Projects executions include the Project,
   item, repository, and issue number in their identity, so same-number issues in different
   repositories keep separate workspaces and pull request lookups. Then Symphony launches Codex in
   [App Server mode](https://developers.openai.com/codex/app-server/).
3. Runs Build, QA, and autonomous Review in separate sessions for ordinary GitHub Projects work;
   issues labelled `qa` start in QA and continue to Review using an existing pull request.
4. Verifies configured QA checks, prepares a pull request for human review, and waits for the
   merge or a request for corrections.

## GitHub write ownership

As recorded in [ADR-0002](../docs/adr/0002-agentes-propietarios-de-escrituras-github.md), the agent
handling a GitHub Issues run or Projects phase owns the writes for its issue and pull request.
GitHub agents use the host-mediated `github_workflow` tool for lane-authorized writes; the
`github_api` tool is read-only and scoped to the task repository. Symphony keeps credentials on the
host, verifies remote evidence, and reconciles the resulting state. Build pushes through the host's
Git credential helper or SSH. Configure push access for each repository profile on the Symphony
host.

Local runs discover repo-local Codex skills from `.agents/skills` in the workspace checkout.
Symphony checks selected skills before launching Codex and reports a missing `SKILL.md` path; pinned
sources and fingerprints are listed in [`../.agents/skills/SOURCES.md`](../.agents/skills/SOURCES.md).

In the Projects pipeline, Symphony owns the Build, QA, and Review role prompts and base skill
assignments; installation `WORKFLOW.md` front matter cannot remap them. Task-specific skills are
selected from issue context. Unattended sessions load only selected task skills; separate workflow
instructions can still request operational skills. Interactive skills such as Impeccable and TDD
are not forced into unattended sessions.

During single-run app-server sessions, the selected tracker adapter may advertise provider-native
tools. Linear serves `linear_graphql`, GitHub Issues and GitHub Projects v2 serve the read-only
`github_api` plus the task-scoped `github_workflow`, Jira Cloud serves `jira_rest`, Asana serves
`asana_api`, and GitLab serves `gitlab_api`. Symphony executes tools with configured host-side auth
and removes declared tracker-token environment variables from the Codex child. GitHub workflow
permissions are restricted by repository, issue, lane, lease, and operation.

If a claimed issue moves to a configured terminal state, Symphony stops the active agent and cleans
up its workspace. In GitHub Projects mode, closing the linked GitHub Issue is terminal; Project
items in Done or Blocked keep their workspace so moving them back to Ready can resume prior work.
When a successful ID refresh omits a running issue, Symphony keeps the same agent, claim, and
workspace after the first omission. A visible active refresh clears the counter; a second
consecutive omission stops the agent and releases its slot while preserving the workspace. Tracker
read errors do not count as omissions. The log records the issue, consecutive omission count, and
number of normalized issues returned.
Before QA or Review starts, Symphony compares the remote PR head and clean workspace with the
Build-accepted SHA. A missing or changed PR head, a mismatched workspace, or uncommitted workspace
changes creates a blocker report before the agent starts. When a Blocked item from QA or Review is
moved to Ready, a changed or missing PR head clears the accepted SHA and restarts at Build to rerun
QA and Review. Transient tracker read errors keep the existing retry behavior.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. For the durable
Projects pipeline, phase checkpoints and external-operation records are stored in SQLite at
`~/.symphony/pipeline.sqlite3`; GitHub agent writes are verified remotely before Symphony advances
the checkpoint. If a nonterminal checkpoint no longer matches the tracker state, Symphony records a
local blocker with the reason and leaves the tracker unchanged; moving the item to Ready resumes the
preserved work. After the independent QA review, Symphony runs every `required_checks` command from
the repository profile in the task workspace and gives the evidence to the QA agent; missing or
failed host checks cannot pass QA.
A merge into the configured base branch is required before Symphony sets Done. Moving a Human Review
item back to Ready requests corrections on the same branch and PR. To move unmerged work to Dropped,
add a human-authored `Drop reason: <reason>` line to the issue body; after a `no_changes` result,
this line confirms the decision to discard the work.

With `merge_policy: auto`, Review invokes the deterministic merge gate. It requires the reviewed PR
head SHA, the current base SHA, an approved Review for the current attempt, and successful host checks.
If GitHub reports checks, they must also pass. The gate stops when GitHub cannot
confirm any of that state. When the gate passes, Symphony merges the PR and verifies that GitHub
reports it merged before closing the issue and moving the Project item to Done. Symphony never
approves PRs automatically; a rejected gate leaves the PR in Human Review.
For automatic Review, a handoff retried after the item has already reached Human Review is rejected:
the runtime cannot distinguish a completed transition from a human move to that state. After a
restart, reconciliation retains Human Review without merging and waits for a human decision.

Pipeline phase reports use Markdown in Spanish when the issue is Spanish, and English for English,
unsupported, or ambiguous issue languages. Reports omit empty sections and distinguish blocked
phases from checks that did not run. QA reports map each issue acceptance criterion to a status,
test or procedure, and evidence reference. Agent checks include their test layer, exact command,
result, and status; Symphony records its required checks separately as host evidence. QA also records
coverage gaps by scenario, impact, missing coverage, and risk priority. Review checks the latest QA
report against the issue criteria, accepted SHA, and required host checks before advancing.

## Prerequisites

Use [mise](https://mise.jdx.dev/) for Elixir/Erlang and install Codex CLI with App Server support.
The host also needs Git credentials for every configured repository and a `GITHUB_TOKEN` that can
read the Project and linked issues.

```bash
mise install
mise exec -- elixir --version
```

## Run the pilot

```bash
git clone https://github.com/Compralaentrada/symphony.git
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix run --no-start --no-halt -e 'SymphonyElixir.CLI.main(["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", "4000", "./WORKFLOW.md"])'
```

The local Mix run loads Exqlite's native SQLite library from the compiled dependency. Do not build
or run an escript; its archive cannot provide the NIF used by the pipeline journal.

## Release builds

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/Compralaentrada/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix; the release
notes identify the source commit.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-vX.Y.Z-macos_arm64
./symphony-vX.Y.Z-macos_arm64 --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

## Configuration

The pilot configuration is in [`WORKFLOW.md`](WORKFLOW.md). Its YAML front matter configures the
tracker, repository profiles, workspace, agent limits, and Codex command; the Markdown body is the
agent prompt. Adapt the Project and repository profiles before pointing the service at another
installation. Do not commit literal credentials; use environment variables such as `$GITHUB_TOKEN`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`). All
  events go to `symphony.log.1`; warnings and errors are also copied to `symphony-errors.log.1`.
  Rotated segments use the same base names with suffixes `.2` through `.5`.
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

For a complete configuration, start from [`WORKFLOW.md`](WORKFLOW.md) and replace its pilot
Project and repository profile with the values for your installation. The adapter sections below
describe the supported tracker settings.

Notes:

- If a value is missing, defaults are used.
- `merge_policy` accepts `human` (the default) or `auto`; set `auto` explicitly to opt in.
  A top-level value takes precedence over `tracker.provider.merge_policy`; when omitted, an
  explicit provider value remains supported. Symphony never approves pull requests automatically.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- GitHub Projects v2 uses Project status for routing and rejects `required_labels`. Its repository
  profiles define the exact repositories Symphony may work in, the base branch, and a preparation
  command for new workspaces. To enable the durable Build → QA → Review pipeline, configure the
  `qa`, `review`, `human_review`, and `dropped` status values, include the active phase statuses in
  `tracker.active_states`, include `Dropped` in `tracker.terminal_states`, and set nonempty
  `required_checks` for each repository profile. The Symphony host also needs Git push credentials
  for each profile; pipeline agents do not receive the tracker token. Symphony selects the profile
  from the linked repository and checks its preparation command and base branch for that task. A
  missing profile requirement, inaccessible repository, unavailable base branch, or failed setup
  blocks tasks for that repository with a diagnostic; other configured repositories remain usable.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- In GitHub Projects mode, each profile's `prepare_command` runs in a new empty workspace and must
  create the repository at `.`. It receives `SYMPHONY_REPOSITORY`, `SYMPHONY_BASE_BRANCH`,
  `SYMPHONY_ISSUE_ID`, and `SYMPHONY_ISSUE_IDENTIFIER`; Symphony then creates the issue branch from
  the configured base branch. The profile command replaces `hooks.after_create` for that workspace.
  Requeues reuse an existing workspace without rerunning either command. When Build resumes without
  an accepted SHA, Symphony fetches the issue branch and fast-forwards it when possible. If local and
  remote work diverged, the branch is missing from both, or local changes prevent the update, Build
  records the blocked report and Project status without resetting the workspace. QA and Review check
  that the PR head and clean workspace still match the accepted Build SHA before starting the agent.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/delivery`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- `GET /api/v1/delivery` returns persisted pipeline tasks alongside a current tracker lookup by
  stable issue ID. `tracker_issue.lookup` is `found`, `missing`, or `error`; the tracker issue's
  title, URL, and state are returned separately from the pipeline task.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.

### GitHub Projects v2 adapter profile

```yaml
tracker:
  kind: github_projects
  active_states: [Ready, Building, QA, Review, Human Review]
  terminal_states: [closed, Dropped]
  provider:
    owner: your-user-or-organization
    project_number: 12
    token: $GITHUB_TOKEN
    repositories:
      - repository: your-org/api
        base_branch: main
        required_checks:
          - mix test
        prepare_command: |
          gh repo clone "$SYMPHONY_REPOSITORY" .
          mise trust
          mise exec -- mix deps.get
```

- `owner` and `project_number` identify a user or organization Project. Symphony uses its `Status`
  single-select field and canonical options: Backlog, Ready, Building, QA, Review, Human Review,
  Blocked, Done, and Dropped.
- `token` defaults to `GITHUB_TOKEN` and accepts `$ENV_VAR`; never put a literal token in
  `WORKFLOW.md`. The token needs access to read and update the Project and linked issues.
- `active_states` must include Ready, Building, QA, Review, and Human Review. `terminal_states` must
  include `closed` and Dropped, leaving Done and Blocked requeueable.
- Only Ready Project items linked to native GitHub Issues with an exact repository profile are
  dispatched. Pull requests, draft issues, and unsupported item types are ignored. An unconfigured
  repository is moved to Blocked and receives a comment explaining the missing profile.
- Work identity is `owner/repository#number`. Claiming moves Ready to Building, successful completion
  moves Building to Done, and intervention-required failures move to Blocked with a comment. Transient
  failures retry on the existing backoff path.
- A rejected GitHub handoff or a phase report with no handoff attempt gets one correction turn in
  the same session; another rejection uses the normal retry path. A successful handoff without
  returned evidence fails normally instead of risking a duplicate remote write.
- Native GitHub `blocked by` relations populate `issue.blocked_by` with `owner/repository#number`
  identities. Incomplete or failed blocker reads fail the Project refresh instead of dropping
  dependency data.
- Project items can belong to either a user or organization Project. The optional `graphql_url`
  setting defaults to `https://api.github.com/graphql`.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView dashboard at `/` with Operations and read-only Delivery views
- Delivery lists pipeline tasks with the current title, status, and issue link from the configured tracker
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
MIX='mise exec -- mix' make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
MIX='mise exec -- mix' make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir/OTP provides supervision and fault isolation for the long-running scheduler and its workers.
SQLite checkpoints let the Projects pipeline resume after a service restart.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
