# Symphony

Este glosario fija el lenguaje del sistema Symphony para coordinar trabajo entre varios repositorios.

## Tracker

**Tablero común**:
El GitHub Projects v2 configurado para una instalación de Symphony, que reúne tareas de uno o varios repositorios.

**Issue del tablero**:
Issue de GitHub vinculada al tablero común. Solo una issue cuyo estado `Status` sea `Ready`, cuyo repo esté registrado y cuyas dependencias estén resueltas puede iniciar una ejecución. En Projects v2, el estado del tablero controla el despacho.

**Perfil de repositorio**:
Configuración de un repositorio permitido para una instalación, con su rama base y los pasos necesarios para preparar su workspace.

**Ciclo de ejecución del tablero**:
En Projects v2, Symphony requiere el campo `Status` y sus opciones canónicas: `Backlog`, `Ready`, `Building`, `QA`, `Review`, `Human Review`, `Blocked`, `Done` y `Dropped`. `Ready` admite tareas elegibles; el scheduler toma las más antiguas cuando hay slots libres. `bug` y `feature` recorren `Building`, `QA` y `Review`; el tipo `qa` empieza en QA. Cada fase autónoma usa una sesión nueva y QA y Review validan el SHA vigente. Symphony crea la PR en draft tras Build y, tras aceptar QA y Review, deja la tarea en `Human Review` con la PR lista. Si la persona pide cambios, la tarea vuelve a `Ready`; Symphony conserva la rama y PR, devuelve la PR a draft y repite las fases. El agente sube la rama y devuelve su SHA; Symphony gestiona las escrituras de la PR y del Project. El Project es autoridad del estado visible y la intención humana; SQLite conserva el diario interno de ejecución y nunca restaura un estado visible obsoleto. `Done` significa que el merge de la PR se confirmó; mover a `Ready` una issue ya cerrada no la reactiva: el trabajo posterior requiere una issue nueva. `Dropped` cierra un trabajo sin merge y lleva el motivo; si no hay cambios que hacer, requiere confirmación humana. `Blocked` indica que hace falta intervención, mientras que los fallos transitorios conservan los reintentos automáticos existentes; al mover una tarea de `Blocked` a `Ready`, Symphony reanuda desde el último checkpoint y conserva la rama y PR si existen. El tracker GitHub Issues conserva su contrato actual.

**Dependencia de tarea**:
Relación explícita entre issues que debe resolverse antes de despachar la dependiente. Una dependencia pendiente no ocupa slot ni equivale a un bloqueo que requiera intervención; una relación no interpretable sí requiere diagnóstico humano.

**Slot de ejecución**:
Capacidad global que ejecuta una tarea desde Build o QA hasta terminar sus fases autónomas. `max_active_tasks` se configura por instalación y vale cinco por defecto. Las tareas en `Human Review`, `Blocked`, `Backlog` tras una parada, o un estado terminal liberan el slot.

**Human Review**:
Estado de una tarea que ya superó QA y la revisión autónoma, y cuya PR espera una decisión humana; todavía no cuenta como completada.

**Dropped**:
Estado terminal de un trabajo que se cancela o cierra sin merge; el motivo queda escrito en la issue y distingue, por ejemplo, cancelación, ausencia de cambios necesarios o sustitución por otra tarea. Si el agente propone `no_changes`, una persona debe confirmarlo.

**Informe de fase**:
Comentario de Symphony en la issue vinculada al terminar una fase, con su resultado, un resumen del trabajo y las comprobaciones realizadas, la evidencia relevante y el siguiente paso. Los bloqueos y descartes también registran su motivo; los comentarios humanos se conservan.
