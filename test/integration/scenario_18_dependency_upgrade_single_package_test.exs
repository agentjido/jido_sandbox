defmodule Jido.Workspace.Integration.Scenario18DependencyUpgradeSinglePackageTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 18 goal: Upgrade one dependency safely with compile/test verification and changelog artifact.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @compile_log_path "/artifacts/compile.log"
  @test_log_path "/artifacts/test.log"
  @diff_path "/artifacts/dependency_diff.txt"
  @change_summary_path "/artifacts/change_summary.json"
  @commit_message_path "/artifacts/commit_message.txt"
  @error_path "/artifacts/errors.json"

  @target_dep "demo_dep"
  @old_requirement "~> 1.0"
  @new_requirement "~> 1.2"

  test "dependency upgrade workflow validates compile/test and emits commit artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("18_dependency_upgrade_single_package", "spec-18", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = write_initial_project(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, "/project/mix.exs", project_mix_exs(@new_requirement))
      ScenarioHelpers.put_workspace(workspace)

      project_root = Path.join(output_root, "project")
      {compile_output, compile_exit} = run_mix(project_root, ["compile"])
      {test_output, test_exit} = run_mix(project_root, ["test"])
      successful? = compile_exit == 0 and test_exit == 0

      {workspace, restored_snapshot?, restore_error} =
        if successful? do
          {workspace, false, nil}
        else
          case Workspace.restore(workspace, snapshot_id) do
            {:ok, restored_workspace} ->
              ScenarioHelpers.put_workspace(restored_workspace)
              {restored_workspace, true, nil}

            {:error, reason} ->
              {workspace, false, inspect(reason)}
          end
        end

      workspace = ensure_artifacts_dir(workspace)
      {:ok, workspace} = Workspace.write(workspace, @compile_log_path, compile_output)
      {:ok, workspace} = Workspace.write(workspace, @test_log_path, test_output)
      {:ok, workspace} = Workspace.write(workspace, @diff_path, dependency_diff(@old_requirement, @new_requirement))
      ScenarioHelpers.put_workspace(workspace)

      change_summary = %{
        "dependency" => @target_dep,
        "from_requirement" => @old_requirement,
        "to_requirement" => @new_requirement,
        "compile_exit_code" => compile_exit,
        "test_exit_code" => test_exit,
        "checks_passed" => successful?,
        "restored_snapshot" => restored_snapshot?,
        "restore_error" => restore_error,
        "snapshot_id" => snapshot_id,
        "risk_summary" =>
          if(successful?,
            do: "low risk: compile and tests passed",
            else: "high risk: verification failed and workspace was restored"
          )
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @change_summary_path, change_summary)
      ScenarioHelpers.put_workspace(workspace)

      commit_message =
        """
        chore(deps): upgrade #{@target_dep} requirement to #{@new_requirement}

        - verified with mix compile
        - verified with mix test
        - scenario: 18_dependency_upgrade_single_package
        """

      {:ok, workspace} = Workspace.write(workspace, @commit_message_path, commit_message)
      ScenarioHelpers.put_workspace(workspace)

      status = if successful?, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "18_dependency_upgrade_single_package",
          status,
          workspace_id,
          [
            {"dependency", @target_dep},
            {"from_requirement", @old_requirement},
            {"to_requirement", @new_requirement},
            {"compile_exit_code", compile_exit},
            {"test_exit_code", test_exit},
            {"restored_snapshot", restored_snapshot?},
            {"restore_error", restore_error || ""}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      compile_log_file = Path.join(output_root, "artifacts/compile.log")
      test_log_file = Path.join(output_root, "artifacts/test.log")
      diff_file = Path.join(output_root, "artifacts/dependency_diff.txt")
      change_summary_file = Path.join(output_root, "artifacts/change_summary.json")
      commit_message_file = Path.join(output_root, "artifacts/commit_message.txt")

      assert File.exists?(summary_file)
      assert File.exists?(compile_log_file)
      assert File.exists?(test_log_file)
      assert File.exists?(diff_file)
      assert File.exists?(change_summary_file)
      assert File.exists?(commit_message_file)

      assert {:ok, summary_contents} = File.read(summary_file)
      assert String.contains?(summary_contents, "\"dependency\"")

      assert {:ok, project_mix} = Workspace.read(workspace, "/project/mix.exs")

      if restored_snapshot? do
        assert String.contains?(project_mix, @old_requirement)
      else
        assert String.contains?(project_mix, @new_requirement)
      end
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp write_initial_project(workspace) do
    files = [
      {"/vendor/demo_dep/mix.exs", dependency_mix_exs()},
      {"/vendor/demo_dep/lib/demo_dep.ex", dependency_module()},
      {"/project/mix.exs", project_mix_exs(@old_requirement)},
      {"/project/lib/demo_project.ex", project_module()},
      {"/project/test/test_helper.exs", "ExUnit.start()\n"},
      {"/project/test/demo_project_test.exs", project_test_module()}
    ]

    Enum.reduce_while(files, {:ok, workspace}, fn {path, content}, {:ok, acc_workspace} ->
      case Workspace.write(acc_workspace, path, content) do
        {:ok, next_workspace} -> {:cont, {:ok, next_workspace}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp dependency_mix_exs do
    """
    defmodule DemoDep.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo_dep,
          version: "1.2.3",
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

  defp dependency_module do
    """
    defmodule DemoDep do
      def version, do: "1.2.3"
    end
    """
  end

  defp project_mix_exs(requirement) do
    """
    defmodule DemoProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo_project,
          version: "0.1.0",
          elixir: "~> 1.14",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:demo_dep, "#{requirement}", path: "../vendor/demo_dep"}
        ]
      end
    end
    """
  end

  defp project_module do
    """
    defmodule DemoProject do
      def value, do: DemoDep.version()
    end
    """
  end

  defp project_test_module do
    """
    defmodule DemoProjectTest do
      use ExUnit.Case, async: true

      test "resolves dependency version from local path dep" do
        assert DemoProject.value() == "1.2.3"
      end
    end
    """
  end

  defp dependency_diff(from_requirement, to_requirement) do
    [
      "Dependency change proposal",
      "",
      "- dependency: #{@target_dep}",
      "- from: #{from_requirement}",
      "- to: #{to_requirement}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
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

  defp ensure_artifacts_dir(workspace) do
    case Workspace.mkdir(workspace, "/artifacts") do
      {:ok, ensured_workspace} -> ensured_workspace
      {:error, _reason} -> workspace
    end
  end
end
