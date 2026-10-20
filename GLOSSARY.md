# Symphony

Este glosario fija el lenguaje del sistema Symphony para coordinar trabajo entre varios repositorios.

## Tracker

**Tablero común**:
El GitHub Projects v2 configurado para una instalación de Symphony, que reúne tareas de uno o varios repositorios.

**Issue del tablero**:
Issue de GitHub vinculada al tablero común. Solo una issue en el estado configurado como `Ready` puede iniciar una ejecución; su repositorio identifica el destino del trabajo. La issue debe pertenecer a un perfil de repositorio configurado. En el tracker Projects v2, el estado del tablero controla el despacho.

**Perfil de repositorio**:
Configuración de un repositorio permitido para una instalación, con su rama base y los pasos necesarios para preparar su workspace.

**Ciclo de ejecución del tablero**:
En Projects v2, el campo y los valores de estado se configuran por instalación. `Ready` inicia el trabajo, que avanza por `Building`, `QA`, `Review` autónoma y `Human Review`; cada fase usa una sesión nueva y QA y Review validan el SHA de la entrega vigente. Symphony crea la PR en draft tras Build y la marca lista para revisión tras aceptar QA y Review. Si la persona pide cambios, vuelve a `Ready`; Symphony conserva la rama y PR, devuelve la PR a draft y repite las fases. El agente sube la rama y devuelve su SHA; Symphony persiste y gestiona las escrituras de la PR y del estado del Project. `Done` significa que el merge de la PR se confirmó; mover a `Ready` una issue ya cerrada no la reactiva: el trabajo posterior requiere una issue nueva. `Dropped` cierra un trabajo sin merge y lleva el motivo; si no hay cambios que hacer, requiere confirmación humana. `Blocked` indica que hace falta intervención, mientras que los fallos transitorios conservan los reintentos automáticos existentes; al mover una tarea de `Blocked` a `Ready`, Symphony reanuda desde el último checkpoint y conserva la rama y PR si existen. El tracker GitHub Issues conserva su contrato actual.

**Human Review**:
Estado de una tarea que ya superó QA y la revisión autónoma, y cuya PR espera una decisión humana; todavía no cuenta como completada.

**Dropped**:
Estado terminal de un trabajo que se cancela o cierra sin merge; el motivo queda escrito en la issue y distingue, por ejemplo, cancelación, ausencia de cambios necesarios o sustitución por otra tarea. Si el agente propone `no_changes`, una persona debe confirmarlo.

**Informe de fase**:
Comentario de Symphony en la issue vinculada al terminar una fase, con su resultado, un resumen del trabajo y las comprobaciones realizadas, la evidencia relevante y el siguiente paso. Los bloqueos y descartes también registran su motivo; los comentarios humanos se conservan.
