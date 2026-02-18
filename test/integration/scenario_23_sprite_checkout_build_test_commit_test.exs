defmodule Jido.Workspace.Integration.Scenario23SpriteCheckoutBuildTestCommitTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 23 goal: Run full remote repo workflow to checkout code, build, test, and local commit on Sprite.
  """

  alias Jido.Shell.Backend.Sprite
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @steps_path "/artifacts/workflow_steps.json"
  @git_status_path "/artifacts/git_status.txt"
  @test_log_path "/artifacts/test_log.txt"
  @git_log_path "/artifacts/git_log.txt"
  @diagnostics_path "/artifacts/startup_diagnostics.json"
  @error_path "/artifacts/errors.json"

  test "sprite checkout build test commit workflow emits deterministic artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("23_sprite_checkout_build_test_commit", "spec-23", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    started_at = System.monotonic_time(:millisecond)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      sprite_config = sprite_backend_config("23")
      {status, summary_fields, workspace} = run_workflow(workspace, sprite_config, started_at)

      assert status == "ok",
             "expected live sprite execution, got status=#{status} fields=#{inspect(summary_fields)}"

      summary_json =
        ScenarioHelpers.summary_json(
          "23_sprite_checkout_build_test_commit",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      steps_file = Path.join(output_root, "artifacts/workflow_steps.json")
      git_status_file = Path.join(output_root, "artifacts/git_status.txt")
      test_log_file = Path.join(output_root, "artifacts/test_log.txt")
      git_log_file = Path.join(output_root, "artifacts/git_log.txt")
      diagnostics_file = Path.join(output_root, "artifacts/startup_diagnostics.json")

      assert File.exists?(summary_file)
      assert File.exists?(steps_file)
      assert File.exists?(git_status_file)
      assert File.exists?(test_log_file)
      assert File.exists?(git_log_file)
      assert File.exists?(diagnostics_file)

      assert {:ok, steps_contents} = File.read(steps_file)
      assert String.contains?(steps_contents, "\"init_repo\"")
      assert String.contains?(steps_contents, "\"build\"")
      assert String.contains?(steps_contents, "\"test\"")
      assert String.contains?(steps_contents, "\"apply_patch\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_workflow(workspace, {:error, reason, diagnostics}, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    {:ok, workspace} = Workspace.write(workspace, @git_status_path, "")
    {:ok, workspace} = Workspace.write(workspace, @test_log_path, "")
    {:ok, workspace} = Workspace.write(workspace, @git_log_path, "")

    {:ok, workspace} =
      HarnessScenarioHelpers.write_json_artifact(workspace, @steps_path, %{
        "status" => "setup_required",
        "reason" => reason,
        "steps" => []
      })

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", reason}, {"elapsed_ms", elapsed_ms}], workspace}
  end

  defp run_workflow(workspace, {:ok, backend_config, diagnostics}, started_at) do
    case Workspace.start_session(workspace, backend: {Sprite, backend_config}, cwd: "/") do
      {:ok, workspace} ->
        ScenarioHelpers.put_workspace(workspace)

        script_steps = [
          {"init_repo", "rm -rf /tmp/spec23 && mkdir -p /tmp/spec23/repo && cd /tmp/spec23/repo && git init ."},
          {"git_config",
           "cd /tmp/spec23/repo && git config user.email 'spec23@example.com' && git config user.name 'Spec 23 Bot'"},
          {"seed_baseline",
           "cd /tmp/spec23/repo && printf '# Spec23\\n' > README.md && git add README.md && git commit -m 'chore: baseline'"},
          {"checkout_branch", "cd /tmp/spec23/repo && git checkout -b spec23/workflow"},
          {"build", "cd /tmp/spec23/repo && sh -lc 'test -f README.md && echo BUILD_OK'"},
          {"test", "cd /tmp/spec23/repo && sh -lc 'grep -q Spec23 README.md && echo TEST_OK'"},
          {"apply_patch",
           "cd /tmp/spec23/repo && printf '\\nupdated\\n' >> README.md && git add README.md && git commit -m 'feat: scripted update'"},
          {"git_status", "cd /tmp/spec23/repo && git status --short"},
          {"git_log", "cd /tmp/spec23/repo && git log --oneline -n 3"}
        ]

        {workspace, step_results} =
          Enum.reduce(script_steps, {workspace, []}, fn {name, command}, {acc_workspace, acc_results} ->
            {next_workspace, result} = run_command(acc_workspace, command)
            {next_workspace, acc_results ++ [Map.put(result, "step", name)]}
          end)

        git_status_output =
          step_results
          |> Enum.find(&(&1["step"] == "git_status"))
          |> Map.get("output", "")

        test_output =
          step_results
          |> Enum.filter(&(&1["step"] in ["build", "test"]))
          |> Enum.map_join("\n", &"#{&1["step"]}: #{&1["status"]} #{&1["output"]}")

        git_log_output =
          step_results
          |> Enum.find(&(&1["step"] == "git_log"))
          |> Map.get("output", "")

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        build_ok? = step_ok?(step_results, "build")
        test_ok? = step_ok?(step_results, "test")
        commit_ok? = step_ok?(step_results, "apply_patch")
        status = if build_ok? and test_ok? and commit_ok?, do: "ok", else: "setup_required"

        {:ok, workspace} = Workspace.write(workspace, @git_status_path, git_status_output)
        {:ok, workspace} = Workspace.write(workspace, @test_log_path, test_output)
        {:ok, workspace} = Workspace.write(workspace, @git_log_path, git_log_output)

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(workspace, @steps_path, %{"steps" => step_results})

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        {:ok, workspace} = Workspace.stop_session(workspace)
        ScenarioHelpers.put_workspace(workspace)

        {status,
         [
           {"sprite_name", Map.get(backend_config, :sprite_name)},
           {"elapsed_ms", elapsed_ms},
           {"build_ok", build_ok?},
           {"test_ok", test_ok?},
           {"commit_ok", commit_ok?}
         ], workspace}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        {:ok, workspace} = Workspace.write(workspace, @git_status_path, "")
        {:ok, workspace} = Workspace.write(workspace, @test_log_path, "")
        {:ok, workspace} = Workspace.write(workspace, @git_log_path, "")

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(workspace, @steps_path, %{
            "status" => "setup_required",
            "reason" => "sprite_start_failed",
            "error" => inspect(reason),
            "steps" => []
          })

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(
            workspace,
            @diagnostics_path,
            Map.put(diagnostics, "start_error", inspect(reason))
          )

        ScenarioHelpers.put_workspace(workspace)

        {"setup_required", [{"reason", "sprite_start_failed"}, {"elapsed_ms", elapsed_ms}], workspace}
    end
  end

  defp run_command(workspace, command) do
    case Workspace.run(workspace, command) do
      {:ok, output, updated_workspace} ->
        ScenarioHelpers.put_workspace(updated_workspace)
        {updated_workspace, %{"status" => "ok", "output" => String.trim(output), "error" => nil}}

      {:error, reason, updated_workspace} ->
        ScenarioHelpers.put_workspace(updated_workspace)
        {updated_workspace, %{"status" => "error", "output" => "", "error" => inspect(reason)}}
    end
  end

  defp step_ok?(results, name) do
    results
    |> Enum.find(&(&1["step"] == name))
    |> case do
      nil -> false
      result -> result["status"] == "ok"
    end
  end

  defp sprite_backend_config(spec_suffix) do
    token = System.get_env("SPRITES_TOKEN")
    sprite_name_env = System.get_env("JIDO_WORKSPACE_SPEC_#{spec_suffix}_SPRITE_NAME")
    base_url = System.get_env("SPRITES_BASE_URL")

    diagnostics = %{
      "token" => if(is_binary(token) and token != "", do: "set", else: "unset"),
      "sprite_name" => sprite_name_env || "(generated)",
      "base_url" => if(is_binary(base_url) and base_url != "", do: "set", else: "unset")
    }

    if is_binary(token) and String.trim(token) != "" do
      sprite_name =
        if is_binary(sprite_name_env) and String.trim(sprite_name_env) != "" do
          String.trim(sprite_name_env)
        else
          "jido-workspace-spec#{spec_suffix}-#{System.unique_integer([:positive])}"
        end

      backend_config =
        %{
          token: String.trim(token),
          sprite_name: sprite_name,
          create: true
        }
        |> maybe_put_base_url(base_url)

      {:ok, backend_config, Map.put(diagnostics, "resolved_sprite_name", sprite_name)}
    else
      {:error, "missing_sprite_token", Map.put(diagnostics, "status", "setup_required")}
    end
  end

  defp maybe_put_base_url(config, base_url) do
    if is_binary(base_url) and String.trim(base_url) != "" do
      Map.put(config, :base_url, String.trim(base_url))
    else
      config
    end
  end
end
