# Symphony

Este glosario fija el lenguaje del sistema Symphony para coordinar trabajo entre varios repositorios.

## Tracker

**Tablero común**:
El GitHub Projects v2 configurado para una instalación de Symphony, que reúne tareas de uno o varios repositorios.

**Issue del tablero**:
Issue de GitHub vinculada al tablero común. Solo una issue cuyo estado `Status` sea `Ready`, cuyo repo esté registrado y cuyas dependencias estén resueltas puede iniciar una ejecución. En Projects v2, el estado del tablero controla el despacho.

**Identidad de ejecución**:
Identificador de una tarea de GitHub Projects compuesto por el ID del Project, el ID de su elemento, `owner/repo` y el número de issue. Symphony lo usa para distinguir tareas y nombrar workspaces e informes; `identifier` sigue siendo el valor legible que muestra la interfaz.

**Perfil de repositorio**:
Configuración de un repositorio permitido para una instalación, con su rama base y los pasos necesarios para preparar su workspace.

**Ciclo de ejecución del tablero**:
En Projects v2, Symphony requiere el campo `Status` y sus opciones canónicas: `Backlog`, `Ready`, `Building`, `QA`, `Review`, `Human Review`, `Blocked`, `Done` y `Dropped`. `Ready` admite tareas elegibles; el scheduler toma las más antiguas cuando hay slots libres. `bug` y `feature` recorren `Building`, `QA` y `Review`; el tipo `qa` empieza en QA. Cada fase autónoma usa una sesión nueva y QA y Review validan el SHA vigente.

En toda ejecución iniciada desde GitHub Issues o GitHub Projects, el agente gestiona las escrituras de su issue y PR; dentro del pipeline Projects, Build, QA y Review se reparten esas acciones por fase. Build crea la PR en draft; QA y Review publican sus informes y transiciones; Review deja la PR lista y la tarea en `Human Review` o, solo bajo el gate configurado, completa la fusión. Symphony lee esos estados, coordina sesiones y conserva el diario interno de ejecución y recuperación en SQLite. El Project en modo Projects y la issue en modo GitHub Issues siguen siendo autoridad de la intención humana; un reinicio nunca restaura un estado visible obsoleto. `Done` significa que el merge de la PR se confirmó; mover a `Ready` una issue ya cerrada no la reactiva: el trabajo posterior requiere una issue nueva. `Dropped` cierra un trabajo sin merge y lleva el motivo; si no hay cambios que hacer, requiere confirmación humana. `Blocked` indica que hace falta intervención, mientras que los fallos transitorios conservan los reintentos automáticos existentes; una diferencia entre un checkpoint no terminal y el estado del tracker también bloquea localmente la tarea sin modificar el tracker. Al mover una tarea de `Blocked` a `Ready`, Symphony conserva la rama y la PR y reanuda desde el último checkpoint; si el bloqueo ocurrió en QA o Review y cambió el head SHA de la PR, descarta ese checkpoint y vuelve a Build para repetir QA y Review. Al reanudar Build sin SHA aceptado, Symphony trae los cambios remotos de la rama mediante fast-forward; si hay divergencia, faltan las dos copias de la rama o los cambios locales impiden la actualización, conserva el workspace y coordina una sesión `diagnostic`. Ese agente lee los informes de la issue e inspecciona el workspace y la PR; publica el motivo y el estado `Blocked` con las herramientas autorizadas de su lane. QA y Review comprueban que el workspace siga limpio y en el SHA que publicó Build antes de iniciar otra sesión; si no coincide, el lane `diagnostic` registra en la issue el motivo y el siguiente paso. El contrato de selección y dispatch del tracker GitHub Issues se conserva.

**Dependencia de tarea**:
Relación explícita entre issues que debe resolverse antes de despachar la dependiente. Una dependencia pendiente no ocupa slot ni equivale a un bloqueo que requiera intervención; una relación no interpretable sí requiere diagnóstico humano.

**Slot de ejecución**:
Capacidad global que ejecuta una tarea desde Build o QA hasta terminar sus fases autónomas. `max_active_tasks` se configura por instalación y vale cinco por defecto. Las tareas en `Human Review`, `Blocked`, `Backlog` tras una parada, o un estado terminal liberan el slot.

**Human Review**:
Estado de una tarea que ya superó QA y la revisión autónoma, y cuya PR espera una decisión humana; todavía no cuenta como completada.

**Dropped**:
Estado terminal de un trabajo que se cancela o cierra sin merge; el motivo queda escrito en la issue y distingue, por ejemplo, cancelación, ausencia de cambios necesarios o sustitución por otra tarea. Si el agente propone `no_changes`, una persona debe confirmarlo.

**Informe de fase**:
Comentario publicado por el agente de fase en la issue vinculada, con su resultado, el resumen del trabajo, las comprobaciones realizadas, la evidencia relevante y el siguiente paso. Los bloqueos y descartes también registran su motivo; los comentarios humanos se conservan.
