defmodule Jido.Workspace.Integration.Scenario14DocsDriftCorrectorTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 14 goal: Detect and fix docs drift by comparing exported APIs to docs files and patching artifacts.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @drift_before_path "/artifacts/drift_report_before.json"
  @drift_after_path "/artifacts/drift_report_after.json"
  @patch_summary_path "/artifacts/docs_patch_summary.json"
  @validation_path "/artifacts/docs_validation.txt"
  @docs_path "/docs/README.md"
  @error_path "/artifacts/errors.json"

  test "docs drift workflow detects mismatches and applies correction patch", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("14_docs_drift_corrector", "spec-14", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/docs")
      ScenarioHelpers.put_workspace(workspace)

      module_inventory = module_inventory()

      initial_docs = "# Workspace Docs\n\n## Exported Modules\n\n- #{List.first(module_inventory)}\n"
      {:ok, workspace} = Workspace.write(workspace, @docs_path, initial_docs)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, before_docs} = Workspace.read(workspace, @docs_path)
      missing_before = missing_modules(module_inventory, before_docs)

      before_report = %{
        "critical_mismatches" => length(missing_before),
        "missing_modules" => missing_before,
        "module_inventory" => module_inventory
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @drift_before_path, before_report)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, @docs_path, corrected_docs(before_docs, missing_before))
      ScenarioHelpers.put_workspace(workspace)

      {:ok, after_docs} = Workspace.read(workspace, @docs_path)
      missing_after = missing_modules(module_inventory, after_docs)

      {workspace, restored?} =
        if missing_after == [] do
          {workspace, false}
        else
          {:ok, restored_workspace} = Workspace.restore(workspace, snapshot_id)
          ScenarioHelpers.put_workspace(restored_workspace)
          {restored_workspace, true}
        end

      after_report = %{
        "critical_mismatches" => length(missing_after),
        "missing_modules" => missing_after,
        "restored_snapshot" => restored?
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @drift_after_path, after_report)
      ScenarioHelpers.put_workspace(workspace)

      patch_summary = %{
        "snapshot_id" => snapshot_id,
        "modules_added" => missing_before,
        "restored_snapshot" => restored?,
        "critical_mismatches_before" => length(missing_before),
        "critical_mismatches_after" => length(missing_after)
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @patch_summary_path, patch_summary)
      ScenarioHelpers.put_workspace(workspace)

      validation_text =
        if missing_after == [] do
          "docs validation succeeded: zero critical mismatches"
        else
          "docs validation failed: unresolved modules #{Enum.join(missing_after, ", ")}"
        end

      {:ok, workspace} = Workspace.write(workspace, @validation_path, validation_text)
      ScenarioHelpers.put_workspace(workspace)

      status = if missing_after == [], do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "14_docs_drift_corrector",
          status,
          workspace_id,
          [
            {"critical_mismatches_before", length(missing_before)},
            {"critical_mismatches_after", length(missing_after)},
            {"restored_snapshot", restored?}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      before_file = Path.join(output_root, "artifacts/drift_report_before.json")
      after_file = Path.join(output_root, "artifacts/drift_report_after.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(before_file)
      assert File.exists?(after_file)
      assert File.exists?(summary_file)

      assert {:ok, after_contents} = File.read(after_file)
      assert String.contains?(after_contents, "\"critical_mismatches\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp module_inventory do
    lib_root = Path.expand("../../lib", __DIR__)

    lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> then(&Regex.scan(~r/defmodule\s+([A-Za-z0-9_.]+)/, &1, capture: :all_but_first))
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(8)
  end

  defp missing_modules(module_inventory, docs_text) do
    Enum.reject(module_inventory, &String.contains?(docs_text, &1))
  end

  defp corrected_docs(existing, []), do: existing

  defp corrected_docs(existing, missing_modules) do
    additions =
      missing_modules
      |> Enum.map_join("\n", fn module -> "- #{module}" end)

    existing <> "\n### Added By Drift Corrector\n" <> additions <> "\n"
  end
end
