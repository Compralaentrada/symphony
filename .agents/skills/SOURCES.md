# Pinned skills

These skills are committed into the project so Codex runs can discover them from the checked-out workspace. Runs do not download or update skills.

`CHECKSUMS.sha256` in each skill directory lists SHA-256 digests for every vendored file in that directory except the checksum file itself. The fingerprint below is the SHA-256 of that checksum list.

| Skill | Source and release | Resolved commit | License | Content fingerprint |
| --- | --- | --- | --- | --- |
| `ponytail` | [DietrichGebert/ponytail v5.3.2](https://github.com/DietrichGebert/ponytail/releases/tag/v5.3.2) | `16352ac229eb08a9598dcae48fe9f2b342567d86` | MIT | `c45df1e5846a557d1d4e1ccf103d5f7ef301de1e7d75d4d66b39aebd47a4497a` |
| `tdd` | [mattpocock/skills v1.3.1](https://github.com/mattpocock/skills/releases/tag/v1.3.1), `skills/engineering/tdd` | `24fe0ef7737efae15c87225755e9f6f5965e4888` | MIT | `667334c17fc95b5baa2de148b7350b869b6ca638d28a4f169a20097a96ff760a` |
| `code-review` | [mattpocock/skills v1.3.1](https://github.com/mattpocock/skills/releases/tag/v1.3.1), `skills/engineering/code-review` | `24fe0ef7737efae15c87225755e9f6f5965e4888` | MIT | `a52343a898efa04dc09383c2838e456f01d71d44cfb1ab18fab9f861b5febdb9` |
| `impeccable` | [pbakaus/impeccable skill-v4.7.0](https://github.com/pbakaus/impeccable/releases/tag/skill-v4.7.0), `.agents/skills/impeccable` | `aeeb3d8c30b5f95aeeb3e893b0f1a308af8fdb8f` | Apache-2.0 | `65221981f5d994a14d3974bf296c0e7abc48c1faab2bf380ea118397bd9e408b` |
| `humanizer` | [blader/humanizer v3.1.0](https://github.com/blader/humanizer/releases/tag/v3.1.0) | `225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8` | MIT | `608262ab1f6eca5b99011ed6f5ee801ff3d5fd96c570f1b3a8db05a83239ff92` |

Verify from each skill directory with `shasum -a 256 -c CHECKSUMS.sha256`.
Impeccable markdown whitespace was normalized for repository checks; its fingerprint covers the committed files.
