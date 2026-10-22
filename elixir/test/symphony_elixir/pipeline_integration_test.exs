defmodule SymphonyElixir.PipelineIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Pipeline}

  test "report locale recognizes Spanish, French, and German issue descriptions" do
    for description <- [
          "Implementar soporte para nuevas salas",
          "Permitir crear salas privadas",
          "Actualizar modulo principal"
        ] do
      assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: description}) == :es
    end

    assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: "Add support for private rooms"}) == :en
    assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: "Implement login for usuarios"}) == :en
    assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: "Créer des salles privées"}) == :fr
    assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: "Unterstützung für private Räume"}) == :de
  end

  test "Build, QA, and Review reports use French when the issue body is French" do
    issue = %{issue("octo/app#43", 43) | description: "Créer des salles privées"}

    build =
      build("sha-fr")
      |> Map.merge(%{
        "summary" => "Les salles privées sont prises en charge.",
        "criteria" => ["La création de salles privées répond au critère."],
        "changes" => ["Ajout de la création de salles privées."],
        "next_step" => "QA peut vérifier le parcours."
      })

    qa =
      qa("sha-fr")
      |> Map.merge(%{
        "summary" => "Toutes les vérifications requises ont réussi.",
        "criteria" => ["Le parcours répond au critère."],
        "next_step" => "Review peut examiner le SHA actuel."
      })

    review =
      review("sha-fr")
      |> Map.merge(%{
        "summary" => "Aucun défaut n’a été trouvé.",
        "next_step" => "Attends la revue humaine."
      })

    table = start_board([issue], %{issue.id => %{build: [build], qa: [qa], review: [review]}})
    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    build_report = lookup(table, {:report, issue.id, "build"})
    assert build_report =~ "<!-- symphony:octo/app#43:1:build:1 -->"
    assert build_report =~ "## Rapport Symphony : Build (prêt)"
    assert build_report =~ "### Résumé\n\nLes salles privées sont prises en charge."
    assert build_report =~ "### Critères d’acceptation"
    assert build_report =~ "### Modifications"
    assert build_report =~ "### Étape suivante"
    refute build_report =~ "### Summary"

    qa_report = lookup(table, {:report, issue.id, "qa"})
    assert qa_report =~ "## Rapport Symphony : QA (réussi)"
    assert qa_report =~ "### Vérifications"
    assert qa_report =~ "Symphony a exécuté la vérification configurée pour le SHA"
    assert qa_report =~ "code de sortie de l’hôte"

    review_report = lookup(table, {:report, issue.id, "review"})
    assert review_report =~ "## Rapport Symphony : Revue (réussi)"
    assert review_report =~ "Aucun défaut n’a été trouvé."
    assert review_report =~ "### Étape suivante"

    for report <- [build_report, qa_report, review_report] do
      refute report =~ "### Summary"
      refute report =~ "\"outcome\""
      refute report =~ "null"
    end

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "Build, QA, and Review reports use German when the issue body is German" do
    issue = %{issue("octo/app#44", 44) | description: "Unterstützung für private Räume"}

    build =
      build("sha-de")
      |> Map.merge(%{
        "summary" => "Private Räume werden unterstützt.",
        "criteria" => ["Private Räume lassen sich erstellen."],
        "changes" => ["Unterstützung für private Räume hinzugefügt."],
        "next_step" => "QA kann die Erstellung prüfen."
      })

    qa =
      qa("sha-de")
      |> Map.merge(%{
        "summary" => "Alle erforderlichen Prüfungen sind bestanden.",
        "criteria" => ["Das Kriterium ist erfüllt."],
        "next_step" => "Review kann den aktuellen SHA prüfen."
      })

    review =
      review("sha-de")
      |> Map.merge(%{
        "summary" => "Es wurden keine Fehler gefunden.",
        "next_step" => "Auf die menschliche Prüfung warten."
      })

    table = start_board([issue], %{issue.id => %{build: [build], qa: [qa], review: [review]}})
    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    build_report = lookup(table, {:report, issue.id, "build"})
    assert build_report =~ "## Symphony-Bericht: Build (bereit)"
    assert build_report =~ "### Zusammenfassung\n\nPrivate Räume werden unterstützt."
    assert build_report =~ "### Akzeptanzkriterien"
    assert build_report =~ "### Nächster Schritt"

    qa_report = lookup(table, {:report, issue.id, "qa"})
    assert qa_report =~ "## Symphony-Bericht: QA (bestanden)"
    assert qa_report =~ "### Prüfungen"
    assert qa_report =~ "Symphony hat die konfigurierte Prüfung für SHA"
    assert qa_report =~ "Exitcode des Hosts"

    review_report = lookup(table, {:report, issue.id, "review"})
    assert review_report =~ "## Symphony-Bericht: Review (bestanden)"
    assert review_report =~ "### Nächster Schritt"

    for report <- [build_report, qa_report, review_report] do
      refute report =~ "### Summary"
      refute report =~ "\"outcome\""
      refute report =~ "null"
    end

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "Build, QA and Review resume on the same PR and Done waits for a confirmed merge" do
    issue = issue("octo/app#1", 1)
    issue = %{issue | description: "Actualizar modulo principal"}

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build_es("sha-one"), build_es("sha-two")],
          qa: [qa_es("sha-one"), qa_es("sha-two")],
          review: [review_es("sha-one"), review_es("sha-two")]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    first_sha = lookup(table, {:remote_sha, issue.id})
    assert %{number: pr_number, branch: branch, sha: ^first_sha, draft: false} = pull_request(table, issue.id)
    assert branch == issue.branch_name
    assert pull_request(table, issue.id).body =~ "Fixes octo/app#1"
    assert pull_request(table, issue.id).body =~ "Se cumple el criterio de aceptación."
    assert pull_request(table, issue.id).body =~ first_sha
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    build_report = lookup(table, {:report, issue.id, "build"})
    assert build_report =~ "<!-- symphony:octo/app#1:1:build:1 -->"
    assert build_report =~ "### Resumen\n\nImplementé los cambios solicitados."
    assert build_report =~ "### Criterios de aceptación"
    assert build_report =~ "### Cambios"
    assert build_report =~ "### SHA\n\n`#{first_sha}`"
    refute build_report =~ "### Pruebas"

    qa_report = lookup(table, {:report, issue.id, "qa"})
    assert qa_report =~ "<!-- symphony:octo/app#1:1:qa:1 -->"
    assert qa_report =~ "### Pruebas"
    assert qa_report =~ "`true`: superada"
    assert qa_report =~ "Symphony ejecutó la comprobación configurada"

    review_report = lookup(table, {:report, issue.id, "review"})
    assert review_report =~ "<!-- symphony:octo/app#1:1:review:1 -->"
    assert review_report =~ "No se encontraron defectos."
    refute review_report =~ "### Hallazgos"
    refute review_report =~ "### Resoluciones"

    for report <- [build_report, qa_report, review_report] do
      refute report =~ "\"outcome\""
      refute report =~ "null"
    end

    set_project_state(table, issue.id, "Done")
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    stop_orchestrator(orchestrator)
    set_project_state(table, issue.id, "Ready")
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" and agent_calls(table, issue.id) == 6 end)
    second_sha = lookup(table, {:remote_sha, issue.id})
    assert second_sha != first_sha
    assert %{number: ^pr_number, branch: ^branch, sha: ^second_sha, draft: false} = pull_request(table, issue.id)
    assert pull_request(table, issue.id).body =~ second_sha
    assert report_phases(table, issue.id) == [:build, :qa, :review, :build, :qa, :review]

    set_pull_request_merged(table, issue.id, true)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == "Done" end)

    set_project_state(table, issue.id, "Ready")
    set_github_issue_state(table, issue.id, "closed")
    send(orchestrator, :tick)
    Process.sleep(50)
    assert agent_calls(table, issue.id) == 6

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "legacy issue status mappings do not remap the canonical pipeline" do
    statuses = default_status_values()

    legacy_statuses = %{
      backlog: "Ideas",
      ready: "Queued",
      building: "Implementing",
      qa: "Verifying",
      review: "Auditing",
      human_review: "Awaiting Human",
      blocked: "Needs Help",
      dropped: "Discarded",
      done: "Integrated"
    }

    issue = issue("octo/app#9", 9)

    issue = %{
      issue
      | state: statuses.ready,
        native_ref: Map.merge(issue.native_ref, %{project_status: statuses.ready, status_values: Map.new(legacy_statuses, fn {key, value} -> {Atom.to_string(key), value} end)})
    }

    table = start_board([issue], %{issue.id => %{build: [build("sha-nine")], qa: [qa("sha-nine")], review: [review("sha-nine")]}})
    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == statuses.human_review end)

    set_project_state(table, issue.id, statuses.done)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == statuses.human_review end)

    set_pull_request_merged(table, issue.id, true)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == statuses.done end)

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "no_changes waits for human confirmation, Blocked resumes, and transient failures retry" do
    no_changes = %{issue("octo/app#2", 2) | description: "Unterstützung für private Räume"}
    blocked = %{issue("octo/app#3", 3) | description: "Unterstützung für private Räume"}
    transient = issue("octo/app#4", 4)
    missing_check = %{issue("octo/app#6", 6) | description: "Unterstützung für private Räume"}
    unavailable_check = %{issue("octo/app#10", 10) | description: "Unterstützung für private Räume"}

    no_changes_report =
      no_changes()
      |> Map.merge(%{
        "summary" => "Das angeforderte Verhalten ist bereits vorhanden.",
        "reason" => "Es sind keine Codeänderungen erforderlich.",
        "criteria" => ["Alle Kriterien sind erfüllt."],
        "next_step" => "Warte auf die Bestätigung durch eine Person."
      })

    blocked_report =
      blocked()
      |> Map.merge(%{
        "summary" => "Der Zugriff auf die Testumgebung ist erforderlich.",
        "reason" => "Die erforderlichen Zugangsdaten sind nicht verfügbar.",
        "risks" => ["Die erforderliche Umgebung kann nicht ausgeführt werden."],
        "next_step" => "Stelle den Zugriff wieder her und verschiebe die Aufgabe auf Ready."
      })

    table =
      start_board([no_changes, blocked, transient, missing_check, unavailable_check], %{
        no_changes.id => %{build: [no_changes_report]},
        blocked.id => %{build: [blocked_report, build("sha-three")], qa: [qa("sha-three")], review: [review("sha-three")]},
        transient.id => %{build: [{:error, :temporary_failure}, build("sha-four")], qa: [qa("sha-four")], review: [review("sha-four")]},
        missing_check.id => %{
          build: [build("sha-six-old"), build("sha-six-fixed")],
          qa: [qa_missing_check("sha-six-old"), qa("sha-six-fixed")],
          review: [Map.put(review("sha-six-fixed"), "resolutions", ["required-check:sh ./check.sh"])]
        },
        unavailable_check.id => %{build: [build("sha-ten")], qa: [qa_missing_check("sha-ten")]}
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)
    workspace = ensure_test_workspace!(missing_check)
    File.write!(Path.join(workspace, "check.sh"), "if [ -f fail-once ]; then rm fail-once; exit 1; fi\nexit 0\n")
    File.write!(Path.join(workspace, "fail-once"), "fail once")
    File.write!(Path.join(workspace, ".git/info/exclude"), "fail-once\n", [:append])
    {_output, 0} = System.cmd("git", ["add", "check.sh"], cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["commit", "-m", "add check fixture"], cd: workspace, stderr_to_stdout: true)
    missing_check = %{missing_check | native_ref: Map.put(missing_check.native_ref, :required_checks, ["sh ./check.sh"])}
    :ets.insert(table, {{:issue, missing_check.id}, missing_check})
    unavailable_check = %{unavailable_check | native_ref: Map.put(unavailable_check.native_ref, :required_checks, ["command-that-does-not-exist"])}
    :ets.insert(table, {{:issue, unavailable_check.id}, unavailable_check})
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, no_changes.id) == "Blocked" end)
    assert report_phases(table, no_changes.id) == [:build]
    no_changes_report = lookup(table, {:reports, no_changes.id})["<!-- symphony:octo/app#2:1:build:1 -->"]
    assert no_changes_report =~ "## Symphony-Bericht: Build (keine Änderungen)"
    assert no_changes_report =~ "### Grund"
    assert no_changes_report =~ "Es sind keine Codeänderungen erforderlich."
    refute no_changes_report =~ "### Prüfungen"

    assert await(fn -> project_state(table, blocked.id) == "Blocked" end)
    blocked_report = lookup(table, {:report, blocked.id, "build"})
    assert blocked_report =~ "### Hindernis"
    assert blocked_report =~ "### Prüfungen"
    assert blocked_report =~ "Es wurden keine Prüfungen ausgeführt, weil die Phase blockiert ist."
    refute blocked_report =~ "\"outcome\""

    set_project_state(table, no_changes.id, "Dropped")

    send(orchestrator, :tick)
    assert await(fn -> project_state(table, no_changes.id) == "Blocked" end)
    drop_reason_report = lookup(table, {:report, no_changes.id, "build"})
    assert drop_reason_report =~ "Vor dem Verwerfen dieser Arbeit ist eine von einer Person verfasste Begründung erforderlich."
    assert drop_reason_report =~ "`Drop reason: <reason>`"

    set_issue_description(table, no_changes.id, no_changes.description <> "\n\nDrop reason: Das angeforderte Verhalten ist bereits vorhanden.")
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, no_changes.id) == "Dropped" end)
    assert report_phases(table, no_changes.id) == [:build, :build, :dropped]
    dropped_report = lookup(table, {:report, no_changes.id, "dropped"})
    assert dropped_report =~ "<!-- symphony:octo/app#2:1:dropped:0 -->"
    assert dropped_report =~ "## Symphony-Bericht: Verworfen (verworfen)"
    assert dropped_report =~ "Das angeforderte Verhalten ist bereits vorhanden."
    assert dropped_report =~ "### Nächster Schritt"
    assert dropped_report =~ "Die Arbeit wurde ohne gemergten Pull Request verworfen."
    refute dropped_report =~ "\"outcome\""
    assert project_state(table, no_changes.id) == "Dropped"

    assert await(fn -> project_state(table, blocked.id) == "Blocked" end)
    set_project_state(table, blocked.id, "Ready")
    assert await(fn -> project_state(table, blocked.id) == "Human Review" end)

    assert await(fn -> project_state(table, transient.id) == "Human Review" end)
    assert agent_calls(table, transient.id) == 4

    assert await(fn -> project_state(table, missing_check.id) == "Human Review" end)
    assert agent_calls(table, missing_check.id) == 5
    assert report_phases(table, missing_check.id) == [:build, :qa, :build, :qa, :review]
    failed_qa_report = lookup(table, {:reports, missing_check.id})["<!-- symphony:octo/app#6:1:qa:1 -->"]
    assert failed_qa_report =~ "## Symphony-Bericht: QA (Änderungen erforderlich)"
    assert failed_qa_report =~ "Mindestens eine erforderliche Host-Prüfung ist fehlgeschlagen"
    assert failed_qa_report =~ "Alle erforderlichen Prüfungen müssen für den akzeptierten SHA"
    assert failed_qa_report =~ "Exitcode des Hosts: 1"

    qa_report = lookup(table, {:report, missing_check.id, "qa"})
    assert qa_report =~ "Exitcode des Hosts: 0"
    refute qa_report =~ "agent claimed success"

    assert await(fn -> project_state(table, unavailable_check.id) == "Blocked" end)
    assert agent_calls(table, unavailable_check.id) == 2
    assert report_phases(table, unavailable_check.id) == [:build, :qa]
    unavailable_report = lookup(table, {:report, unavailable_check.id, "qa"})
    assert unavailable_report =~ "### Hindernis"
    assert unavailable_report =~ "### Prüfungen"
    assert unavailable_report =~ "Eine erforderliche Prüfung war auf dem Host nicht verfügbar."
    assert unavailable_report =~ "Symphony konnte die erforderliche Prüfung nicht ausführen."
    assert unavailable_report =~ "Symphony konnte nicht alle konfigurierten erforderlichen Prüfungen ausführen."
    assert unavailable_report =~ "Behebe das Problem mit der Host-Prüfung"

    for report <- Map.values(lookup(table, {:reports, no_changes.id})) ++ Map.values(lookup(table, {:reports, blocked.id})) ++ Map.values(lookup(table, {:reports, unavailable_check.id})) do
      refute report =~ "\"outcome\""
      refute report =~ "null"
    end

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "uncertain PR and report responses reconcile after orchestrator restarts without duplicates" do
    issue = issue("octo/app#5", 5)
    table = start_board([issue], %{issue.id => %{build: [build("sha-five")], qa: [qa("sha-five")], review: [review("sha-five")]}})
    path = pipeline_database!(table, retry_backoff_ms: 300_000)
    :ets.insert(table, {:uncertain_pr_once, true})
    :ets.insert(table, {:uncertain_report_once, true})

    orchestrator = start_orchestrator()
    assert await(fn -> pull_request(table, issue.id) != nil end)
    assert await(fn -> :ets.lookup(table, :uncertain_pr_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> report_phases(table, issue.id) == [:build] end)
    assert await(fn -> :ets.lookup(table, :uncertain_report_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review]
    assert pull_request_count(table, issue.id) == 1
    assert agent_calls(table, issue.id) == 3

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "PR creation revalidates the pushed SHA after Build commits its outbox" do
    issue = issue("octo/app#7", 7)
    table = start_board([issue], %{issue.id => %{build: [build("sha-seven")]}})
    path = pipeline_database!(table)
    :ets.insert(table, {:change_sha_after_validation, true})

    orchestrator = start_orchestrator()
    assert await(fn -> agent_calls(table, issue.id, :build) == 1 end)
    Process.sleep(50)

    assert project_state(table, issue.id) == "Building"
    assert pull_request_count(table, issue.id) == 0

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "QA retries a report missing the changes summary" do
    issue = issue("octo/app#8", 8)
    incomplete = qa("sha-eight") |> Map.delete("changes")

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-eight")],
          qa: [incomplete, qa("sha-eight")],
          review: [review("sha-eight")]
        }
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 4
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "blocked reports retry until their summary, reason, and next step are present" do
    issue = %{issue("octo/app#15", 15) | description: "Falta acceso al entorno de pruebas."}

    incomplete_reports = [
      Map.put(blocked(), "summary", " "),
      Map.put(blocked(), "reason", "\n"),
      Map.put(blocked(), "next_step", "")
    ]

    table = start_board([issue], %{issue.id => %{build: incomplete_reports ++ [blocked()]}})
    path = pipeline_database!(table, retry_backoff_ms: 1)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    assert agent_calls(table, issue.id, :build) == 4
    assert report_phases(table, issue.id) == [:build]

    report = table |> lookup({:reports, issue.id}) |> Map.values() |> List.first()
    assert report =~ "### Resumen\n\nHace falta acceso al entorno de pruebas."
    assert report =~ "### Bloqueo\n\nNo están disponibles las credenciales necesarias para las pruebas."
    assert report =~ "### Siguiente paso\n\nResuelve el acceso y mueve la tarea a Ready."
    assert report =~ "No se ejecutaron pruebas porque la fase quedó bloqueada."
    refute report =~ "null"
    refute report =~ ~r/\"(?:outcome|summary|reason|next_step)\"\s*:/

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "QA host checks reject workspace drift after the accepted Build SHA" do
    issue = %{issue("octo/app#11", 11) | description: "Créer des salles privées"}

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("dirty"), build("clean")],
          qa: [qa("dirty"), qa("clean")],
          review: [Map.put(review("clean"), "resolutions", ["workspace-sha-mismatch"])]
        }
      })

    path = pipeline_database!(table)
    :ets.insert(table, {{:dirty_once, issue.id}, true})
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 5
    assert report_phases(table, issue.id) == [:build, :qa, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) |> Enum.any?(&(&1["id"] == "workspace-sha-mismatch"))

    qa_report = lookup(table, {:reports, issue.id})["<!-- symphony:octo/app#11:1:qa:1 -->"]
    assert qa_report =~ "## Rapport Symphony : QA (modifications requises)"
    assert qa_report =~ "Toutes les vérifications requises doivent réussir pour le SHA accepté"
    assert qa_report =~ "Symphony n’a pas exécuté la vérification"

    assert table
           |> lookup({:reports, issue.id})
           |> Map.values()
           |> Enum.any?(&String.contains?(&1, "espace de travail"))

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "a QA report with findings returns to Build and keeps finding context through Review" do
    issue = issue("octo/app#12", 12)
    finding = %{"id" => "QA-12-1", "reproduction" => "Run the failing scenario.", "criterion" => "The result matches the acceptance criterion."}
    qa_with_finding = Map.put(qa("first"), "findings", [finding])

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("first"), build("fixed"), build("fixed-two")],
          qa: [qa_with_finding, qa("fixed"), qa("fixed-two")],
          review: [review("fixed"), Map.put(review("fixed-two"), "resolutions", [finding["id"]])]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    assert agent_calls(table, issue.id) == 8
    assert report_phases(table, issue.id) == [:build, :qa, :build, :qa, :review, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 3}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 1}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 2}) == [finding]

    qa_report = lookup(table, {:reports, issue.id})["<!-- symphony:octo/app#12:1:qa:1 -->"]
    assert qa_report =~ "### Findings"
    assert qa_report =~ "`QA-12-1`"
    assert qa_report =~ "Reproduction: Run the failing scenario."
    assert qa_report =~ "Criterion: The result matches the acceptance criterion."
    refute qa_report =~ "\"reproduction\""

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "generated QA findings text follows the issue language" do
    issue = %{issue("octo/app#14", 14) | description: "Implementa los cambios y valida los criterios de aceptación."}

    finding = %{
      "id" => "QA-14-1",
      "reproduction" => "Ejecuta el caso que falla.",
      "criterion" => "El resultado debe cumplir el criterio de aceptación."
    }

    qa_with_finding = qa_es("first") |> Map.put("findings", [finding])

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build_es("first"), build_es("fixed"), build_es("fixed-two")],
          qa: [qa_with_finding, qa_es("fixed"), qa_es("fixed-two")],
          review: [Map.put(review_es("fixed"), "findings", [finding]), Map.put(review_es("fixed-two"), "resolutions", [finding["id"]])]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    report = lookup(table, {:reports, issue.id})["<!-- symphony:octo/app#14:1:qa:1 -->"]
    assert report =~ "QA encontró hallazgos que requieren corrección."
    assert report =~ "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
    refute report =~ "QA reported findings"
    refute report =~ "\"outcome\""

    review_report = lookup(table, {:reports, issue.id})["<!-- symphony:octo/app#14:1:review:1 -->"]
    assert review_report =~ "La revisión encontró hallazgos que requieren corrección."
    assert review_report =~ "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
    refute review_report =~ "Review reported findings"

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "a Review report with findings returns to Build instead of Human Review" do
    issue = issue("octo/app#13", 13)
    finding = %{"id" => "REV-13-1", "reproduction" => "Run the affected path.", "criterion" => "The implementation preserves the required behavior."}
    review_with_finding = Map.put(review("first"), "findings", [finding])

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("first"), build("fixed")],
          qa: [qa("first"), qa("fixed")],
          review: [review_with_finding, Map.put(review("fixed"), "resolutions", [finding["id"]])]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 2}) == [finding]

    review_report = lookup(table, {:reports, issue.id})["<!-- symphony:octo/app#13:1:review:1 -->"]
    assert review_report =~ "### Findings"
    assert review_report =~ "`REV-13-1`"
    assert review_report =~ "Reproduction: Run the affected path."
    assert review_report =~ "Criterion: The implementation preserves the required behavior."
    refute review_report =~ "\"reproduction\""

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  defp start_board(issues, agent_results) do
    table = :ets.new(:pipeline_board, [:set, :public])
    Enum.each(issues, &:ets.insert(table, {{:issue, &1.id}, &1}))

    for {issue_id, results_by_phase} <- agent_results,
        {phase, results} <- results_by_phase,
        {result, index} <- Enum.with_index(results, 1) do
      :ets.insert(table, {{:agent_result, issue_id, phase, index}, result})
    end

    table
  end

  defp pipeline_database!(table, opts \\ []) do
    env_keys = [:pipeline_test_board, :pipeline_database_path, :pipeline_test_workspace, :github_projects_client_module]
    previous_env = Map.new(env_keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    root = Path.join(System.tmp_dir!(), "symphony-pipeline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "pipeline.sqlite3")
    workspace = Path.join(root, "workspaces")
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :pipeline_test_board, table)
    Application.put_env(:symphony_elixir, :github_projects_client_module, __MODULE__.FakeClient)
    Application.put_env(:symphony_elixir, :pipeline_database_path, path)
    Application.put_env(:symphony_elixir, :pipeline_test_workspace, workspace)
    write_pipeline_workflow!(Keyword.get(opts, :retry_backoff_ms, 1))

    on_exit(fn ->
      File.rm_rf(root)
      if :ets.info(table) != :undefined, do: :ets.delete(table)

      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)
    end)

    path
  end

  defp write_pipeline_workflow!(retry_backoff_ms) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github_projects
      active_states: [Ready, Building, QA, Review, Human Review]
      terminal_states: [closed, Dropped]
      provider:
        owner: acme
        project_number: 1
        repositories:
          - repository: octo/app
            base_branch: main
            prepare_command: "true"
            required_checks: ["true"]
        token: test-token
    polling:
      interval_ms: 20
    workspace:
      root: /tmp/symphony-pipeline-workspaces
    agent:
      max_concurrent_agents: 5
      max_turns: 2
      max_retry_backoff_ms: #{retry_backoff_ms}
    codex:
      stall_timeout_ms: 0
    ---
    Return JSON phase reports.
    """)

    assert :ok = WorkflowStore.force_reload()
  end

  defp default_status_values do
    %{backlog: "Backlog", ready: "Ready", building: "Building", qa: "QA", review: "Review", human_review: "Human Review", blocked: "Blocked", dropped: "Dropped", done: "Done"}
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Pipeline#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, agent_runner: __MODULE__.FakeAgent)
    pid
  end

  defp stop_orchestrator(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  end

  defp issue(id, number) do
    %Issue{
      id: id,
      identifier: id,
      title: "Pipeline integration #{number}",
      description: "Implement the acceptance criteria.",
      state: "Ready",
      branch_name: "symphony/octo-app-#{number}",
      url: "https://github.com/octo/app/issues/#{number}",
      dispatchable: true,
      native_ref: %{
        repository: "octo/app",
        base_branch: "main",
        prepare_command: "true",
        required_checks: ["true"],
        project_status: "Ready"
      }
    }
  end

  defp build(sha) do
    %{
      "outcome" => "ready",
      "summary" => "Implemented the task.",
      "criteria" => ["Acceptance criterion completed."],
      "changes" => ["Updated implementation."],
      "checks" => [],
      "risks" => [],
      "next_step" => "Run QA.",
      "sha" => sha
    }
  end

  defp build_es(sha) do
    Map.merge(build(sha), %{
      "summary" => "Implementé los cambios solicitados.",
      "criteria" => ["Se cumple el criterio de aceptación."],
      "changes" => ["Actualicé la implementación."],
      "next_step" => "QA debe revisar el SHA actual."
    })
  end

  defp qa(sha) do
    %{
      "outcome" => "passed",
      "summary" => "All required checks passed.",
      "criteria" => ["Acceptance criterion verified."],
      "changes" => [],
      "checks" => [%{"name" => "true", "status" => "passed", "evidence" => "agent report"}],
      "findings" => [],
      "next_step" => "Run autonomous review.",
      "sha" => sha
    }
  end

  defp qa_es(sha) do
    Map.merge(qa(sha), %{
      "summary" => "Pasaron las comprobaciones requeridas.",
      "criteria" => ["La implementación cumple el criterio."],
      "changes" => [],
      "next_step" => "Review debe inspeccionar el SHA actual."
    })
  end

  defp qa_missing_check(sha) do
    %{qa(sha) | "checks" => [%{"name" => "sh ./check.sh", "status" => "passed", "evidence" => "agent claimed success"}]}
  end

  defp review(sha) do
    %{
      "outcome" => "passed",
      "summary" => "No defects found.",
      "findings" => [],
      "resolutions" => [],
      "next_step" => "Wait for human review.",
      "sha" => sha
    }
  end

  defp review_es(sha) do
    Map.merge(review(sha), %{
      "summary" => "No se encontraron defectos.",
      "next_step" => "Esperar la revisión humana."
    })
  end

  defp no_changes do
    %{
      "outcome" => "no_changes",
      "summary" => "El comportamiento solicitado ya existe.",
      "reason" => "No hacen falta cambios de código.",
      "criteria" => ["Ya se cumplen todos los criterios."],
      "changes" => [],
      "checks" => [],
      "risks" => [],
      "next_step" => "Esperar la confirmación de una persona.",
      "sha" => nil
    }
  end

  defp blocked do
    %{
      "outcome" => "blocked",
      "summary" => "Hace falta acceso al entorno de pruebas.",
      "reason" => "No están disponibles las credenciales necesarias para las pruebas.",
      "criteria" => [],
      "changes" => [],
      "checks" => [],
      "risks" => ["No se puede ejecutar el entorno requerido."],
      "next_step" => "Resuelve el acceso y mueve la tarea a Ready.",
      "sha" => nil
    }
  end

  defp project_state(table, issue_id), do: table |> fetch_issue(issue_id) |> Map.fetch!(:state)

  defp pull_request(table, issue_id) do
    case :ets.lookup(table, {:pull_request, issue_id}) do
      [{_, pr}] -> pr
      [] -> nil
    end
  end

  defp pull_request_count(table, issue_id), do: if(pull_request(table, issue_id), do: 1, else: 0)
  defp report_phases(table, issue_id), do: lookup(table, {:report_history, issue_id}) || []
  defp agent_calls(table, issue_id), do: Enum.sum(Enum.map([:build, :qa, :review], &agent_calls(table, issue_id, &1)))
  defp agent_calls(table, issue_id, phase), do: lookup(table, {:agent_calls, issue_id, phase}) || 0

  defp set_project_state(table, issue_id, status) do
    active_states = Config.settings!().tracker.active_states
    ready_status = "Ready"
    blocked_status = "Blocked"
    issue = fetch_issue(table, issue_id)
    dispatchable = status in active_states

    updated = %{
      issue
      | state: status,
        dispatchable: dispatchable,
        requeueable: status == ready_status,
        tracker_blocked: status == blocked_status,
        native_ref: Map.put(issue.native_ref, :project_status, status)
    }

    :ets.insert(table, {{:issue, issue_id}, updated})
  end

  defp set_github_issue_state(table, issue_id, status) do
    issue = fetch_issue(table, issue_id)
    :ets.insert(table, {{:issue, issue_id}, %{issue | state: status, dispatchable: false}})
  end

  defp set_issue_description(table, issue_id, description) do
    issue = fetch_issue(table, issue_id)
    :ets.insert(table, {{:issue, issue_id}, %{issue | description: description}})
  end

  defp set_pull_request_merged(table, issue_id, value) do
    pr = pull_request(table, issue_id)
    :ets.insert(table, {{:pull_request, issue_id}, %{pr | merged: value}})
  end

  defp fetch_issue(table, issue_id), do: table |> :ets.lookup({:issue, issue_id}) |> hd() |> elem(1)

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def ensure_test_workspace!(issue) do
    workspace = workspace_path(issue)
    File.mkdir_p!(workspace)

    if not File.dir?(Path.join(workspace, ".git")) do
      {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Pipeline Test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "pipeline-test@example.invalid"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "--allow-empty", "-m", "initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", issue.branch_name], cd: workspace, stderr_to_stdout: true)
    end

    workspace
  end

  def workspace_path(issue) do
    root = Application.fetch_env!(:symphony_elixir, :pipeline_test_workspace)
    Path.join(root, SymphonyElixir.Workspace.workspace_key(issue))
  end

  defp await(predicate, attempts \\ 400)
  defp await(_predicate, 0), do: false

  defp await(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      await(predicate, attempts - 1)
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FakeAgent do
  def run(issue, recipient, opts) do
    phase = Keyword.fetch!(opts, :phase)
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    workspace = SymphonyElixir.PipelineIntegrationTest.ensure_test_workspace!(issue)

    if phase == :qa do
      send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: workspace, worker_host: Keyword.get(opts, :worker_host)}})
    end

    count = :ets.update_counter(table, {:agent_calls, issue.id, phase}, {2, 1}, {{:agent_calls, issue.id, phase}, 0})
    result = table |> :ets.lookup({:agent_result, issue.id, phase, count}) |> hd() |> elem(1)
    :ets.insert(table, {{:agent_prior_findings, issue.id, phase, count}, Keyword.get(opts, :prior_findings, [])})

    case {phase, result} do
      {:build, %{"sha" => sha} = result} when is_binary(sha) ->
        File.rm_rf!(Path.join(workspace, "qa-mutation"))
        File.write!(Path.join(workspace, "delivery.txt"), sha)
        {_output, 0} = System.cmd("git", ["add", "delivery.txt"], cd: workspace, stderr_to_stdout: true)
        {_output, 0} = System.cmd("git", ["commit", "-m", "deliver #{sha}"], cd: workspace, stderr_to_stdout: true)
        {remote_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
        remote_sha = String.trim(remote_sha)
        :ets.insert(table, {{:remote_sha, issue.id}, remote_sha})
        Map.put(result, "sha", remote_sha)

      {phase, %{} = result} when phase in [:qa, :review] ->
        result = Map.put(result, "sha", :ets.lookup_element(table, {:remote_sha, issue.id}, 2))

        if phase == :qa and :ets.lookup(table, {:dirty_once, issue.id}) != [] do
          :ets.delete(table, {:dirty_once, issue.id})
          File.write!(Path.join(workspace, "qa-mutation"), "QA changed the delivered workspace")
        end

        result

      _ ->
        result
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FakeClient do
  alias SymphonyElixir.Config

  @statuses %{
    ready: "Ready",
    building: "Building",
    qa: "QA",
    review: "Review",
    human_review: "Human Review",
    blocked: "Blocked",
    dropped: "Dropped",
    done: "Done"
  }

  def fetch_issues_by_states(states) do
    {:ok, issues() |> Enum.filter(&(&1.state in states))}
  end

  def fetch_issues_by_ids(ids), do: {:ok, Enum.filter(issues(), &(&1.id in ids))}
  def claim_issue(issue), do: set_pipeline_status(issue, :building)
  def complete_issue(issue), do: set_pipeline_status(issue, :done)
  def block_issue(issue, _reason), do: set_pipeline_status(issue, :blocked)

  def set_pipeline_status(issue, status, _reason \\ nil) do
    table = table()
    current = fetch_issue(table, issue.id)
    state = Map.fetch!(@statuses, status)

    updated = %{
      current
      | state: state,
        dispatchable: state in Config.settings!().tracker.active_states,
        requeueable: state == @statuses.ready,
        tracker_blocked: state == @statuses.blocked,
        native_ref: Map.put(current.native_ref, :project_status, state)
    }

    :ets.insert(table, {{:issue, issue.id}, updated})
    :ok
  end

  def validate_pipeline_delivery(issue, branch, sha) do
    table = table()
    valid = branch == issue.branch_name and issue.native_ref.repository == "octo/app" and lookup(table, {:remote_sha, issue.id}) == sha

    if valid and lookup(table, :change_sha_after_validation) do
      :ets.delete(table, :change_sha_after_validation)
      :ets.insert(table, {{:remote_sha, issue.id}, "changed-after-validation"})
    end

    if valid, do: :ok, else: {:error, :invalid_delivery}
  end

  def upsert_pull_request(issue, attrs) do
    table = table()

    pr =
      lookup(table, {:pull_request, issue.id}) ||
        %{
          number: 100 + issue_index(issue),
          branch: attrs.branch,
          base: attrs.base,
          sha: nil,
          draft: true,
          merged: false,
          body: attrs.body,
          url: "https://github.com/octo/app/pull/#{100 + issue_index(issue)}"
        }

    updated = %{pr | sha: attrs.sha, draft: true, body: attrs.body}
    :ets.insert(table, {{:pull_request, issue.id}, updated})

    if lookup(table, :uncertain_pr_once) do
      :ets.delete(table, :uncertain_pr_once)
      {:error, :response_lost}
    else
      {:ok, updated}
    end
  end

  def set_pull_request_stage(issue, _number, stage) do
    table = table()
    pr = lookup(table, {:pull_request, issue.id})
    updated = %{pr | draft: stage == :draft}
    :ets.insert(table, {{:pull_request, issue.id}, updated})
    {:ok, updated}
  end

  def pull_request(issue), do: {:ok, lookup(table(), {:pull_request, issue.id})}

  def publish_phase_report(issue, marker, body, phase) do
    table = table()
    key = {:report, issue.id, phase}
    reports = lookup(table, {:reports, issue.id}) || %{}

    if Map.has_key?(reports, marker) do
      :ok
    else
      :ets.insert(table, {{:reports, issue.id}, Map.put(reports, marker, body)})
      :ets.insert(table, {key, body})
      :ets.insert(table, {{:report_history, issue.id}, (lookup(table, {:report_history, issue.id}) || []) ++ [String.to_existing_atom(phase)]})
    end

    if lookup(table, :uncertain_report_once) do
      :ets.delete(table, :uncertain_report_once)
      {:error, :response_lost}
    else
      :ok
    end
  end

  defp issues,
    do:
      table()
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:issue, _id}, issue} -> [issue]
        _ -> []
      end)

  defp table, do: Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
  defp fetch_issue(table, id), do: lookup(table, {:issue, id})

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp issue_index(%{id: id}), do: id |> String.split("#") |> List.last() |> String.to_integer()
end
