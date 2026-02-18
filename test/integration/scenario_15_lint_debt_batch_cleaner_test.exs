defmodule Jido.Workspace.Integration.Scenario15LintDebtBatchCleanerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 15 goal: Iteratively fix lint issues in controlled batches with checkpoints.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @metrics_path "/artifacts/batch_metrics.json"
  @lint_summary_path "/artifacts/lint_summary.json"
  @error_path "/artifacts/errors.json"
  @target_file "/project/lib/sample.ex"

  test "lint debt cleaner reduces deterministic issue count in batches", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("15_lint_debt_batch_cleaner", "spec-15", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/project")
      {:ok, workspace} = Workspace.mkdir(workspace, "/project/lib")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, @target_file, sample_with_lint_debt())
      ScenarioHelpers.put_workspace(workspace)

      initial_count = lint_count(workspace, @target_file)
      {workspace, metrics, final_count} = run_batches(workspace, @target_file, 2, 4, [])
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @metrics_path, metrics)
      ScenarioHelpers.put_workspace(workspace)

      lint_summary = %{
        "initial_issue_count" => initial_count,
        "final_issue_count" => final_count,
        "issue_delta" => initial_count - final_count,
        "batch_count" => length(metrics)
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @lint_summary_path, lint_summary)
      ScenarioHelpers.put_workspace(workspace)

      status = if final_count < initial_count, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "15_lint_debt_batch_cleaner",
          status,
          workspace_id,
          [
            {"initial_issue_count", initial_count},
            {"final_issue_count", final_count},
            {"batch_count", length(metrics)}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      metrics_file = Path.join(output_root, "artifacts/batch_metrics.json")
      lint_summary_file = Path.join(output_root, "artifacts/lint_summary.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(metrics_file)
      assert File.exists?(lint_summary_file)
      assert File.exists?(summary_file)

      assert final_count <= initial_count
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_batches(workspace, target_file, _batch_size, 0, metrics) do
    {workspace, Enum.reverse(metrics), lint_count(workspace, target_file)}
  end

  defp run_batches(workspace, target_file, batch_size, remaining_batches, metrics) do
    before_count = lint_count(workspace, target_file)

    cond do
      before_count == 0 ->
        {workspace, Enum.reverse(metrics), before_count}

      true ->
        {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
        ScenarioHelpers.put_workspace(workspace)

        {:ok, content} = Workspace.read(workspace, target_file)
        fixed_content = fix_n_issues(content, batch_size)
        {:ok, workspace} = Workspace.write(workspace, target_file, fixed_content)
        ScenarioHelpers.put_workspace(workspace)

        after_count = lint_count(workspace, target_file)

        if after_count < before_count do
          {:ok, checkpoint_id, workspace} = Workspace.snapshot(workspace)
          ScenarioHelpers.put_workspace(workspace)

          metric = %{
            "batch" => length(metrics) + 1,
            "before_count" => before_count,
            "after_count" => after_count,
            "status" => "applied",
            "checkpoint_snapshot_id" => checkpoint_id
          }

          run_batches(workspace, target_file, batch_size, remaining_batches - 1, [metric | metrics])
        else
          {:ok, workspace} = Workspace.restore(workspace, snapshot_id)
          ScenarioHelpers.put_workspace(workspace)

          metric = %{
            "batch" => length(metrics) + 1,
            "before_count" => before_count,
            "after_count" => before_count,
            "status" => "regression_restored",
            "restored_snapshot_id" => snapshot_id
          }

          run_batches(workspace, target_file, batch_size, remaining_batches - 1, [metric | metrics])
        end
    end
  end

  defp lint_count(workspace, target_file) do
    case Workspace.read(workspace, target_file) do
      {:ok, content} ->
        content
        |> String.split("LINT_ISSUE")
        |> length()
        |> Kernel.-(1)

      {:error, _} ->
        0
    end
  end

  defp fix_n_issues(content, 0), do: content

  defp fix_n_issues(content, n) when n > 0 do
    content
    |> String.replace("LINT_ISSUE", "FIXED_ISSUE", global: false)
    |> fix_n_issues(n - 1)
  end

  defp sample_with_lint_debt do
    """
    defmodule Sample do
      # LINT_ISSUE: unused alias
      # LINT_ISSUE: long line
      def run do
        :ok # LINT_ISSUE
      end
      # LINT_ISSUE: trailing whitespace
      # LINT_ISSUE: docs missing
      # LINT_ISSUE: function complexity
    end
    """
  end
end
