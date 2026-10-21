# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues in `Compralaentrada/symphony`. Use the `gh` CLI for all operations, always passing `--repo Compralaentrada/symphony`. This clone's only remote is `origin`, which points to that repo.

## Conventions

- **Create an issue**: validate the title as described in **Title format**, then run `gh issue create --repo Compralaentrada/symphony --title "$title" --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --repo Compralaentrada/symphony --json number,title,body,labels,comments`.
- **List issues**: `gh issue list --repo Compralaentrada/symphony --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Make an issue a sub-issue of a parent**: `gh issue create --repo Compralaentrada/symphony --parent <parent> ...`, or `gh issue edit <parent> --repo Compralaentrada/symphony --add-sub-issue <child>` afterwards (`gh` 2.94+). Older `gh`: `gh api --repo Compralaentrada/symphony --method POST repos/Compralaentrada/symphony/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>` (database id, as in **Blocking** below). Without sub-issues, put `Part of #<parent>` at the top of the child body.
- **Comment on an issue**: `gh issue comment <number> --repo Compralaentrada/symphony --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --repo Compralaentrada/symphony --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --repo Compralaentrada/symphony --comment "..."`

## Title format

Use the same local Conventional Commit format for issue, pull request, and commit subjects:

```text
<type>(<scope>): <imperative description>
<type>(<scope>)!: <imperative description>   # breaking change
```

Allowed types are `feat`, `fix`, `docs`, `refactor`, `test`, `ci`, `build`, `chore`, `perf`, and `security`. `security` is a repository-specific type. Use `fix` for bugs and `feat` for features; `qa` remains a routing label, not a title type.

Every title needs one lowercase kebab-case scope naming a stable area, such as `projects`, `workflow`, `orchestrator`, `skills`, `docs`, or `ci`. The scope list is open so new areas do not require a policy change. Keep the subject imperative, at most 72 characters for the full title, and without a final period. Spanish and English descriptions are both accepted.

Before any `gh issue create` command, validate its title from the repository root:

```sh
title="feat(projects): usar estados canónicos"
(cd elixir && mise exec -- mix title.check --title "$title")
gh issue create --repo Compralaentrada/symphony --title "$title" --body-file /path/to/issue.md
```

The checker validates the type, scope, single-line structure, whitespace, length, and final punctuation. Keep the imperative description meaningful by review. The title format for issues and pull requests is a Symphony repository rule; the Conventional Commits specification itself standardizes commit messages. GitHub's manual issue form does not enforce this rule, so apply it when creating or editing issues by hand.

Title types do not control pipeline routing. Keep using the issue labels and Project status for that.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --repo Compralaentrada/symphony --comments` and `gh pr diff <number> --repo Compralaentrada/symphony` for the diff.
- **List external PRs for triage**: `gh api --repo Compralaentrada/symphony --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`.
- **Comment / label / close**: `gh pr comment <number> --repo Compralaentrada/symphony --body "..."`, `gh pr edit <number> --repo Compralaentrada/symphony --add-label "..."` / `--remove-label "..."`, `gh pr close <number> --repo Compralaentrada/symphony`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42 --repo Compralaentrada/symphony` and fall back to `gh issue view 42 --repo Compralaentrada/symphony`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --repo Compralaentrada/symphony --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (see **Make an issue a sub-issue of a parent**). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --repo Compralaentrada/symphony --method POST repos/Compralaentrada/symphony/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api --repo Compralaentrada/symphony repos/Compralaentrada/symphony/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --repo Compralaentrada/symphony --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --repo Compralaentrada/symphony --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --repo Compralaentrada/symphony --body "<answer>"`, then `gh issue close <n> --repo Compralaentrada/symphony`, then append a context pointer (gist + link) to the map's Decisions-so-far.
