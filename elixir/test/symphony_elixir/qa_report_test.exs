defmodule SymphonyElixir.QAReportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.QAReport

  test "a passed report links every criterion to concrete passing evidence" do
    report = report()

    assert QAReport.valid?(report)
    assert QAReport.valid?(put_in(report, ["criteria", Access.at(0), "evidence"], ["host:make -C elixir all"]), ["make -C elixir all"])
    refute QAReport.valid?(report, ["missing host check"])
  end

  test "the report covers every source acceptance criterion" do
    description = "## Acceptance Criteria\n- The search returns matching results.\n- The search respects the configured limit."

    refute QAReport.valid?(report(), [], description)

    complete_report =
      update_in(report(), ["criteria"], fn criteria ->
        criteria ++
          [
            %{
              "criterion" => "The search respects the configured limit.",
              "status" => "passed",
              "procedure" => "Run a search at the configured result limit.",
              "evidence" => ["unit-search"]
            }
          ]
      end)

    assert QAReport.valid?(complete_report, [], description)
    assert QAReport.valid?(Map.put(complete_report, "criteria", Enum.reverse(complete_report["criteria"])), [], description)
    refute QAReport.valid?(Map.put(complete_report, "criteria", Enum.drop(complete_report["criteria"], -1)), [], description)
  end

  test "acceptance criteria are read from English and Spanish issue sections" do
    assert ["First criterion.", "Second criterion."] =
             QAReport.criteria_from_description("""
             ## Acceptance Criteria

             - [ ] First criterion.
             2. Second criterion.

             ## Verification
             - Do not include this line.
             """)

    assert ["Primer criterio."] =
             QAReport.criteria_from_description("## Criterios de aceptación\n- Primer criterio.")

    assert [] = QAReport.criteria_from_description("## Acceptance Criteria\n\n## Verification\n- Run tests.")

    assert ["The result is clearly reported."] =
             QAReport.criteria_from_description("## Acceptance Criteria\nThe result is clearly reported.")
  end

  test "a criterion without a real evidence reference cannot be covered by the summary" do
    report = report()

    refute QAReport.valid?(put_in(report, ["criteria", Access.at(0), "evidence"], []))
    refute QAReport.valid?(put_in(report, ["criteria", Access.at(0), "evidence"], ["missing-check"]))
  end

  test "malformed report sections and checks are rejected" do
    report = report()

    refute QAReport.valid?("not a report")
    refute QAReport.valid?(%{}, :invalid_host_check_list)
    refute QAReport.valid?(Map.put(report, "checks", nil))
    refute QAReport.valid?(put_in(report, ["checks", Access.at(0)], "not a check"))
    refute QAReport.valid?(Map.put(report, "host_checks", "not a check list"))
    refute QAReport.valid?(Map.put(report, "host_checks", [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}]))
    refute QAReport.valid?(Map.put(report, "criteria", nil))
    refute QAReport.valid?(Map.put(report, "criteria", ["unstructured criterion"]))
    refute QAReport.valid?(Map.put(report, "gaps", "unstructured gap"))
    refute QAReport.valid?(Map.put(report, "gaps", ["unstructured gap"]))
  end

  test "host evidence can be deferred before host checks are attached, but missing references fail" do
    report =
      report()
      |> Map.put("host_checks", nil)
      |> put_in(["criteria", Access.at(0), "evidence"], ["host:make -C elixir all"])

    assert QAReport.valid?(report)

    missing_host_check = Map.put(report, "host_checks", [])
    refute QAReport.valid?(missing_host_check)
    refute QAReport.valid?(put_in(report, ["criteria", Access.at(0), "evidence"], ["unknown-evidence"]))
  end

  test "required checks with non-passing states cannot approve QA" do
    for status <- ["failed", "unstable", "skipped", "unavailable"] do
      report =
        report()
        |> put_in(["checks", Access.at(0), "status"], status)
        |> put_in(["checks", Access.at(0), "reason"], "The required check did not complete successfully.")
        |> put_in(["criteria", Access.at(0), "status"], status)

      refute QAReport.valid?(report)

      if status == "unavailable" do
        refute QAReport.valid?(Map.put(report, "outcome", "changes_requested"))
      end
    end
  end

  test "skipped checks need a reason and operational blockers carry recovery guidance" do
    skipped =
      report()
      |> Map.put("outcome", "changes_requested")
      |> put_in(["checks", Access.at(0), "status"], "skipped")
      |> put_in(["checks", Access.at(0), "reason"], "The check was intentionally skipped.")
      |> put_in(["criteria", Access.at(0), "status"], "skipped")

    blocked =
      report()
      |> Map.put("outcome", "blocked")
      |> Map.put("reason", "QA cannot access the test service.")
      |> Map.put("next_step", "Restore test service access and rerun QA on the same SHA.")
      |> put_in(["checks", Access.at(0), "status"], "unavailable")
      |> put_in(["checks", Access.at(0), "reason"], "The service credentials are missing.")
      |> put_in(["criteria", Access.at(0), "status"], "unavailable")

    assert QAReport.valid?(skipped)
    refute QAReport.valid?(put_in(skipped, ["checks", Access.at(0), "reason"], nil))
    assert QAReport.valid?(blocked)
    refute QAReport.valid?(put_in(blocked, ["next_step"], " "))
    refute QAReport.valid?(put_in(report(), ["host_checks", Access.at(0), "status"], "unavailable"))
  end

  test "coverage gaps include scenario, impact, missing coverage, and priority" do
    report =
      report()
      |> Map.put("gaps", [
        %{
          "scenario" => "The upstream service times out.",
          "impact" => "Requests may hang without a bounded failure.",
          "missing_coverage" => "No timeout-path test exists.",
          "priority" => "high"
        },
        %{
          "scenario" => "The user reaches the configured request limit.",
          "impact" => "The result may be truncated without an explanation.",
          "missing_coverage" => "No limit-boundary test exists.",
          "priority" => "medium"
        },
        %{
          "scenario" => "The caller lacks permission.",
          "impact" => "The request may expose restricted records.",
          "missing_coverage" => "No permission-denial test exists.",
          "priority" => "low"
        }
      ])

    assert QAReport.valid?(report)
    refute QAReport.valid?(put_in(report, ["gaps", Access.at(0), "missing_coverage"], ""))
    refute QAReport.valid?(put_in(report, ["gaps", Access.at(0), "priority"], "urgent"))
    refute QAReport.valid?(Map.put(report, "gaps", Enum.reverse(report["gaps"])))
  end

  defp report do
    %{
      "outcome" => "passed",
      "summary" => "The acceptance criterion was verified.",
      "sha" => String.duplicate("a", 40),
      "criteria" => [
        %{
          "criterion" => "The search returns matching results.",
          "status" => "passed",
          "procedure" => "Run the search query and compare the returned records.",
          "evidence" => ["unit-search"]
        }
      ],
      "changes" => [],
      "checks" => [
        %{
          "id" => "unit-search",
          "layer" => "unit",
          "command" => "mix test test/symphony_elixir/search_test.exs",
          "status" => "passed",
          "result" => "1 test, 0 failures.",
          "evidence" => "test-output: search-test-1",
          "required" => true,
          "reason" => nil
        }
      ],
      "host_checks" => [
        %{
          "name" => "make -C elixir all",
          "status" => "passed",
          "evidence" => "Host exit status 0 on the accepted SHA.",
          "source" => "host"
        }
      ],
      "gaps" => [],
      "findings" => [],
      "next_step" => "Continue to Review.",
      "reason" => nil
    }
  end
end
