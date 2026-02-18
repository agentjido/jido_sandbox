defmodule Jido.Workspace.Integration.Scenario17TestGenerationLoopTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 17 goal: Generate missing tests, run suite, and iterate until threshold or max cycles.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @baseline_path "/artifacts/coverage_baseline.json"
  @cycles_path "/artifacts/cycle_metrics.json"
  @final_report_path "/artifacts/final_coverage_report.json"
  @error_path "/artifacts/errors.json"

  test "coverage-guided loop accepts only green cycles and reports final delta", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("17_test_generation_loop", "spec-17", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    target_coverage = 80.0
    max_cycles = 3
    baseline_coverage = 72.0

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/project")
      {:ok, workspace} = Workspace.mkdir(workspace, "/project/test")
      ScenarioHelpers.put_workspace(workspace)

      provider_hint = provider_hint(output_root)

      baseline = %{
        "coverage" => baseline_coverage,
        "target_coverage" => target_coverage,
        "provider_hint" => provider_hint
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @baseline_path, baseline)
      ScenarioHelpers.put_workspace(workspace)

      {workspace, metrics, final_coverage} =
        run_cycles(workspace, baseline_coverage, target_coverage, max_cycles, 1, [])

      workspace = ensure_artifacts_dir(workspace)
      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @baseline_path, baseline)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @cycles_path, metrics)
      ScenarioHelpers.put_workspace(workspace)

      final_report = %{
        "baseline_coverage" => baseline_coverage,
        "final_coverage" => final_coverage,
        "delta" => Float.round(final_coverage - baseline_coverage, 2),
        "target_coverage" => target_coverage,
        "target_reached" => final_coverage >= target_coverage,
        "max_cycles" => max_cycles
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @final_report_path, final_report)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "17_test_generation_loop",
          "ok",
          workspace_id,
          [
            {"baseline_coverage", baseline_coverage},
            {"final_coverage", final_coverage},
            {"target_coverage", target_coverage},
            {"target_reached", final_coverage >= target_coverage}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      baseline_file = Path.join(output_root, "artifacts/coverage_baseline.json")
      cycles_file = Path.join(output_root, "artifacts/cycle_metrics.json")
      final_file = Path.join(output_root, "artifacts/final_coverage_report.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(baseline_file)
      assert File.exists?(cycles_file)
      assert File.exists?(final_file)
      assert File.exists?(summary_file)

      assert final_coverage >= baseline_coverage
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_cycles(workspace, coverage, target, _max_cycles, _cycle, metrics) when coverage >= target do
    {workspace, Enum.reverse(metrics), coverage}
  end

  defp run_cycles(workspace, coverage, _target, max_cycles, cycle, metrics) when cycle > max_cycles do
    {workspace, Enum.reverse(metrics), coverage}
  end

  defp run_cycles(workspace, coverage, target, max_cycles, cycle, metrics) do
    {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
    ScenarioHelpers.put_workspace(workspace)

    proposal = proposal_for_cycle(cycle)
    proposed_delta = proposed_delta_for_cycle(cycle)
    suite_green = suite_green_for_cycle(cycle)

    if suite_green do
      updated_coverage = Float.round(min(100.0, coverage + proposed_delta), 2)
      generated_test = "/project/test/generated_cycle_#{cycle}_test.exs"

      {:ok, workspace} = Workspace.write(workspace, generated_test, generated_test_content(cycle))
      ScenarioHelpers.put_workspace(workspace)

      {:ok, checkpoint_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      metric = %{
        "cycle" => cycle,
        "proposal" => proposal,
        "status" => "accepted",
        "before_coverage" => coverage,
        "after_coverage" => updated_coverage,
        "snapshot_id" => snapshot_id,
        "checkpoint_id" => checkpoint_id
      }

      run_cycles(workspace, updated_coverage, target, max_cycles, cycle + 1, [metric | metrics])
    else
      {next_workspace, status, restore_error} =
        case Workspace.restore(workspace, snapshot_id) do
          {:ok, restored_workspace} ->
            ScenarioHelpers.put_workspace(restored_workspace)
            {restored_workspace, "reverted", nil}

          {:error, reason} ->
            {workspace, "revert_restore_failed", inspect(reason)}
        end

      metric = %{
        "cycle" => cycle,
        "proposal" => proposal,
        "status" => status,
        "before_coverage" => coverage,
        "after_coverage" => coverage,
        "snapshot_id" => snapshot_id,
        "restore_error" => restore_error
      }

      run_cycles(next_workspace, coverage, target, max_cycles, cycle + 1, [metric | metrics])
    end
  end

  defp proposal_for_cycle(1), do: "Add focused tests for low-coverage branch conditions."
  defp proposal_for_cycle(2), do: "Add concurrent test path with shared state coverage."
  defp proposal_for_cycle(3), do: "Add edge-case input validation tests."
  defp proposal_for_cycle(_), do: "No additional proposal."

  defp proposed_delta_for_cycle(1), do: 4.0
  defp proposed_delta_for_cycle(2), do: 3.0
  defp proposed_delta_for_cycle(3), do: 5.5
  defp proposed_delta_for_cycle(_), do: 0.0

  defp suite_green_for_cycle(2), do: false
  defp suite_green_for_cycle(_), do: true

  defp generated_test_content(cycle) do
    """
    defmodule GeneratedCycle#{cycle}Test do
      use ExUnit.Case

      test "generated cycle #{cycle}" do
        assert true
      end
    end
    """
  end

  defp provider_hint(output_root) do
    selected_provider =
      Harness.providers()
      |> then(&HarnessScenarioHelpers.select_default_or_first_provider(&1, Harness.default_provider()))

    case selected_provider do
      nil ->
        %{"provider" => nil, "status" => "none", "hint" => ""}

      provider ->
        prompt = "Suggest one short sentence for test generation focus."

        case Harness.run(provider, prompt, cwd: output_root, timeout_ms: 8_000) do
          {:ok, stream} ->
            case HarnessScenarioHelpers.collect_events(stream, 80) do
              {:ok, events, _} ->
                %{
                  "provider" => Atom.to_string(provider),
                  "status" => "ok",
                  "hint" => HarnessScenarioHelpers.final_output_text(events)
                }

              {:error, reason, _events} ->
                %{
                  "provider" => Atom.to_string(provider),
                  "status" => "stream_error",
                  "hint" => inspect(reason)
                }
            end

          {:error, reason} ->
            %{
              "provider" => Atom.to_string(provider),
              "status" => "run_error",
              "hint" => inspect(reason)
            }
        end
    end
  end

  defp ensure_artifacts_dir(workspace) do
    case Workspace.mkdir(workspace, "/artifacts") do
      {:ok, ensured_workspace} -> ensured_workspace
      {:error, _reason} -> workspace
    end
  end
end
