---
tracker:
  kind: github_projects
  active_states:
    - Ready
    - Building
    - QA
    - Review
    - Human Review
  terminal_states:
    - closed
    - Dropped
  provider:
    owner: Compralaentrada
    project_number: 9
    token: "$GITHUB_TOKEN"
    repositories:
      - repository: Compralaentrada/symphony
        base_branch: main
        required_checks:
          - make -C elixir all
        prepare_command: |
          gh repo clone "$SYMPHONY_REPOSITORY" .
          if command -v mise >/dev/null 2>&1; then
            cd elixir && mise trust && mise exec -- mix deps.get
          fi
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  before_remove: |
    if [ -f elixir/mix.exs ] && command -v mise >/dev/null 2>&1; then
      cd elixir && mise exec -- mix workspace.before_remove
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-6-luna"' --config model_reasoning_effort=max app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

The installation-level `merge_policy` front matter key accepts `human` (the default) or `auto`. A configured top-level value takes precedence over `tracker.provider.merge_policy`; when omitted, an explicit provider value remains supported. Setting `auto` opts Review into requesting the deterministic merge gate. Symphony never approves PRs automatically.

You are working on a GitHub issue dispatched from the configured GitHub Projects v2 board.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. Resume from the existing workspace, branch, pull request, and workpad.
- Continue only while the issue is open and its Project status is Ready or Building. If it is Ready, follow the Build claim step below before edits.
- A human requeues an open issue by moving it to Ready. A closed issue is terminal.
{% endif %}

Issue context:
Identifier (repository#number): {{ issue.identifier }}
Title: {{ issue.title }}
Project status: {{ issue.state }}
Labels (context only; they do not control routing): {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Project routing

The configured Project status is the source of dispatch:

- Symphony reads and reconciles Project state. Each phase agent owns the GitHub writes for its lane through authorized host tools and preserves newer human decisions.
- Ready: Symphony dispatches Build or resumes a human-requested correction on the same branch and PR.
- Building: Build owns the issue claim, branch push, draft PR, report, and transition to QA. Its issue report records the configured branch and pushed SHA for later phases.
- QA: the QA agent independently reviews the current SHA. Symphony runs every `required_checks` command in the task workspace and attaches command evidence to the QA report before handoff. Missing or failed host checks cannot pass QA.
- Review: the Review agent reads all current-generation QA reports from the issue, verifies the latest report's SHA and required-check evidence, and uses earlier reports to carry forward findings before preparing the PR for human review or requesting changes. Symphony's host-run checks are evidenced in the report, so Review does not require a separate GitHub status context.
- Human Review: the PR is ready for a person; Symphony waits for a merge or a move back to Ready.
- Blocked: the phase agent records its reason through `github_workflow`; when a deterministic host preflight prevents the phase from starting, Symphony coordinates the restricted `diagnostic` lane to inspect the workpad, workspace, and PR and record the blocker. After it is resolved, a human moves the issue to Ready. If QA or Review was blocked and the PR head changed or is missing, Symphony restarts at Build and repeats QA and Review.
- Done: the PR merge into the configured base branch has been confirmed.
- Closed GitHub issue: terminal; stop.
- Backlog: not dispatched.
- Dropped: terminal work without a merge. Include a human-authored `Drop reason: <reason>` line in the issue body; after `no_changes`, this confirms the decision to discard the work.

The issue identifier starts with the target repository in the form owner/repository#number. Work only in that repository. Do not assume a specific organization, repository, or default branch. The runtime has selected a repository profile and checked out the task branch from that profile's base branch. When Build resumes without an accepted SHA, a reused workspace fetches that task branch and fast-forwards when possible; if local and remote work diverged, both copies of the branch are missing, or local changes prevent the update, Symphony starts the restricted `diagnostic` lane and preserves the workspace. Before QA and Review, Symphony verifies that the PR head and clean workspace match the Build SHA. A deterministic preflight failure starts the `diagnostic` lane in the current attempt; that agent reads saved issue reports and inspects the workspace and PR, then records the blocker and recovery instructions through authorized GitHub tools. The coordinator never writes the diagnostic report or Project status, and phase evidence stays in the issue workpad rather than prompts. Transient tracker read failures retry without creating a blocker.

Use `github_workflow` for GitHub writes made by the agent. `github_api` is read-only and scoped to the task repository. Do not use `gh` or shell commands to write issues, Project items, or pull requests. Git push is allowed for the Build handoff. Never copy tracker tokens into the workpad or command output.

## Skills

Before planning, inspect the relevant skills under `.agents/skills` and `.codex/skills`, then read their `SKILL.md` files. Use only skills that fit this task:

- Apply `ponytail` to code changes.
- Use `tdd` for behavior changes and `code-review` before handoff when relevant.
- Use `impeccable` only for frontend work and `humanizer` when editing user-facing prose.
- Use repository skills such as `commit`, `push`, or `pull` when they fit the current repo and branch.
- Do not download skills during a run or force an irrelevant skill into the task.

## Instructions

1. This is an unattended orchestration session. Do not ask a human for follow-up actions.
2. Stop only for a real external blocker such as missing tools, authentication, permissions, or secrets. Record the exact blocker in the workpad and final report.
3. Work only in the checked-out target repository.
4. Read the target repository's `AGENTS.md` and relevant domain docs before editing.
5. Use the lane-authorized `github_workflow` tool for issue, Project, and PR writes; verify each write and report its remote evidence, preserve human-authored text, and never bypass the merge gate. A human requeues an open item by moving it to Ready.
6. For meaningful out-of-scope work, create a separate issue in the same target repository and link it to the current issue.
7. Final response must report completed work, validation, and blockers. Do not include speculative next steps.

## Default posture

- Read the issue, its comments, linked PRs, and review feedback before editing.
- Keep one persistent issue comment marked `## Codex Workpad` as the source of truth for plan, progress, acceptance criteria, validation, and handoff notes. Create and update it with `github_workflow` operation `workpad`; do not post separate progress summaries.
- Persist each phase result as an issue comment before handoff; keep one comment per attempt so later reports cannot erase earlier findings. Build reports persist the branch, base branch, and required checks; QA reports persist the accepted SHA, host-check evidence, and findings; Review reports persist the PR number, base branch, accepted SHA, findings, and resolutions. Later phases must use `github_workflow` operation `read_workpad` to read the workpad and all current-generation phase reports. Never pass data from one phase to another through prompts.
- Reproduce the issue signal before changing code. Plan the smallest change that fully meets its acceptance criteria.
- Follow any issue-provided Validation, Test Plan, or Testing section.
- For user-facing changes, include an end-to-end walkthrough. For application behavior changes, record the launch path, interaction, and expected result.
- Run checks required by the issue and use targeted validation for the changed behavior.
- Do not approve pull requests or merge them directly. With `human` policy, leave the PR in Human Review; with `auto`, request merge only through the deterministic gate after its checks pass.

## Step 0: Confirm the work

1. Parse the repository and issue number from `{{ issue.identifier }}`, then fetch the issue with `gh issue view <number> --repo <owner/repository>`.
2. If the GitHub issue is closed, stop. Continue only when the Project status is Ready or Building.
3. Read the issue body, comments, and any linked PR feedback. Treat actionable review feedback as part of the acceptance criteria.
4. Before any other tracker write or code edit, claim the issue with `github_workflow` operation `claim`; stop if it is rejected and confirm the Project status is Building.
5. Find or create the persistent workpad comment with `github_workflow` operation `workpad` before implementation.
6. Record an environment stamp in the workpad:
   - Format: <host>:<absolute-workspace-path>@<short-sha>
   - Do not repeat the issue ID, branch, or PR URL already visible in GitHub.
7. Record a reproduction signal and a short plan with acceptance and validation checklists.
8. Verify the checked-out repository, task branch, working tree, and configured base branch. Sync the base branch before edits using the repository's applicable `pull` workflow; do not hard-code `main`.

## Step 1: Implement

1. Follow the workpad plan and update it after meaningful milestones.
2. Use the repository's existing patterns and keep changes within the issue scope.
3. Run the issue's required validation before each push. Record exact commands and results in the workpad.
4. If validation or a required dependency is blocked, record what failed and why; do not claim it passed.
5. For issue comments, labels, and closure, use the lane-authorized `github_workflow` tool. `github_api` is read-only; do not use `gh` or shell commands for GitHub writes. Do not use labels for Symphony routing.

## Step 2: Prepare a human handoff

1. Review the diff, acceptance criteria, validation evidence, and all PR feedback.
2. Create or update a draft PR when the task produces code that needs review. Link it to the issue and include `Fixes #<issue-number>` when merging should close that issue.
3. Do not merge or approve the PR.
4. Update the persistent workpad with the final summary, validation evidence, and PR link.
5. Stop after the handoff. On successful completion, the current tracker moves Building to Done. If a reviewer requests changes, a human moves the open issue back to Ready; Symphony resumes the same workspace and branch. If the saved SHA was invalidated, Build syncs the issue branch before its next run; if the workspace cannot be reconciled automatically, follow its blocked report, resolve the branch, and move the issue back to Ready.

## Workpad template

Use this structure for the persistent issue comment and keep it updated in place:

~~~~md
## Codex Workpad

~~~text
<hostname>:<absolute-path>@<short-sha>
~~~

### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] Targeted checks: <command>

### Notes

- <short progress note with timestamp>

### Confusions

- <include only when something was confusing during execution>
~~~~
