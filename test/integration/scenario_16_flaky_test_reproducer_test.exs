defmodule Jido.Workspace.Integration.Scenario16FlakyTestReproducerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 16 goal: Reproduce intermittent tests, classify flake patterns, and emit stabilization patch plan.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @matrix_path "/artifacts/flake_matrix.json"
  @recommendations_path "/artifacts/recommendations.md"
  @verification_path "/artifacts/verification_matrix.json"
  @error_path "/artifacts/errors.json"

  test "flake reproducer emits signature matrix and stabilization recommendations", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("16_flaky_test_reproducer", "spec-16", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      run_count = 20
      baseline_runs = simulate_runs(run_count, false)
      reproduced_failures = Enum.flat_map(baseline_runs, & &1.failures)

      baseline_matrix = build_flake_matrix(baseline_runs)
      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @matrix_path, baseline_matrix)
      ScenarioHelpers.put_workspace(workspace)

      recommendations_md = build_recommendations(reproduced_failures)
      {:ok, workspace} = Workspace.write(workspace, @recommendations_path, recommendations_md)
      ScenarioHelpers.put_workspace(workspace)

      verification_runs = simulate_runs(run_count, true)
      verification_matrix = build_flake_matrix(verification_runs)
      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @verification_path, verification_matrix)
      ScenarioHelpers.put_workspace(workspace)

      status = if reproduced_failures == [], do: "inconclusive", else: "ok"

      summary_json =
        ScenarioHelpers.summary_json(
          "16_flaky_test_reproducer",
          status,
          workspace_id,
          [
            {"run_count", run_count},
            {"baseline_failure_count", length(reproduced_failures)},
            {"verification_failure_count", Enum.flat_map(verification_runs, & &1.failures) |> length()}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      matrix_file = Path.join(output_root, "artifacts/flake_matrix.json")
      recommendations_file = Path.join(output_root, "artifacts/recommendations.md")
      verification_file = Path.join(output_root, "artifacts/verification_matrix.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(matrix_file)
      assert File.exists?(recommendations_file)
      assert File.exists?(verification_file)
      assert File.exists?(summary_file)

      assert {:ok, matrix_contents} = File.read(matrix_file)
      assert String.contains?(matrix_contents, "\"failure_frequency\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp simulate_runs(run_count, stabilized?) do
    for run <- 1..run_count do
      failures =
        []
        |> maybe_add_failure(rem(run, 5) == 0, "Workspace.FlakyTimeoutTest", "timeout waiting for process")
        |> maybe_add_failure(rem(run, 7) == 0, "Workspace.RaceConditionTest", "race detected on shared state")
        |> maybe_add_failure(
          not stabilized? and rem(run, 11) == 0,
          "Workspace.RandomSeedTest",
          "seed-dependent assertion"
        )

      %{run: run, failures: failures}
    end
  end

  defp maybe_add_failure(failures, true, test_name, signature) do
    [%{"test" => test_name, "signature" => signature} | failures]
  end

  defp maybe_add_failure(failures, false, _test_name, _signature), do: failures

  defp build_flake_matrix(runs) do
    all_failures = Enum.flat_map(runs, & &1.failures)
    run_count = length(runs)
    failure_frequency = Enum.frequencies_by(all_failures, & &1["test"])
    signature_frequency = Enum.frequencies_by(all_failures, & &1["signature"])

    %{
      "run_count" => run_count,
      "failed_run_count" => Enum.count(runs, &(&1.failures != [])),
      "total_failure_events" => length(all_failures),
      "failure_frequency" => failure_frequency,
      "signature_frequency" => signature_frequency
    }
  end

  defp build_recommendations([]) do
    """
    # Flake Recommendations

    No reproducible flakes detected in this run window. Increase repeat count and capture additional seeds.
    """
  end

  defp build_recommendations(failures) do
    top_tests =
      failures
      |> Enum.frequencies_by(& &1["test"])
      |> Enum.sort_by(fn {_test, count} -> -count end)
      |> Enum.take(3)

    bullets =
      top_tests
      |> Enum.map(fn {test_name, count} ->
        "- #{test_name}: observed #{count} failures. Add deterministic wait/seed controls and isolate shared state."
      end)
      |> Enum.join("\n")

    """
    # Flake Recommendations

    #{bullets}
    """
  end
end
