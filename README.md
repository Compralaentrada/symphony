# Symphony

Symphony coordina agentes de código para llevar trabajo de desarrollo desde un GitHub Project hasta
una entrega revisable. Lee las tareas admitidas, prepara un workspace aislado para el repositorio
correspondiente y ejecuta las fases necesarias con Codex.

## Qué hace

- Coordina varios repositorios desde un único GitHub Project v2 mediante perfiles de repositorio.
- Ejecuta Build, QA y Review en sesiones separadas y comprueba los comandos `required_checks` del
  repositorio durante QA.
- Publica informes Markdown en español para issues en español y en inglés para el resto.
- Guarda checkpoints del pipeline en SQLite para reanudar el trabajo tras un reinicio.
- Expone el estado operativo en un dashboard y una API JSON.
- Espera una fusión humana y solo marca una tarea como Done tras confirmar la fusión.

En el pipeline de Projects, el estado visible del Project determina el despacho. El flujo normal es
`Ready → Building → QA → Review → Human Review → Done`; las tareas que requieren intervención
pueden pasar a `Blocked`. Mover una tarea de `Human Review` a `Ready` solicita correcciones sobre la
misma rama y PR.

El tablero usa el campo `Status` y las opciones canónicas de Symphony: `Backlog`, `Ready`, `Building`,
`QA`, `Review`, `Human Review`, `Blocked`, `Done` y `Dropped`.

El runtime también incluye adaptadores para GitHub Issues, Linear, Jira Cloud, Asana y GitLab. El
pipeline multi-repositorio descrito aquí está centrado en GitHub Projects v2.

## Estado del proyecto

El pipeline y la recuperación durable están implementados. La migración para que cada agente de
fase sea propietario de sus escrituras de GitHub está aprobada y sigue en curso en la issue
[#40](https://github.com/Compralaentrada/symphony/issues/40); hasta que termine, Symphony coordina
esas escrituras.

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
