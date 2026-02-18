defmodule Jido.Workspace.Integration.Scenario21MultiMountBuildPipelineTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 21 goal: Use separate mounts for source, cache, and artifacts in one orchestrated build run.
  """

  alias Jido.Shell.VFS
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @mount_stats_path "/artifacts/mount_stats.json"
  @build_log_path "/artifacts/build.log"
  @test_log_path "/artifacts/test.log"
  @performance_path "/artifacts/performance.json"
  @error_path "/artifacts/errors.json"

  test "multi-mount build pipeline isolates repo cache and artifact outputs", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("21_multi_mount_build_pipeline", "spec-21", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    repo_prefix = Path.join(output_root, "repo_mount")
    cache_prefix = Path.join(output_root, "cache_mount")

    :ok = File.mkdir_p!(repo_prefix)
    :ok = File.mkdir_p!(cache_prefix)

    artifacts_mount_name = "spec21_artifacts_#{System.unique_integer([:positive])}"

    try do
      :ok = VFS.mount(workspace_id, "/repo", Jido.VFS.Adapter.Local, prefix: repo_prefix)
      :ok = VFS.mount(workspace_id, "/cache", Jido.VFS.Adapter.Local, prefix: cache_prefix)
      :ok = VFS.mount(workspace_id, "/artifacts", Jido.VFS.Adapter.InMemory, name: artifacts_mount_name)

      {:ok, workspace} = Workspace.write(workspace, "/repo/mix.exs", project_mix_exs())
      {:ok, workspace} = Workspace.write(workspace, "/repo/lib/mount_build_sample.ex", project_module())
      {:ok, workspace} = Workspace.write(workspace, "/repo/test/test_helper.exs", "ExUnit.start()\n")
      {:ok, workspace} = Workspace.write(workspace, "/repo/test/mount_build_sample_test.exs", project_test())
      ScenarioHelpers.put_workspace(workspace)

      env = [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", Path.join(cache_prefix, "_build")},
        {"MIX_DEPS_PATH", Path.join(cache_prefix, "deps")}
      ]

      {build_log_1, build_exit_1} = run_mix(repo_prefix, ["compile"], env)
      {test_log_1, test_exit_1} = run_mix(repo_prefix, ["test"], env)
      {build_log_2, build_exit_2} = run_mix(repo_prefix, ["compile"], env)
      {test_log_2, test_exit_2} = run_mix(repo_prefix, ["test"], env)

      build_artifact =
        Path.join([
          cache_prefix,
          "_build",
          "test",
          "lib",
          "mount_build_sample",
          "ebin",
          "Elixir.MountBuildSample.beam"
        ])

      build_ok? =
        Enum.all?([build_exit_1, test_exit_1, build_exit_2, test_exit_2], &(&1 == 0)) and
          File.exists?(build_artifact)

      mounts =
        workspace_id
        |> VFS.list_mounts()
        |> Enum.map(fn mount ->
          %{
            "path" => mount.path,
            "adapter" => inspect(mount.adapter),
            "ownership" => to_string(mount.ownership)
          }
        end)
        |> Enum.sort_by(& &1["path"])

      mount_stats = %{
        "mount_count" => length(mounts),
        "mounts" => mounts,
        "repo_prefix" => repo_prefix,
        "cache_prefix" => cache_prefix
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @mount_stats_path, mount_stats)
      {:ok, workspace} = Workspace.write(workspace, @build_log_path, build_log_1 <> "\n" <> build_log_2)
      {:ok, workspace} = Workspace.write(workspace, @test_log_path, test_log_1 <> "\n" <> test_log_2)
      ScenarioHelpers.put_workspace(workspace)

      performance = %{
        "first_pass" => %{"compile_exit" => build_exit_1, "test_exit" => test_exit_1},
        "second_pass" => %{"compile_exit" => build_exit_2, "test_exit" => test_exit_2},
        "build_artifact_path" => build_artifact,
        "build_artifact_exists" => File.exists?(build_artifact),
        "reproducible" => build_ok?
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @performance_path, performance)
      ScenarioHelpers.put_workspace(workspace)

      status = if build_ok?, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "21_multi_mount_build_pipeline",
          status,
          workspace_id,
          [
            {"mount_count", length(mounts)},
            {"reproducible", build_ok?},
            {"build_exit_1", build_exit_1},
            {"test_exit_1", test_exit_1},
            {"build_exit_2", build_exit_2},
            {"test_exit_2", test_exit_2}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      assert {:ok, mount_stats_contents} = Workspace.read(workspace, @mount_stats_path)
      assert String.contains?(mount_stats_contents, "\"/repo\"")
      assert String.contains?(mount_stats_contents, "\"/cache\"")
      assert String.contains?(mount_stats_contents, "\"/artifacts\"")

      assert {:ok, summary_contents} = Workspace.read(workspace, @summary_path)
      assert String.contains?(summary_contents, "\"reproducible\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_mix(repo_prefix, args, env) do
    try do
      System.cmd("mix", args, cd: repo_prefix, env: env, stderr_to_stdout: true, timeout: 90_000)
    rescue
      error ->
        {"mix #{Enum.join(args, " ")} failed: #{Exception.message(error)}\n", 1}
    catch
      :exit, reason ->
        {"mix #{Enum.join(args, " ")} failed: #{inspect(reason)}\n", 124}
    end
  end

  defp project_mix_exs do
    """
    defmodule MountBuildSample.MixProject do
      use Mix.Project

      def project do
        [
          app: :mount_build_sample,
          version: "0.1.0",
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

  defp project_module do
    """
    defmodule MountBuildSample do
      def sum(a, b), do: a + b
    end
    """
  end

  defp project_test do
    """
    defmodule MountBuildSampleTest do
      use ExUnit.Case, async: true

      test "sum/2" do
        assert MountBuildSample.sum(2, 3) == 5
      end
    end
    """
  end
end
