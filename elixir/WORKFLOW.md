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
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-6-luna"' --config model_reasoning_effort=max app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a GitHub issue dispatched from the configured GitHub Projects v2 board.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. Resume from the existing workspace, branch, pull request, and workpad.
- Continue only while the issue is open and its Project status is Building.
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
- Building: Build owns the issue claim, branch push, draft PR, report, and transition to QA.
- QA: the QA agent reviews the current SHA, runs every `required_checks` command in the task workspace, records evidence, and advances or returns the task. Missing or failed host checks cannot pass QA.
- Review: the Review agent examines the QA-accepted SHA, records findings, and either requests changes or prepares the PR for human review.
- Human Review: the PR is ready for a person; Symphony waits for a merge or a move back to Ready.
- Blocked: the phase agent records the reason in the issue and moves the Project item to Blocked. After it is resolved, a human moves the issue to Ready.
- Done: the PR merge into the configured base branch has been confirmed.
- Closed GitHub issue: terminal; stop.
- Backlog: not dispatched.
- Dropped: terminal work without a merge. Include a human-authored `Drop reason: <reason>` line in the issue body; after `no_changes`, this confirms the decision to discard the work.

The issue identifier starts with the target repository in the form owner/repository#number. Work only in that repository. Do not assume a specific organization, repository, or default branch. The runtime has selected a repository profile and checked out the task branch from that profile's base branch.

Use `github_workflow` for GitHub writes. `github_api` is read-only and scoped to the task repository. Do not use `gh` or shell commands to write issues, Project items, or pull requests. Git push is allowed for the Build handoff. Never copy tracker tokens into the workpad or command output.

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
- Reproduce the issue signal before changing code. Plan the smallest change that fully meets its acceptance criteria.
- Follow any issue-provided Validation, Test Plan, or Testing section.
- For user-facing changes, include an end-to-end walkthrough. For application behavior changes, record the launch path, interaction, and expected result.
- Run checks required by the issue and use targeted validation for the changed behavior.
- Do not approve or merge pull requests. Human approval and merge remain manual.

## Step 0: Confirm the work

1. Parse the repository and issue number from `{{ issue.identifier }}`, then fetch the issue with `gh issue view <number> --repo <owner/repository>`.
2. If the GitHub issue is closed, stop. If the Project status is not Building, do not edit code or tracker content.
3. Read the issue body, comments, and any linked PR feedback. Treat actionable review feedback as part of the acceptance criteria.
4. Find or create the persistent workpad comment with `github_workflow` operation `workpad` before implementation.
5. Record an environment stamp in the workpad:
   - Format: <host>:<absolute-workspace-path>@<short-sha>
   - Do not repeat the issue ID, branch, or PR URL already visible in GitHub.
6. Record a reproduction signal and a short plan with acceptance and validation checklists.
7. Verify the checked-out repository, task branch, working tree, and configured base branch. Sync the base branch before edits using the repository's applicable `pull` workflow; do not hard-code `main`.

## Step 1: Implement

1. Follow the workpad plan and update it after meaningful milestones.
2. Use the repository's existing patterns and keep changes within the issue scope.
3. Run the issue's required validation before each push. Record exact commands and results in the workpad.
4. If validation or a required dependency is blocked, record what failed and why; do not claim it passed.
5. For issue comments, labels, and closure, use `gh` with the target repository or the injected `github_api` tool. Do not use labels for Symphony routing.

## Step 2: Prepare a human handoff

1. Review the diff, acceptance criteria, validation evidence, and all PR feedback.
2. Create or update a draft PR when the task produces code that needs review. Link it to the issue and include `Fixes #<issue-number>` when merging should close that issue.
3. Do not merge or approve the PR.
4. Update the persistent workpad with the final summary, validation evidence, and PR link.
5. Stop after the handoff. On successful completion, the current tracker moves Building to Done. If a reviewer requests changes, a human moves the open issue back to Ready; Symphony resumes the same workspace and branch.

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
