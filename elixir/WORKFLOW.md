---
# Alternative Projects v2 mode: use `kind: github_projects`, status-only routing,
# and provider fields `owner`, `project_number`, `status_field`, `status_values`,
# `token: $GITHUB_TOKEN`, and `repositories` (repository, base_branch,
# prepare_command). See README.md's GitHub Projects v2 adapter profile for the
# full example and workspace preparation contract.
tracker:
  kind: github
  provider:
    repo: Compralaentrada/symphony
    token: "$GITHUB_TOKEN"
  required_labels:
    - ready-for-agent
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    gh repo clone Compralaentrada/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
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

You are working on GitHub issue {{ issue.identifier }} in Compralaentrada/symphony.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. It may be a normal continuation or a retry after a failure.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat completed investigation or validation unless needed for new code changes.
- Continue only while the issue is open and has the required ready-for-agent label. When handing work to a human, remove that label so Symphony stops the run.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Issue number: {{ issue.id }}
Title: {{ issue.title }}
State: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## GitHub issue routing

The GitHub tracker state is only open or closed. Workflow phases use labels and pull request review state:

- Open with ready-for-agent: Symphony may start or continue work. Keep this label while implementation or merge work is active.
- Open with ready-for-human and without ready-for-agent: waiting for human review; Symphony must not work on the issue.
- Open without either routing label: queued or out of scope; do not work on it.
- Closed: terminal; stop.
- When a reviewer requests changes, the human removes ready-for-human and re-adds ready-for-agent. Read all issue and PR feedback and continue the existing work.
- After a PR is approved, the human removes ready-for-human and re-adds ready-for-agent. If checks are green and no actionable feedback remains, follow the land skill.
- To hand work to a human, remove ready-for-agent and add ready-for-human. The tracker requires ready-for-agent both for dispatch and for continuing an active run, so removing it stops the run.

Only use GitHub issues in Compralaentrada/symphony. Follow docs/agents/issue-tracker.md and pass --repo Compralaentrada/symphony to GitHub CLI commands.

## Instructions

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Stop early only for a true external blocker such as missing tools, authentication, permissions, or secrets. If blocked, record it in the workpad and hand off by removing ready-for-agent and adding ready-for-human.
3. Final message must report completed actions and blockers only. Do not include next steps for the user.
4. Work only in the provided repository copy. Do not touch any other path.
5. Keep ready-for-agent on the issue while doing implementation or merge work. Remove it only for a human handoff or when the issue is no longer assigned to Symphony.
6. For issue reads, comments, labels, and closure, use gh commands with --repo Compralaentrada/symphony as documented in docs/agents/issue-tracker.md. If gh cannot authenticate, use the injected github_api tool, which executes host-side with the session-bound token.
7. Do not put tracker tokens in WORKFLOW.md or the issue workpad. Symphony reads GITHUB_TOKEN from its host environment and keeps tracker credentials out of the Codex child environment.

## Default posture

- Read the issue and its labels, then follow the routing rules above.
- Start each routed task by opening the persistent workpad comment and bringing it up to date before implementation.
- Spend extra effort up front on planning and verification design.
- Reproduce first: confirm the current behavior or issue signal before changing code.
- Keep issue labels, the workpad checklist, acceptance criteria, and PR links current.
- Treat one persistent GitHub issue comment as the source of truth for progress and handoff notes. Do not post separate completion summaries.
- Treat any issue-authored Validation, Test Plan, or Testing section as non-negotiable acceptance input. Copy it into the workpad and execute it before considering the task complete.
- For meaningful out-of-scope improvements, create a separate issue in Compralaentrada/symphony, label it needs-triage, and link it to the current issue as a sub-issue or with a Part of #<number> line. Use native GitHub issue dependencies for blockers when available; otherwise add a Blocked by: #<number> line.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Do not change issue state to represent intermediate workflow phases. Use the routing labels and PR review state above.

## Related skills

- commit: produce clean, logical commits during implementation.
- push: keep the remote branch current and publish updates.
- pull: merge the latest origin/main before code edits and before handoff as required below.
- land: after a human approves the PR and re-adds ready-for-agent, open and follow .codex/skills/land/SKILL.md. Do not call gh pr merge directly.

## Step 0: Confirm routing and choose the task flow

1. Fetch the issue by number with gh issue view <number> --repo Compralaentrada/symphony.
2. If it is closed, stop without changing it.
3. If ready-for-agent is absent, do not start or continue work. If ready-for-human is present, wait for the human review cycle to re-route the issue.
4. Check for an existing PR linked to the issue and for review feedback:
   - If the latest review requests changes, follow the rework flow.
   - If the PR is approved, checks are green, and no actionable feedback remains, follow the merge flow.
   - Otherwise continue implementation from the current workpad and workspace.
5. If an existing PR is closed or merged:
   - If merged, confirm the issue is closed and stop.
   - If closed without merge, do not reuse its branch; create a fresh branch from origin/main and restart from reproduction and planning.
6. For every issue with ready-for-agent, find or create the workpad before implementation. Do not make an intermediate issue-state transition.

## Step 1: Start or continue execution

1. Find or create one persistent issue comment marked ## Codex Workpad:
   - Search the issue comments for that exact header.
   - Reuse the existing comment when found; otherwise create one.
   - Edit the same comment for all progress and handoff notes. Do not create extra status comments.
2. Reconcile the workpad before new edits:
   - Check off completed items.
   - Refine the plan for the current scope.
   - Ensure Acceptance Criteria and Validation match the issue and its required validation.
3. Write or update a hierarchical plan in the workpad.
4. Add a compact environment stamp as a fenced code line:
   - Format: <host>:<absolute-workspace-path>@<short-sha>
   - Example: devbox-01:/home/dev-user/code/symphony-workspaces/GH-32@7bdde33bc
   - Do not repeat issue ID, labels, branch, or PR URL already visible in GitHub.
5. Add acceptance criteria and TODOs as checklists in the workpad.
   - For user-facing changes, include an end-to-end UI walkthrough.
   - For app behavior changes, include the launch path, changed interaction, and expected result.
   - Copy any issue-provided Validation, Test Plan, or Testing requirements into the workpad as required checkboxes.
6. Review the plan for missing steps, risks, and verification, then refine it.
7. Capture a concrete reproduction signal before implementation and record it in Notes.
8. Run the pull skill to merge origin/main before code edits. Record the merge source, result, and resulting HEAD short SHA in Notes.
9. Compact context and proceed with the remaining plan.

## PR feedback sweep

Before handing a PR to a human or merging it, review every feedback channel:

1. Identify linked PRs from the issue cross-references and current branch.
2. Read top-level comments with gh pr view <number> --repo Compralaentrada/symphony --comments.
3. Read inline review comments with gh api --repo Compralaentrada/symphony repos/Compralaentrada/symphony/pulls/<number>/comments.
4. Read review summaries with gh pr view <number> --repo Compralaentrada/symphony --json reviews.
5. Treat every actionable human or bot comment as blocking until addressed in code/tests/docs or answered with justified pushback.
6. Update the workpad with each feedback item and its resolution.
7. Re-run validation after feedback changes, push updates, and repeat the sweep until no actionable comments remain.

## Blocked-access handling

- Try the configured github_api tool and the authenticated gh CLI before declaring GitHub access blocked.
- GitHub access is required for issue routing, comments, labels, and PR handoff. If neither path works, record what failed and why it blocks the task in the workpad, remove ready-for-agent, and add ready-for-human.
- For missing non-GitHub tools or auth, use the same label handoff and include the exact blocker and required human action in the workpad.
- Keep blocker notes concise and do not post separate top-level comments outside the workpad.

## Step 2: Implement and prepare the PR

1. Confirm the repository, branch, git status, and HEAD. Verify the pull skill sync is recorded in the workpad before code edits.
2. Keep ready-for-agent on the issue while implementation is active.
3. Follow the workpad plan. Update it after meaningful milestones and whenever scope, risks, or validation changes.
4. Run validation required by the issue:
   - Execute all issue-provided Validation, Test Plan, or Testing requirements.
   - Prefer targeted proof for the changed behavior.
   - Temporary local proof edits are allowed when useful, but revert them before commit or push and record the steps in the workpad.
   - For app changes, run launch-app validation and capture/upload media via github-pr-media before handoff.
5. Re-check the acceptance criteria and close any gaps.
6. Before every push, run the required validation and confirm it passes.
7. Create or update the PR. Include Fixes #<issue-number> in its body so GitHub links it to the issue and closes the issue when the PR merges.
8. Ensure the PR has the symphony label.
9. Merge the latest origin/main into the branch, resolve conflicts, and rerun required checks.
10. Update the workpad with final plan, acceptance, and validation status. Record the PR number and link there.
11. Before handoff, read the PR Manual QA Plan if present, run the full PR feedback sweep, confirm checks are green, and confirm all issue-provided validation items are complete.
12. When implementation is ready for human review:
    - Remove ready-for-agent and add ready-for-human on the issue.
    - Update the workpad with the handoff summary and validation evidence.
    - Stop work. Do not keep polling or making changes while waiting for review.
13. If the issue started with an existing PR, resolve its feedback and push the required updates before handoff.

## Step 3: Human review and merge

An issue waiting for review has ready-for-human and does not have ready-for-agent, so Symphony will not run on it.

- If reviewers request changes, the human removes ready-for-human and re-adds ready-for-agent. Resume from the existing workspace and workpad, address all feedback, validate, then hand off again.
- If the PR is approved, the human removes ready-for-human and re-adds ready-for-agent. Confirm the latest PR review is approved, checks are green, and no actionable comments remain.
- After approval, open and follow .codex/skills/land/SKILL.md and run the land loop until the PR is merged. Do not call gh pr merge directly.
- After merge, confirm GitHub closed the linked issue. If it remains open, close it with gh issue close <number> --repo Compralaentrada/symphony.

## Step 4: Rework handling

When a reviewer requests changes and the issue is re-routed with ready-for-agent:

1. Treat rework as a full approach reset, not incremental patching.
2. Re-read the full issue body, all human comments, and all PR feedback. Record what will change in the approach.
3. Close the existing PR tied to the issue.
4. Delete the existing Codex Workpad issue comment using the GitHub API.
5. Create a fresh branch from origin/main.
6. Start a new workpad, plan, and validation checklist, then execute the task end-to-end.
7. Remove ready-for-agent and add ready-for-human when the updated PR is ready for review.

## Completion bar before human review

- The plan, acceptance criteria, and validation checklist are complete in the workpad.
- All required issue validation items passed for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, PR is linked to the issue, and the PR has the symphony label.
- If the change touches the app, runtime validation and required media are complete.
- The issue has ready-for-human and no ready-for-agent label.

## Guardrails

- If the issue is closed, do nothing and stop.
- If the issue is open but lacks ready-for-agent, do not modify code or tracker content.
- Do not edit the issue body for planning or progress tracking.
- Use exactly one persistent ## Codex Workpad issue comment.
- Update the workpad comment in place using the authenticated GitHub API or an available update script.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- For out-of-scope work, create a separate needs-triage issue in this repository and link it to the current issue as a sub-issue or with a Part of #<number> line. Use Blocked by: #<number> if native issue dependencies are unavailable.
- Do not hand off for review until the completion bar is satisfied, except when missing access blocks required work; document that blocker in the workpad.
- During human review, do not make changes. The issue must remain without ready-for-agent until the human requests changes or approves the PR.
- Keep issue and PR text concise, specific, and reviewer-oriented.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place:

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

- [ ] Targeted tests: <command>

### Notes

- <short progress note with timestamp>

### Confusions

- <include only when something was confusing during execution>
~~~~
