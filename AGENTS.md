## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `Compralaentrada/symphony`; pass `--repo Compralaentrada/symphony` to `gh` commands. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default labels `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses the single-context layout. See `docs/agents/domain.md`.

### Skills for local Codex runs

Codex discovers the pinned skills in `.agents/skills` from the checked-out project. Local code work uses Ponytail and TDD, and code-review runs before a PR. Add Impeccable for `frontend`, `front-end`, or `ui` labels. Use Humanizer only for person-directed writing; `copywriting`, `customer-facing`, `humanizer`, and `user-facing` labels select it. `writing-only` and `text-only` skip Ponytail and TDD. Before acting, verify each selected `SKILL.md`; if one is missing, stop and report its name and path.
