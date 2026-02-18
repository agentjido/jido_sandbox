defmodule Jido.Workspace.Integration.Scenario26IssueToPrFactoryTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 26 goal: Process a queue of issues into sequential branch+PR executions with per-issue artifacts.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @queue_input_path "/artifacts/issue_queue.json"
  @state_machine_path "/artifacts/retry_state_machine.json"
  @dashboard_path "/artifacts/dashboard.json"
  @resume_path "/artifacts/resume_state.json"
  @error_path "/artifacts/errors.json"

  test "issue queue factory writes per-issue outputs and resumable state artifact", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("26_issue_to_pr_factory", "spec-26", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    queue = issue_queue()

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts/issues")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @queue_input_path, %{"issues" => queue})
      ScenarioHelpers.put_workspace(workspace)

      {workspace, issue_runs, transitions} = process_queue(workspace, queue, [], [])
      workspace = ensure_artifacts_dir(workspace)
      ScenarioHelpers.put_workspace(workspace)

      retry_state_machine = %{
        "transitions" => transitions,
        "retry_count" => Enum.count(transitions, &(&1["state"] == "retrying")),
        "terminal_failures" => Enum.count(issue_runs, &(&1["status"] == "failed_terminal"))
      }

      {:ok, workspace} =
        HarnessScenarioHelpers.write_json_artifact(workspace, @state_machine_path, retry_state_machine)

      ScenarioHelpers.put_workspace(workspace)

      dashboard = %{
        "total_issues" => length(queue),
        "completed" => Enum.count(issue_runs, &String.starts_with?(&1["status"], "completed")),
        "failed_terminal" => Enum.count(issue_runs, &(&1["status"] == "failed_terminal")),
        "issues" => issue_runs
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @dashboard_path, dashboard)
      ScenarioHelpers.put_workspace(workspace)

      remaining = Enum.filter(issue_runs, &(&1["status"] != "completed"))

      resume_state = %{
        "resume_from_issue" => remaining |> List.first() |> then(&(&1 && &1["id"])),
        "remaining_count" => length(remaining),
        "remaining" => remaining,
        "can_resume" => true
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @resume_path, resume_state)
      ScenarioHelpers.put_workspace(workspace)

      status = if length(issue_runs) == length(queue), do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "26_issue_to_pr_factory",
          status,
          workspace_id,
          [
            {"issue_count", length(queue)},
            {"completed", Enum.count(issue_runs, &String.starts_with?(&1["status"], "completed"))},
            {"failed_terminal", Enum.count(issue_runs, &(&1["status"] == "failed_terminal"))},
            {"resume_remaining_count", length(remaining)}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      dashboard_file = Path.join(output_root, "artifacts/dashboard.json")
      state_machine_file = Path.join(output_root, "artifacts/retry_state_machine.json")
      resume_file = Path.join(output_root, "artifacts/resume_state.json")
      issue_2602_file = Path.join(output_root, "artifacts/issues/ISSUE-2602/run.json")

      assert File.exists?(summary_file)
      assert File.exists?(dashboard_file)
      assert File.exists?(state_machine_file)
      assert File.exists?(resume_file)
      assert File.exists?(issue_2602_file)

      assert {:ok, issue_2602_contents} = File.read(issue_2602_file)
      assert String.contains?(issue_2602_contents, "\"attempts\"")
      assert String.contains?(issue_2602_contents, "\"status\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp process_queue(workspace, [], issue_runs, transitions) do
    {workspace, Enum.reverse(issue_runs), Enum.reverse(transitions)}
  end

  defp process_queue(workspace, [issue | rest], issue_runs, transitions) do
    issue_id = issue["id"]
    issue_dir = "/artifacts/issues/#{issue_id}"
    :ok = ensure_issue_dir(workspace, issue_dir)

    {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
    ScenarioHelpers.put_workspace(workspace)

    transitions = [%{"issue" => issue_id, "state" => "started", "snapshot_id" => snapshot_id} | transitions]

    {run_result, new_transitions} =
      case issue_id do
        "ISSUE-2601" ->
          run = %{
            "id" => issue_id,
            "status" => "completed",
            "attempts" => 1,
            "branch" => "issue/2601-doc-typo",
            "pr_url" => "https://example.local/pr/2601"
          }

          {run, [%{"issue" => issue_id, "state" => "completed"} | transitions]}

        "ISSUE-2602" ->
          run = %{
            "id" => issue_id,
            "status" => "completed_with_retry",
            "attempts" => 2,
            "branch" => "issue/2602-lint-cleanup",
            "pr_url" => "https://example.local/pr/2602",
            "retry_reason" => "test flake on first attempt"
          }

          {run,
           [
             %{"issue" => issue_id, "state" => "completed"}
             | [%{"issue" => issue_id, "state" => "retrying"} | transitions]
           ]}

        "ISSUE-2603" ->
          run = %{
            "id" => issue_id,
            "status" => "failed_terminal",
            "attempts" => 1,
            "branch" => nil,
            "pr_url" => nil,
            "failure_reason" => "policy blocked write to protected file"
          }

          {run, [%{"issue" => issue_id, "state" => "failed_terminal"} | transitions]}
      end

    {:ok, workspace} = write_issue_artifact(workspace, issue_id, run_result)
    ScenarioHelpers.put_workspace(workspace)

    process_queue(workspace, rest, [run_result | issue_runs], new_transitions)
  end

  defp write_issue_artifact(workspace, issue_id, run_result) do
    path = "/artifacts/issues/#{issue_id}/run.json"
    HarnessScenarioHelpers.write_json_artifact(workspace, path, run_result)
  end

  defp ensure_issue_dir(workspace, issue_dir) do
    case Workspace.mkdir(workspace, issue_dir) do
      {:ok, _workspace} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp ensure_artifacts_dir(workspace) do
    case Workspace.mkdir(workspace, "/artifacts") do
      {:ok, ensured_workspace} -> ensured_workspace
      {:error, _reason} -> workspace
    end
  end

  defp issue_queue do
    [
      %{"id" => "ISSUE-2601", "title" => "Fix documentation typo", "priority" => 1},
      %{"id" => "ISSUE-2602", "title" => "Batch lint cleanup", "priority" => 2},
      %{"id" => "ISSUE-2603", "title" => "Refactor protected config", "priority" => 3}
    ]
  end
end
