## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `Compralaentrada/symphony`; pass `--repo Compralaentrada/symphony` to `gh` commands. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default labels `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses the single-context layout. See `docs/agents/domain.md`.

### Skills for local Codex runs

Codex discovers the pinned skills in `.agents/skills` from the checked-out project. Select them by issue labels: code work uses Ponytail and TDD, and code-review runs before a PR; `frontend`, `front-end`, or `ui` adds Impeccable; `writing`, `copywriting`, `docs`, or `documentation` adds Humanizer for person-directed text. `writing-only` and `text-only` skip the code skills. Before acting, verify each selected `SKILL.md`; if one is missing, stop and report its name and path.
