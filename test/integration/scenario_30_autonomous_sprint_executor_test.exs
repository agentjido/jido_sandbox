defmodule Jido.Workspace.Integration.Scenario30AutonomousSprintExecutorTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 30 goal: Execute a backlog for hours with checkpoints, multi-issue state, and multi-PR output.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @backlog_path "/artifacts/backlog.json"
  @checkpoint_state_path "/artifacts/checkpoints/state.json"
  @sprint_summary_path "/artifacts/sprint_summary.json"
  @error_path "/artifacts/errors.json"

  @provider_order [:codex, :amp, :gemini]

  test "autonomous sprint executor writes resumable checkpoints and carryover artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("30_autonomous_sprint_executor", "spec-30", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    backlog = sprint_backlog()
    time_budget_tasks = 2

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts/tasks")
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts/checkpoints")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @backlog_path, %{"tasks" => backlog})
      ScenarioHelpers.put_workspace(workspace)

      {workspace, task_runs, checkpoints} = execute_backlog(workspace, backlog, time_budget_tasks, output_root, [], [])
      workspace = ensure_artifacts_dirs(workspace)
      ScenarioHelpers.put_workspace(workspace)

      completed = Enum.filter(task_runs, &(&1["status"] == "completed"))
      carryovers = Enum.filter(task_runs, &(&1["status"] == "carryover"))

      checkpoint_state = %{
        "checkpoint_count" => length(checkpoints),
        "checkpoints" => checkpoints,
        "completed_ids" => Enum.map(completed, & &1["id"]),
        "remaining_ids" => Enum.map(carryovers, & &1["id"]),
        "can_resume" => true
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @checkpoint_state_path, checkpoint_state)
      ScenarioHelpers.put_workspace(workspace)

      sprint_summary = %{
        "total_tasks" => length(backlog),
        "completed_count" => length(completed),
        "carryover_count" => length(carryovers),
        "prs" => Enum.map(completed, & &1["pr_url"]),
        "tasks" => task_runs
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @sprint_summary_path, sprint_summary)
      ScenarioHelpers.put_workspace(workspace)

      status =
        if checkpoint_state["can_resume"] and length(task_runs) == length(backlog), do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "30_autonomous_sprint_executor",
          status,
          workspace_id,
          [
            {"task_count", length(backlog)},
            {"completed_count", length(completed)},
            {"carryover_count", length(carryovers)},
            {"checkpoint_count", length(checkpoints)}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      checkpoint_file = Path.join(output_root, "artifacts/checkpoints/state.json")
      sprint_summary_file = Path.join(output_root, "artifacts/sprint_summary.json")
      task_file = Path.join(output_root, "artifacts/tasks/TASK-3002.json")

      assert File.exists?(summary_file)
      assert File.exists?(checkpoint_file)
      assert File.exists?(sprint_summary_file)
      assert File.exists?(task_file)

      assert {:ok, checkpoint_contents} = File.read(checkpoint_file)
      assert String.contains?(checkpoint_contents, "\"can_resume\"")
      assert String.contains?(checkpoint_contents, "\"remaining_ids\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp execute_backlog(workspace, [], _budget, _output_root, task_runs, checkpoints) do
    {workspace, Enum.reverse(task_runs), Enum.reverse(checkpoints)}
  end

  defp execute_backlog(workspace, [task | rest], budget, output_root, task_runs, checkpoints) do
    task_id = task["id"]
    task_artifact_path = "/artifacts/tasks/#{task_id}.json"

    {plan_provider, plan_status} =
      case HarnessScenarioHelpers.run_with_failover(
             @provider_order,
             "One short planning sentence for #{task["title"]}.",
             [cwd: output_root, timeout_ms: 8_000],
             80
           ) do
        {:ok, %{provider: provider}} -> {Atom.to_string(provider), "provider_plan"}
        {:error, _attempts} -> {nil, "fallback_plan"}
      end

    {task_status, pr_url, remaining_budget} =
      if budget > 0 do
        {"completed", "https://example.local/sprint/pr/#{task_id}", budget - 1}
      else
        {"carryover", nil, budget}
      end

    {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
    ScenarioHelpers.put_workspace(workspace)

    phase_checkpoints = [
      %{"task_id" => task_id, "phase" => "plan", "snapshot_id" => snapshot_id},
      %{"task_id" => task_id, "phase" => "implement", "snapshot_id" => snapshot_id},
      %{"task_id" => task_id, "phase" => "validate", "snapshot_id" => snapshot_id},
      %{"task_id" => task_id, "phase" => "publish", "snapshot_id" => snapshot_id}
    ]

    task_result = %{
      "id" => task_id,
      "title" => task["title"],
      "status" => task_status,
      "plan_provider" => plan_provider,
      "plan_status" => plan_status,
      "pr_url" => pr_url,
      "snapshot_id" => snapshot_id
    }

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, task_artifact_path, task_result)
    ScenarioHelpers.put_workspace(workspace)

    execute_backlog(
      workspace,
      rest,
      remaining_budget,
      output_root,
      [task_result | task_runs],
      Enum.reverse(phase_checkpoints) ++ checkpoints
    )
  end

  defp ensure_artifacts_dirs(workspace) do
    workspace
    |> ensure_dir("/artifacts")
    |> ensure_dir("/artifacts/tasks")
    |> ensure_dir("/artifacts/checkpoints")
  end

  defp ensure_dir(workspace, path) do
    case Workspace.mkdir(workspace, path) do
      {:ok, ensured_workspace} -> ensured_workspace
      {:error, _reason} -> workspace
    end
  end

  defp sprint_backlog do
    [
      %{"id" => "TASK-3001", "title" => "Refine planner prompt formatting", "priority" => 1},
      %{"id" => "TASK-3002", "title" => "Add regression test around event parser", "priority" => 2},
      %{"id" => "TASK-3003", "title" => "Draft release notes for sprint output", "priority" => 3},
      %{"id" => "TASK-3004", "title" => "Clean up stale scenario docs links", "priority" => 4}
    ]
  end
end
