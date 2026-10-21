# Nombres de issues, PRs y commits

Investigación realizada el 21 de octubre de 2026. Para Super Board se inspeccionó `main` en `f014cfa8aa0ef4e807c132f502a520f1e4864a31`.

## Hallazgo principal

Conventional Commits define el formato de **mensajes de commit**, no de títulos de issue o PR. Super Board tiene una convención propia inspirada en tipos y scopes, pero distinta e incompatible con el formato literal de Conventional Commits. [Especificación 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)

Por tanto, usar exactamente el formato de Super Board y usar Conventional Commits de forma estricta son dos decisiones distintas.

## Qué hace Super Board

Su referencia única de escritura define:

- **Commit:** `emoji [type] scope: subject`, en imperativo y hasta 72 caracteres. El emoji debe corresponder al tipo. El regex de sus tests rechaza `fix(receipts): ...`, que es formato Conventional Commits. [Writing standard, sección 1](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-board/references/writing-standard.md#L22-L57) · [test_writing_format.py](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/tests/test_writing_format.py#L50-L71)
- **PR:** reutiliza exactamente el asunto del commit. En su flujo de squash, el gate pasa el título de la PR como asunto del commit integrado. [Writing standard, sección 2](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-board/references/writing-standard.md#L68-L85) · [Super Build](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-build/SKILL.md#L134-L147)
- **Issue/ticket:** formato relacionado, pero con el tipo de trabajo: `emoji [kind] scope: what`, hasta 70 caracteres y sin repetir el número de issue. Por ejemplo, `🐛 [bug] receipts: spinner never stops over 10 MB`. [Ticket format](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-board/references/ticket-format.md#L33-L43)
- **Creación automática:** sus scripts forman el prefijo con el tipo y scope. La issue #65 documenta un caso real donde caller y script lo añadían ambos; el arreglo aclara quién es responsable del prefijo. [Issue #65](https://github.com/EricTechPro/super-board/issues/65) · [PR #68](https://github.com/EricTechPro/super-board/pull/68)
- **Validación:** su suite de seguridad ejecuta tests del estándar. Estos comprueban formas de asuntos y plantillas, pero no encontré un check de GitHub que inspeccione cada título real de PR ni un validador que impida crear cualquier issue fuera del formato. [test_writing_format.py](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/tests/test_writing_format.py) · [cross-platform workflow](https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/.github/workflows/cross-platform.yml)

El historial de Super Board también tiene títulos antiguos que no cumplen el estándar; la referencia y los tests actuales son una guía más fiable que asumir que todo el histórico está migrado.

## Estado actual de Symphony

- El skill de commits ya pide tipos convencionales y ejemplos `feat(scope): ...` y `fix(scope): ...`, con asunto imperativo de hasta 72 caracteres. [commit skill](../../.codex/skills/commit/SKILL.md#L35-L42)
- El skill de publicación solo pide que el título de PR describa claramente el cambio; no fija una gramática. [push skill](../../.codex/skills/push/SKILL.md#L40-L46)
- El skill de merge hace squash y pasa `pr_title` como `--subject`. El título de PR termina siendo el asunto del commit integrado. [land skill](../../.codex/skills/land/SKILL.md#L97-L98)
- La Action actual valida la **descripción** de PR (`body`), no su título. [pr-description-lint.yml](../../.github/workflows/pr-description-lint.yml#L30-L38)
- La guía de issues explica cómo crearlas, pero no define el título; tampoco hay issue forms en `.github/`. [issue-tracker.md](../agents/issue-tracker.md#L5-L13)
- La práctica actual es mixta: issue #38 y PR #36 usan títulos descriptivos sin prefijo, mientras la PR #8 usa `docs(superboard): ...`. [Issue #38](https://github.com/Compralaentrada/symphony/issues/38) · [PR #36](https://github.com/Compralaentrada/symphony/pull/36) · [PR #8](https://github.com/Compralaentrada/symphony/pull/8)
- La configuración de GitHub permite squash y usa `COMMIT_OR_PR_TITLE` para el título por defecto. Esto refuerza que título de PR y mensaje final deban tener el mismo contrato. [GitHub REST API: repository settings](https://docs.github.com/en/rest/repos/repos) · [Pull request merges](https://docs.github.com/en/pull-requests/reference/pull-request-merges)

## Decisión para Symphony

Se adopta la gramática literal de Conventional Commits como regla local para commits, títulos de PR y títulos de issues:

```text
<type>(<scope>): <imperative description>
<type>(<scope>)!: <imperative description>   # breaking change
```

La especificación oficial cubre mensajes de commit; extenderla a los títulos de issue y PR es una regla propia de Symphony. [Especificación 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)

- El scope es obligatorio, único, lowercase kebab-case y representa un área estable; el catálogo queda abierto. Ejemplos: `projects`, `workflow`, `orchestrator`, `skills`, `docs` y `ci`.
- Tipos permitidos: `feat`, `fix`, `docs`, `refactor`, `test`, `ci`, `build`, `chore`, `perf` y `security`. `security` es un tipo local permitido. `feat` y `fix` tienen el significado SemVer de la especificación; el resto clasifica el cambio.
- El asunto es imperativo, tiene hasta 72 caracteres y no termina en punto. Puede escribirse en español o inglés. El checker valida sintaxis, tipo, scope, longitud y puntuación; el imperativo requiere revisión humana.
- No se usan emojis ni `[tipo]`; eso seguiría el formato incompatible de Super Board.
- El tipo del título no reemplaza etiquetas de routing. `bug`, `feature` y `qa` siguen siendo labels; usa `fix`, `feat` o el tipo adecuado en el título.
- El PR describe el cambio que se integra. Al hacer squash, GitHub usa el título del PR como asunto del commit final. La `release` skill sigue pidiendo elegir la versión explícitamente; Conventional Commits no automatiza el release.

## Aplicación

- `mix title.check --title "..."` es el validador común. La Action de PR lo ejecuta al crear, reabrir o marcar lista una PR, y al cambiar su título. Las PR heredadas en draft se validan al pasar a revisión. `land` exige que ese check pase antes del squash.
- `docs/agents/issue-tracker.md` exige validar el título antes de cada `gh issue create`. Symphony no crea issues desde el runtime; la creación de tickets desde sus flujos de trabajo usa GitHub CLI. La interfaz manual de GitHub queda como recomendación porque los issue forms no validan expresiones regulares.
- Las skills `commit` y `push` documentan la regla y el preflight local; `land` exige que pase el check de título de PR antes del merge. Los commits individuales reciben guía local; el título validado del PR pasa a ser el mensaje final de squash.
- Se normalizan los 29 issues que estaban abiertos el 21 de octubre de 2026, excepto la issue #9 en `Building`. La PR #36 abierta en draft no se modifica mientras siga activa. Las issues cerradas quedan como historial.

No se añade `commitlint` ni una Action de issues: el checker Mix compartido cubre CI de PR y el preflight de creación de tickets.
