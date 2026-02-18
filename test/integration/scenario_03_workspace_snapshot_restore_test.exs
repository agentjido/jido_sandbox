defmodule Jido.Workspace.Integration.Scenario03WorkspaceSnapshotRestoreTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 03 goal: Show deterministic rollback using snapshot/restore around file mutations.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @error_path "/artifacts/errors.json"

  test "workspace snapshot and restore reverts destructive mutations", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("03_workspace_snapshot_restore", "spec-03", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.write(workspace, "/original.txt", "original")
      {:ok, workspace} = Workspace.write(workspace, "/anchor.txt", "A")
      ScenarioHelpers.put_workspace(workspace)

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.delete(workspace, "/original.txt")
      {:ok, workspace} = Workspace.write(workspace, "/new.txt", "new")
      {:ok, workspace} = Workspace.write(workspace, "/anchor.txt", "MUTATED")
      ScenarioHelpers.put_workspace(workspace)

      assert {:error, :file_not_found} = Workspace.read(workspace, "/original.txt")
      assert {:ok, "new"} = Workspace.read(workspace, "/new.txt")
      assert {:ok, "MUTATED"} = Workspace.read(workspace, "/anchor.txt")

      {:ok, workspace} = Workspace.restore(workspace, snapshot_id)
      ScenarioHelpers.put_workspace(workspace)

      assert {:ok, "original"} = Workspace.read(workspace, "/original.txt")
      assert {:ok, "A"} = Workspace.read(workspace, "/anchor.txt")
      assert {:error, :file_not_found} = Workspace.read(workspace, "/new.txt")

      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.write(workspace, "/artifacts/snapshot_id.txt", snapshot_id)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "03_workspace_snapshot_restore",
          "ok",
          workspace_id,
          [
            {"snapshot_id", snapshot_id},
            {"restored_original", true},
            {"removed_new_file", true}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      snapshot_file = Path.join(output_root, "artifacts/snapshot_id.txt")

      assert File.exists?(summary_file)
      assert File.exists?(snapshot_file)

      assert {:ok, snapshot_recorded} = File.read(snapshot_file)
      assert String.trim(snapshot_recorded) == snapshot_id
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end
end
