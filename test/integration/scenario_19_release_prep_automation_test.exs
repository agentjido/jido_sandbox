defmodule Jido.Workspace.Integration.Scenario19ReleasePrepAutomationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 19 goal: Prepare version bump, changelog draft, and release checklist artifacts.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @version_update_path "/artifacts/version_update.json"
  @changelog_draft_path "/artifacts/changelog_draft.md"
  @quality_output_path "/artifacts/quality_output.txt"
  @release_checklist_path "/artifacts/release_checklist.json"
  @tag_notes_path "/artifacts/tag_notes.md"
  @error_path "/artifacts/errors.json"

  @project_mix_path "/project/mix.exs"
  @project_changelog_path "/project/CHANGELOG.md"

  @current_version "0.4.2"
  @release_version "0.5.0"

  test "release prep updates version/changelog and emits readiness checklist", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("19_release_prep_automation", "spec-19", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = write_release_project(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, current_mix} = Workspace.read(workspace, @project_mix_path)
      {:ok, current_changelog} = Workspace.read(workspace, @project_changelog_path)

      detected_current_version = extract_version(current_mix)
      release_date = Date.utc_today() |> Date.to_iso8601()
      updated_mix = String.replace(current_mix, "version: \"#{@current_version}\"", "version: \"#{@release_version}\"")
      updated_changelog = inject_release_entry(current_changelog, @release_version, release_date)

      {:ok, workspace} = Workspace.write(workspace, @project_mix_path, updated_mix)
      {:ok, workspace} = Workspace.write(workspace, @project_changelog_path, updated_changelog)
      ScenarioHelpers.put_workspace(workspace)

      project_root = Path.join(output_root, "project")
      quality_command = "mix test"
      {quality_output, quality_exit} = run_mix(project_root, ["test"])

      {:ok, workspace} = Workspace.write(workspace, @quality_output_path, quality_output)
      {:ok, workspace} = Workspace.write(workspace, @changelog_draft_path, updated_changelog)
      ScenarioHelpers.put_workspace(workspace)

      release_ready = quality_exit == 0
      blockers = if release_ready, do: [], else: ["quality command failed: #{quality_command}"]

      version_update = %{
        "snapshot_id" => snapshot_id,
        "from_version" => detected_current_version,
        "to_version" => @release_version,
        "release_date" => release_date,
        "quality_command" => quality_command,
        "quality_exit_code" => quality_exit
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @version_update_path, version_update)
      ScenarioHelpers.put_workspace(workspace)

      checklist = %{
        "release_ready" => release_ready,
        "blockers" => blockers,
        "checks" => [
          %{"name" => "version bumped", "passed" => detected_current_version != @release_version},
          %{"name" => "changelog drafted", "passed" => true},
          %{"name" => "quality command", "passed" => release_ready}
        ]
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @release_checklist_path, checklist)
      ScenarioHelpers.put_workspace(workspace)

      tag_notes = """
      # Release Candidate

      - tag: v#{@release_version}
      - from_version: #{detected_current_version}
      - release_date: #{release_date}
      - quality_command: #{quality_command}
      - quality_exit_code: #{quality_exit}

      ## Notes
      - Automated by scenario 19 release prep workflow.
      """

      {:ok, workspace} = Workspace.write(workspace, @tag_notes_path, tag_notes)
      ScenarioHelpers.put_workspace(workspace)

      status = if release_ready, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "19_release_prep_automation",
          status,
          workspace_id,
          [
            {"from_version", detected_current_version},
            {"to_version", @release_version},
            {"quality_exit_code", quality_exit},
            {"release_ready", release_ready},
            {"blocker_count", length(blockers)}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      version_update_file = Path.join(output_root, "artifacts/version_update.json")
      changelog_draft_file = Path.join(output_root, "artifacts/changelog_draft.md")
      quality_output_file = Path.join(output_root, "artifacts/quality_output.txt")
      checklist_file = Path.join(output_root, "artifacts/release_checklist.json")
      tag_notes_file = Path.join(output_root, "artifacts/tag_notes.md")

      assert File.exists?(summary_file)
      assert File.exists?(version_update_file)
      assert File.exists?(changelog_draft_file)
      assert File.exists?(quality_output_file)
      assert File.exists?(checklist_file)
      assert File.exists?(tag_notes_file)

      assert {:ok, mix_after} = Workspace.read(workspace, @project_mix_path)
      assert String.contains?(mix_after, "version: \"#{@release_version}\"")

      assert {:ok, changelog_after} = Workspace.read(workspace, @project_changelog_path)
      assert String.contains?(changelog_after, "## [#{@release_version}] - #{release_date}")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp write_release_project(workspace) do
    files = [
      {@project_mix_path, release_mix_exs(@current_version)},
      {@project_changelog_path, base_changelog()},
      {"/project/lib/release_sample.ex", release_module()},
      {"/project/test/test_helper.exs", "ExUnit.start()\n"},
      {"/project/test/release_sample_test.exs", release_module_test()}
    ]

    Enum.reduce_while(files, {:ok, workspace}, fn {path, content}, {:ok, acc_workspace} ->
      case Workspace.write(acc_workspace, path, content) do
        {:ok, next_workspace} -> {:cont, {:ok, next_workspace}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp release_mix_exs(version) do
    """
    defmodule ReleaseSample.MixProject do
      use Mix.Project

      def project do
        [
          app: :release_sample,
          version: "#{version}",
          elixir: "~> 1.14",
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """
  end

  defp base_changelog do
    """
    # Changelog

    All notable changes to this project are documented in this file.

    ## [Unreleased]
    - Add release prep automation scenario scaffolding.

    ## [0.4.2] - 2026-01-15
    - Previous stable release entry.
    """
  end

  defp release_module do
    """
    defmodule ReleaseSample do
      def ok?, do: true
    end
    """
  end

  defp release_module_test do
    """
    defmodule ReleaseSampleTest do
      use ExUnit.Case, async: true

      test "sanity" do
        assert ReleaseSample.ok?()
      end
    end
    """
  end

  defp extract_version(mix_content) when is_binary(mix_content) do
    case Regex.run(~r/version:\s*"([^"]+)"/, mix_content, capture: :all_but_first) do
      [version] -> version
      _ -> @current_version
    end
  end

  defp inject_release_entry(changelog, version, release_date) do
    release_entry = """
    ## [#{version}] - #{release_date}
    - Bump package version and prepare release notes.
    - Verify quality checks before tagging.

    """

    String.replace(changelog, "## [Unreleased]\n", "## [Unreleased]\n- (no unreleased items)\n\n#{release_entry}")
  end

  defp run_mix(project_root, args) do
    try do
      System.cmd("mix", args, cd: project_root, stderr_to_stdout: true, timeout: 90_000)
    rescue
      error ->
        {"mix #{Enum.join(args, " ")} failed: #{Exception.message(error)}\n", 1}
    catch
      :exit, reason ->
        {"mix #{Enum.join(args, " ")} failed: #{inspect(reason)}\n", 124}
    end
  end
end
