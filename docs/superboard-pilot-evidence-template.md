# Registro de evidencia del piloto

Usa una copia de esta plantilla por cohorte. Registra hechos observables y enlaces a informes, checks o PRs. No incluyas tokens, secretos ni datos que no hagan falta para revisar el resultado. Consulta el [runbook del piloto](superboard-pilot-runbook.md) para el orden de ejecución.

## Datos de la cohorte

| Campo | Valor |
| --- | --- |
| Cohorte / fecha | |
| Responsable de supervisión | |
| Project configurado | |
| Repositorios y runtimes | |
| Ramas base y checks requeridos por perfil | |
| `agent.max_concurrent_agents` máximo (**M**) | |
| Política de merge efectiva (`human` o `auto`) | |
| Número de slots activos máximo observado | |
| Resultado de cohorte (`pasa` / `no pasa`) | |

## Registro por tarea

Duplica una fila por tarea. Si un caso bloquea, indica qué faltó y qué acción permite continuar.

| Fecha | Repo#issue | Tipo / ruta | Escenario de matriz | Dependencia | Aceptación (`sí` / `parcial` / `no`) | Intentos y reintentos por fase | Supervisión (min) | Bloqueo y motivo | Recuperación o acción humana | Evidencias / SHA / PR |
| --- | --- | --- | --- | --- | --- | --- | ---: | --- | --- | --- |
| | | | | | | | | | | |

## Métricas de la cohorte

| Métrica | Resultado |
| --- | --- |
| Tareas ejecutadas / rango objetivo 10–20 | |
| Tareas aceptadas / tareas revisadas (tasa de aceptación) | |
| Reintentos, desglosados por fase | |
| Tiempo total de supervisión (minutos) | |
| Motivos de bloqueo y frecuencia | |
| Pico de slots observados / **M** | |
| Fallos recuperables | |
| Fallos con acción humana concreta | |

## Criterios de estabilidad de #10

Marca cada criterio solo con evidencia. Un criterio sin evidencia cuenta como no demostrado.

| Criterio | Resultado (`sí` / `no`) | Evidencia o issue correctivo |
| --- | --- | --- |
| Cero tareas perdidas | | |
| Cero efectos externos duplicados | | |
| Cero transiciones falsas a `Done` | | |
| Cero excesos del límite de slots | | |
| Toda ejecución fallida es recuperable o tiene un bloqueo accionable | | |

## Resumen

- Evidencia revisada:
- Desviaciones y bloqueos:
- Issues correctivos para criterios fallidos:
- Decisión final: `pasa` / `no pasa`.
