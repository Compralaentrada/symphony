# Symphony

Symphony coordina agentes de código para llevar trabajo de desarrollo desde un GitHub Project hasta
una entrega revisable. Lee las tareas admitidas, prepara un workspace aislado para el repositorio
correspondiente y ejecuta las fases necesarias con Codex.

## Qué hace

- Coordina varios repositorios desde un único GitHub Project v2 mediante perfiles de repositorio.
- Aísla cada ejecución de Projects con el proyecto, el elemento, el repositorio y el número de issue;
  cada workspace y búsqueda de PR queda vinculado al repositorio correcto.
- Ejecuta Build, QA y Review en sesiones separadas y comprueba los comandos `required_checks` del
  repositorio durante QA.
- Resuelve las skills del catálogo de Symphony por fase y añade las condicionales solo cuando
  aplican a la tarea.
- Publica informes Markdown en español para issues en español y en inglés para el resto.
- Guarda checkpoints del pipeline en SQLite para reanudar el trabajo tras un reinicio.
- Expone el estado operativo y las tareas del pipeline en Operations, Delivery y una API JSON.
- Espera una fusión humana por defecto; solo `auto` explícito solicita la fusión al gate determinista.
  Symphony nunca aprueba PRs y solo marca una tarea como Done tras confirmar la fusión.

En el pipeline de Projects, el estado visible del Project determina el despacho. El flujo normal es
`Ready → Building → QA → Review → Human Review → Done`; las tareas que requieren intervención
pueden pasar a `Blocked`. Mover una tarea de `Human Review` a `Ready` solicita correcciones sobre la
misma rama y PR. Antes de QA o Review, Symphony comprueba que el `head SHA` de la PR siga siendo el
que aceptó Build y que el workspace esté limpio en ese SHA. Si una tarea bloqueada en QA o Review
vuelve de `Blocked` a `Ready` con el head cambiado o sin PR, reinicia en `Build` y repite ambas
fases. Si falla una comprobación previa, el agente del lane `diagnostic` lee el workpad e inspecciona
el workspace y la PR antes de documentar el motivo y la recuperación en la issue y el Project.
Symphony detecta el bloqueo y coordina esa sesión, pero no escribe en GitHub. Si un checkpoint de fase
no coincide con el estado actual del tracker, conserva el trabajo y registra el bloqueo local sin
cambiar el estado visible; mover la tarea a `Ready` permite reanudarla.

El tablero usa el campo `Status` y las opciones canónicas de Symphony: `Backlog`, `Ready`, `Building`,
`QA`, `Review`, `Human Review`, `Blocked`, `Done` y `Dropped`.

El runtime también incluye adaptadores para GitHub Issues, Linear, Jira Cloud, Asana y GitLab. El
pipeline multi-repositorio descrito aquí está centrado en GitHub Projects v2.

## Estado del proyecto

El pipeline y la recuperación durable están implementados. En ejecuciones desde GitHub Issues o
GitHub Projects, el agente de cada tarea es propietario de sus escrituras de issue y PR. En el
pipeline Projects, Build, QA y Review gestionan las operaciones de su lane mediante herramientas del
host; Symphony conserva la lectura, el scheduling, los leases, los checkpoints y la reconciliación.
Una lectura exitosa que omite una issue activa conserva su agente en el primer refresh; una segunda
omisión consecutiva confirma la ausencia y lo detiene sin borrar el workspace.

## Empezar en local

Requisitos: macOS o Linux, `mise`, Git, Codex CLI autenticado y acceso de escritura a los
repositorios configurados. Configura `GITHUB_TOKEN` con acceso al Project y a sus issues, y
credenciales Git en el host para publicar ramas.

```sh
git clone https://github.com/Compralaentrada/symphony.git
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix run --no-start --no-halt -e 'SymphonyElixir.CLI.main(["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", "4000", "./WORKFLOW.md"])'
```

El comando deja el servicio en primer plano y habilita el dashboard en `http://localhost:4000`. La
configuración incluida en [`elixir/WORKFLOW.md`](elixir/WORKFLOW.md) corresponde al piloto de este
repositorio; revísala antes de usarla con otro Project o repositorio.

## Desarrollo y documentación

```sh
MIX='mise exec -- mix' make -C elixir all
```

- [Guía de ejecución y configuración](elixir/README.md)
- [Workflow del piloto](elixir/WORKFLOW.md)
- [Plan del producto](docs/superboard-symphony-plan.md)
- [Decisión sobre escrituras de GitHub](docs/adr/0002-agentes-propietarios-de-escrituras-github.md)

## Licencia

Este proyecto está publicado bajo la [Apache License 2.0](LICENSE).
