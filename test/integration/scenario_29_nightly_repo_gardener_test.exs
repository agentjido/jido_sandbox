defmodule Jido.Workspace.Integration.Scenario29NightlyRepoGardenerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 29 goal: Scheduled maintenance run that applies low-risk fixes and opens maintenance PRs.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @policy_path "/artifacts/policy_config.json"
  @dashboard_path "/artifacts/nightly_dashboard.json"
  @notifications_path "/artifacts/notifications_payload.json"
  @error_path "/artifacts/errors.json"

  test "nightly repo gardener emits deterministic per-repo statuses and notifications", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("29_nightly_repo_gardener", "spec-29", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    repo_inventory = repo_inventory()
    policy_config = policy_config()

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts/repos")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @policy_path, policy_config)
      ScenarioHelpers.put_workspace(workspace)

      {workspace, repo_results} =
        Enum.reduce(repo_inventory, {workspace, []}, fn repo, {acc_workspace, acc_results} ->
          {:ok, snapshot_id, acc_workspace} = Workspace.snapshot(acc_workspace)
          ScenarioHelpers.put_workspace(acc_workspace)

          result = run_repo_maintenance(repo, snapshot_id)
          repo_id = repo["id"]
          repo_artifact_path = "/artifacts/repos/#{repo_id}.json"

          {:ok, next_workspace} =
            HarnessScenarioHelpers.write_json_artifact(acc_workspace, repo_artifact_path, result)

          ScenarioHelpers.put_workspace(next_workspace)
          {next_workspace, acc_results ++ [result]}
        end)

      dashboard = %{
        "run_id" => "nightly-#{System.unique_integer([:positive])}",
        "repo_count" => length(repo_inventory),
        "statuses" => Enum.frequencies_by(repo_results, & &1["status"]),
        "repos" => repo_results,
        "silent_failure_count" => Enum.count(repo_results, &is_nil(&1["status"]))
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @dashboard_path, dashboard)
      ScenarioHelpers.put_workspace(workspace)

      opened_prs = repo_results |> Enum.map(& &1["pr_url"]) |> Enum.reject(&is_nil/1)

      notifications = %{
        "channel" => "nightly-maintenance",
        "repo_count" => length(repo_inventory),
        "opened_pr_count" => length(opened_prs),
        "opened_prs" => opened_prs,
        "deferred_repos" =>
          repo_results
          |> Enum.filter(&String.starts_with?(&1["status"], "deferred"))
          |> Enum.map(& &1["id"])
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @notifications_path, notifications)
      ScenarioHelpers.put_workspace(workspace)

      status =
        if dashboard["silent_failure_count"] == 0 and length(repo_results) == length(repo_inventory),
          do: "ok",
          else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "29_nightly_repo_gardener",
          status,
          workspace_id,
          [
            {"repo_count", length(repo_inventory)},
            {"opened_pr_count", length(opened_prs)},
            {"deferred_count", length(notifications["deferred_repos"])},
            {"silent_failure_count", dashboard["silent_failure_count"]}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      dashboard_file = Path.join(output_root, "artifacts/nightly_dashboard.json")
      notifications_file = Path.join(output_root, "artifacts/notifications_payload.json")
      repo_alpha_file = Path.join(output_root, "artifacts/repos/repo-alpha.json")

      assert File.exists?(summary_file)
      assert File.exists?(dashboard_file)
      assert File.exists?(notifications_file)
      assert File.exists?(repo_alpha_file)

      assert {:ok, dashboard_contents} = File.read(dashboard_file)
      assert String.contains?(dashboard_contents, "\"statuses\"")
      assert String.contains?(dashboard_contents, "\"repo-alpha\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_repo_maintenance(%{"id" => "repo-alpha"} = repo, snapshot_id) do
    %{
      "id" => repo["id"],
      "status" => "pr_opened",
      "snapshot_id" => snapshot_id,
      "changes" => ["lint autofix", "docs heading normalization"],
      "validation" => "passed",
      "pr_url" => "https://example.local/repo-alpha/pull/101",
      "reverted" => false
    }
  end

  defp run_repo_maintenance(%{"id" => "repo-beta"} = repo, snapshot_id) do
    %{
      "id" => repo["id"],
      "status" => "deferred_policy",
      "snapshot_id" => snapshot_id,
      "changes" => [],
      "validation" => "not_run",
      "pr_url" => nil,
      "reverted" => true,
      "reason" => "policy violation: high-risk dependency bump blocked"
    }
  end

  defp run_repo_maintenance(%{"id" => "repo-gamma"} = repo, snapshot_id) do
    %{
      "id" => repo["id"],
      "status" => "deferred_validation",
      "snapshot_id" => snapshot_id,
      "changes" => ["format rewrite"],
      "validation" => "failed",
      "pr_url" => nil,
      "reverted" => true,
      "reason" => "quality check failed after autofix"
    }
  end

  defp repo_inventory do
    [
      %{"id" => "repo-alpha", "tier" => "low-risk"},
      %{"id" => "repo-beta", "tier" => "policy-sensitive"},
      %{"id" => "repo-gamma", "tier" => "low-risk"}
    ]
  end

  defp policy_config do
    %{
      "allow" => ["lint", "docs", "format"],
      "block" => ["major_dependency_upgrade", "security_sensitive_config"],
      "max_files_changed" => 20
    }
  end
end
