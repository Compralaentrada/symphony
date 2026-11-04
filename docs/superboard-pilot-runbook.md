# Runbook del piloto progresivo

Este runbook guía un piloto controlado de 10–20 tareas en dos o más repositorios configurados, con runtimes distintos. El Project configurado determina qué tareas entran y en qué estado están. Cada repositorio aporta su rama base, preparación y checks requeridos.

El plan de hitos está en el [roadmap de Super Board](superboard-symphony-plan.md). La [plantilla del registro](superboard-pilot-evidence-template.md) acompaña cada cohorte y conserva la evidencia necesaria para declarar el resultado.

## Límites del piloto

- No presupongas una organización, una lista de repositorios ni una rama base. Lee los perfiles configurados para cada instalación.
- No pongas tareas en `Ready` ni actives `auto` mientras redactas o revisas este runbook. Las ejecuciones reales corresponden a las cohortes operativas #32–#35.
- El smoke test de este cambio se hará con una tarea de prueba en el Project #9 configurado para este piloto y guardará el primer registro, una vez iniciada la operación controlada.
- La primera cohorte (#32) usa merge humano y empieza con un slot. No cambies la política de merge como parte de la documentación.
- No declares estabilidad a partir de tests automatizados o de una sola cohorte.

## Preparación

Antes de admitir trabajo, confirma que:

1. El Project configurado tiene los estados canónicos del pipeline y sus tareas están identificadas por repositorio e issue.
2. Hay al menos dos perfiles de repositorio con runtimes distintos. Cada perfil declara su repo, rama base, comando de preparación y checks requeridos.
3. La preparación de cada perfil y sus checks pasan en su propio workspace. Una limitación de un repo debe bloquear solo sus tareas y dejar una acción concreta.
4. El máximo global efectivo es `agent.max_concurrent_agents` (`10` si no está configurado). Empieza configurándolo en `1`; anota el valor máximo efectivo como **M**.
5. Anota la política de merge efectiva que se usará. La clave de instalación `merge_policy` admite `human` o `auto`, por defecto `human`. Si se configura en el nivel superior prevalece sobre `tracker.provider.merge_policy`; si se omite, se respeta un valor explícito del provider. No infieras el valor activo de un ejemplo ni lo cambies durante el piloto.
6. Para la primera cohorte, verifica que la política efectiva es `human`, como requiere #32. Para las siguientes, conserva la política elegida. `auto` solo se usa cuando ya estaba habilitado expresamente y el gate está operativo.
7. Prepara el registro y guarda configuración, perfiles, checks, límite **M**, política, fecha y responsable de supervisión. No copies tokens ni secretos.

Si falta un requisito, no admitas nuevas tareas. Registra el bloqueo y la acción que lo resolvería; no sustituyas un perfil incompleto por valores supuestos.

## Secuencia de operación

### 1. Comprobar el smoke test y el primer registro

Después de aprobar este runbook y preparar la instalación, sigue el procedimiento con una tarea de prueba en el Project #9 configurado para este piloto. Usa un slot, merge humano y los checks del perfil de esa tarea. Completa una fila de la plantilla de registro con la aceptación, los reintentos, el tiempo de supervisión y cualquier bloqueo. No cuentes esta tarea como evidencia de estabilidad de una cohorte.

### 2. Ejecutar la primera cohorte con un slot

Sigue #32: ejecuta cinco tareas de bajo riesgo en un repositorio configurado, con `agent.max_concurrent_agents: 1` y merge humano. Incluye al menos una tarea `bug`, una `feature` y una con la etiqueta `qa`. Registra cada tarea, su resultado, reintentos, bloqueos y tiempo de supervisión.

Continúa solo si no hay tareas perdidas, efectos externos duplicados, transiciones falsas a `Done` ni exceso del slot. Cada fallo debe quedar recuperable o tener una acción humana concreta.

### 3. Añadir un segundo repositorio y probar recuperación

Sigue #33: amplía la muestra con un segundo repositorio cuyo runtime sea distinto. Usa dos issues con el mismo número local para comprobar que la identidad incluye el repositorio. Registra una dependencia nativa entre repositorios mientras sigue abierta y después de resolverla. Provoca un reinicio o una respuesta externa incierta y verifica el aislamiento de ramas, workspaces, PRs y estados.

Una dependencia abierta mantiene la tarea en `Ready` sin consumir slot. Al resolverse, la tarea vuelve a ser elegible según el Project. No infieras dependencias por el número de issue. Si GitHub no permite leer la relación completa, registra el bloqueo sin inventar otra relación.

### 4. Aumentar los slots gradualmente

Sigue #34 y aumenta el límite solo después de que el nivel actual cumpla sus criterios. Usa estos pasos, sin superar **M**:

`1 → min(2, M) → min(4, M) → min(8, M) → … → M`

En cada nivel, anota el límite configurado y el pico observado de tareas activas. Comprueba que no se supera el límite global. Si falla una comprobación, no aumentes capacidad: registra el fallo, la recuperación o la acción humana, y conserva la evidencia.

Entre las tareas de esta cohorte incluye dependencia, feedback humano, `Blocked → Ready` y recuperación de fases. En cada respuesta a feedback, confirma que el trabajo continúa en la misma rama y PR y que la fase correcta vuelve a ejecutarse.

### 5. Consolidar y decidir

Sigue #35 para resumir entre 10 y 20 tareas de al menos dos repositorios. Completa todos los criterios de estabilidad del registro. El resultado es `pasa` solo si hay evidencia para cada criterio; de lo contrario es `no pasa` y cada brecha debe enlazar a un issue correctivo.

## Matriz de escenarios

Ejecuta los casos dentro de las cohortes indicadas y guarda un registro por tarea. Los reinicios se provocan en una ventana acordada y se verifican tras reconciliar el Project, los informes y los efectos externos.

| ID | Caso y procedimiento | Resultado esperado | Cohorte |
| --- | --- | --- | --- |
| BUG | Enviar una tarea de tipo `bug` por la ruta normal. | Build, QA y Review terminan con checks del perfil; el resultado queda registrado. | #32 |
| FEATURE | Enviar una tarea de tipo `feature` por la ruta normal. | Build, QA y Review terminan con checks del perfil; el resultado queda registrado. | #32 |
| QA | Añadir la etiqueta `qa` a una tarea de prueba. | Sigue la ruta directa QA → Review, sin ejecutar Build. | #32 |
| DEP-OPEN | Mantener abierta una dependencia nativa de otra issue. | La tarea queda en `Ready` y no consume slot. | #33 |
| DEP-RESOLVED | Resolver esa dependencia. | La tarea pasa a ser elegible según el estado actual del Project y se procesa una sola vez. | #33 |
| HUMAN-FEEDBACK | Pedir una corrección humana durante la revisión y devolver la tarea a Ready. | Se conserva la rama y PR; el feedback llega a la fase responsable y queda registrado. | #34 |
| RESTART-BUILD | Reiniciar Symphony durante Build y reconciliar antes de reanudar. | Se conserva la rama y el trabajo confirmado; no se duplica PR ni informe. | #33/#34 |
| RESTART-QA | Reiniciar durante QA y volver a comprobar el SHA aceptado y los checks requeridos. | QA puede reanudarse o repetirse sobre el SHA correcto; no se reutiliza evidencia de otro SHA. | #33/#34 |
| RESTART-REVIEW | Reiniciar durante Review y volver a reconciliar el informe y la PR. | Review usa el informe vigente; no se duplica una escritura ni se aprueba automáticamente la PR. | #33/#34 |
| TWO-REPOS | Ejecutar tareas en dos perfiles configurados con runtimes distintos, incluidas issues con igual número local. | Cada repo mantiene su rama base, workspace, PR, checks y estado; no hay colisión de identidad. | #33 |
| MERGE-POLICY | Comprobar la política elegida y registrar el resultado según `human` o `auto`. | Con `human`, la PR espera una decisión humana. Con `auto`, Review solicita el gate determinista y Symphony solo cierra tras verificar el merge. Nunca se aprueba automáticamente. Si la base avanza, se reencola Build y luego se repiten QA y Review; otros fallos del gate quedan en Human Review. | #32–#34 |

Con `auto`, el gate requiere el informe aprobado de Review del intento actual y que el head revisado contenga el commit actual de la base. Los checks requeridos del host deben pasar; si GitHub reporta un rollup, también debe ser satisfactorio. La protección de ramas y la mergeabilidad siguen bajo control de GitHub. Un head, base o evidencia que no coincida impide una fusión incorrecta.

## Cierre de cada cohorte

1. Asegura que cada tarea tiene aceptación, reintentos, supervisión, bloqueos, resultado y referencias a su evidencia.
2. Anota el máximo configurado y el pico real de tareas activas; confirma que el segundo no lo superó.
3. Comprueba tareas perdidas, efectos duplicados, transiciones falsas a `Done` y fallos sin recuperación ni acción concreta.
4. No declares estable el piloto si falta una tarea, cohorte o evidencia.
5. Publica el resumen de #35 con resultado `pasa` o `no pasa` y enlaza issues correctivos para brechas.
