defmodule SymphonyElixir.PipelineFindingsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pipeline.Findings

  test "resolutions match exact finding IDs and annotated IDs without matching partial IDs" do
    finding_id = "required-check:make -C elixir all"

    assert Findings.resolved?(finding_id, [finding_id])
    assert Findings.resolved?(finding_id, [finding_id <> " — resolved: check passed after the fix."])
    assert Findings.resolved?(finding_id, [%{"id" => finding_id, "status" => "not_applicable", "reason" => "The finding no longer applies."}])
    refute Findings.resolved?(finding_id, [%{"id" => finding_id, "status" => "not_applicable", "reason" => " "}])
    refute Findings.resolved?(finding_id, [finding_id <> " — still failing."])
    refute Findings.resolved?(finding_id, [nil])
    refute Findings.resolved?(nil, [finding_id])
    refute Findings.resolved?(finding_id, nil)
  end
end
