# Delegar las escrituras de GitHub a los agentes de ejecución

- **Estado:** Aceptada
- **Fecha:** 21 de octubre de 2026
- **Issue de implementación:** #40, hija de #10

## Contexto

El pipeline Projects actual concentra en Symphony las escrituras de PR, Project e informes. En el tracker GitHub Issues, las escrituras de la ejecución también deben pertenecer al agente que trabaja la issue. Separar el trabajo del agente de la llamada que publica su resultado crea caminos duplicados de recuperación e idempotencia.

Super Board asigna a cada lane la responsabilidad de reclamar y liberar la issue, informar en issue y PR, mover el Project y completar las acciones de su fase. Build abre la draft PR; Review aplica el gate y decide si puede fusionarse. El dispatcher coordina la ejecución. [SB1], [SB17]

## Decisión

- En toda ejecución despachada desde GitHub Issues o GitHub Projects, el agente que trabaja la tarea es propietario de las mutaciones de GitHub relacionadas con su issue y PR: claim/liberación, etiquetas, comentarios e informes, cambios de estado del Project cuando aplique, creación y actualización de issues de seguimiento, lifecycle de PR, revisión y cierre. En el pipeline Projects, Build, QA y Review se reparten estas acciones por fase; en una ejecución individual las gestiona el agente de esa ejecución.
- Cada lane solo ejecuta las acciones permitidas por su rol y resultado. Build crea o actualiza la draft PR y entrega la fase a QA. QA registra evidencia y entrega o devuelve el trabajo. Review publica hallazgos, solicita correcciones o pasa a Human Review. Si **merge_policy: auto** está habilitado, Review solicita la fusión al gate determinista; con la política humana predeterminada, espera a la persona. Review solo marca **Done** y cierra la issue tras confirmar el merge en la rama base. [SB17], [SB18]
- Symphony conserva las lecturas del tracker, admisión, scheduling, límites y slots, lease local, lanzamiento y parada de sesiones, checkpoints, diario durable y reconciliación. El orquestador no inicia mutaciones de issues, Projects ni PRs; las herramientas del host ejecutan y controlan las que solicita el agente de ejecución.
- El scheduler reserva localmente el slot antes de lanzar al agente. El agente adquiere el claim visible de GitHub con una operación atómica, lo libera al terminar y no continúa si otro worker lo posee. Un token de generación local impide que una sesión antigua publique resultados. Si el bloqueo debe publicarse antes de iniciar el trabajo normal, un agente de diagnóstico ejecuta esa mutación.
- Las sesiones reciben herramientas GitHub mediadas por el host, con el repo, identidad y operaciones autorizadas para ese rol. No reciben tokens del tracker ni una vía de shell que permita saltarse las restricciones o el gate de merge.
- Cada escritura se registra y devuelve evidencia remota verificable. Ante una respuesta incierta, el agente o la herramienta consulta GitHub antes de repetirla; Symphony reconcilia esa evidencia antes de reintentar una fase. Los informes editan únicamente el bloque/comentario propiedad de Symphony y conservan texto humano.
- En modo Projects, el Project sigue siendo autoridad del estado visible y de la intención humana; en modo GitHub Issues, lo es la issue y su contrato existente. SQLite sigue siendo el diario interno. Las escrituras de agentes nunca sustituyen decisiones humanas más recientes.

## Consecuencias

Las fases y las ejecuciones individuales deben recibir permisos GitHub acotados y prompts que asignen claramente claim, comentarios, estados y lifecycle de PR. Las herramientas del host deben aplicar permisos y el gate de merge fuera del modelo, y registrar operaciones para recuperación. El coordinador deja de duplicar esas mutaciones y conserva la capacidad de detener o reconciliar una ejecución.

Los issues #25–#29 dependen de #40 porque su deduplicación de PR, informes, transiciones y merge debe construirse sobre este límite de propiedad.

## Fuentes

- [Contrato de lanes de Super Board][SB1]
- [Skill super-build][SB17]
- [Skill super-review][SB18]

[SB1]: https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-board/references/run.md
[SB17]: https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-build/SKILL.md
[SB18]: https://github.com/EricTechPro/super-board/blob/f014cfa8aa0ef4e807c132f502a520f1e4864a31/skills/super-review/SKILL.md
