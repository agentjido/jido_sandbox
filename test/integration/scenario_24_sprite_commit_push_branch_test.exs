defmodule Jido.Workspace.Integration.Scenario24SpriteCommitPushBranchTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 24 goal: Extend remote workflow to push commit to remote branch safely.
  """

  alias Jido.Shell.Backend.Sprite
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @push_result_path "/artifacts/push_result.json"
  @remote_ref_path "/artifacts/remote_ref.txt"
  @pr_hint_path "/artifacts/pr_url_hint.md"
  @diagnostics_path "/artifacts/startup_diagnostics.json"
  @error_path "/artifacts/errors.json"

  test "sprite commit and push workflow captures remote ref and push classification", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("24_sprite_commit_push_branch", "spec-24", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    started_at = System.monotonic_time(:millisecond)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      sprite_config = sprite_backend_config("24")
      {status, summary_fields, workspace} = run_push_flow(workspace, sprite_config, started_at)

      assert status == "ok",
             "expected live sprite execution, got status=#{status} fields=#{inspect(summary_fields)}"

      summary_json =
        ScenarioHelpers.summary_json(
          "24_sprite_commit_push_branch",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      push_result_file = Path.join(output_root, "artifacts/push_result.json")
      remote_ref_file = Path.join(output_root, "artifacts/remote_ref.txt")
      pr_hint_file = Path.join(output_root, "artifacts/pr_url_hint.md")
      diagnostics_file = Path.join(output_root, "artifacts/startup_diagnostics.json")

      assert File.exists?(summary_file)
      assert File.exists?(push_result_file)
      assert File.exists?(remote_ref_file)
      assert File.exists?(pr_hint_file)
      assert File.exists?(diagnostics_file)

      assert {:ok, push_result_contents} = File.read(push_result_file)
      assert String.contains?(push_result_contents, "\"push_status\"")
      assert String.contains?(push_result_contents, "\"classification\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_push_flow(workspace, {:error, reason, diagnostics}, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    {:ok, workspace} =
      HarnessScenarioHelpers.write_json_artifact(workspace, @push_result_path, %{
        "status" => "setup_required",
        "reason" => reason,
        "push_status" => "not_run",
        "classification" => "missing_setup"
      })

    {:ok, workspace} = Workspace.write(workspace, @remote_ref_path, "")
    {:ok, workspace} = Workspace.write(workspace, @pr_hint_path, "")
    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", reason}, {"elapsed_ms", elapsed_ms}], workspace}
  end

  defp run_push_flow(workspace, {:ok, backend_config, diagnostics}, started_at) do
    case Workspace.start_session(workspace, backend: {Sprite, backend_config}, cwd: "/") do
      {:ok, workspace} ->
        ScenarioHelpers.put_workspace(workspace)

        root_dir = "/tmp/spec24_#{System.unique_integer([:positive])}"
        branch_name = "spec24/push-#{System.unique_integer([:positive])}"
        remote_dir = "#{root_dir}/remote.git"
        work_dir = "#{root_dir}/work"

        steps = [
          {"init_remote", "rm -rf #{root_dir} && mkdir -p #{root_dir} && git init --bare #{remote_dir}"},
          {"init_work", "git init #{work_dir}"},
          {"git_config",
           "cd #{work_dir} && git config user.email 'spec24@example.com' && git config user.name 'Spec 24 Bot'"},
          {"seed_commit",
           "cd #{work_dir} && printf 'spec24\\n' > README.md && git add README.md && git commit -m 'chore: baseline'"},
          {"create_branch", "cd #{work_dir} && git checkout -b #{branch_name}"},
          {"add_remote", "cd #{work_dir} && git remote add origin #{remote_dir}"},
          {"push_branch", "cd #{work_dir} && git push origin #{branch_name}"},
          {"remote_ref", "git --git-dir=#{remote_dir} show-ref refs/heads/#{branch_name}"}
        ]

        {workspace, results} =
          Enum.reduce(steps, {workspace, []}, fn {name, command}, {acc_workspace, acc_results} ->
            {next_workspace, result} = run_command(acc_workspace, command)
            {next_workspace, acc_results ++ [Map.put(result, "step", name)]}
          end)

        push_result = Enum.find(results, &(&1["step"] == "push_branch")) || %{}
        ref_result = Enum.find(results, &(&1["step"] == "remote_ref")) || %{}

        classification = classify_push(push_result)
        push_ok? = push_result["status"] == "ok"
        remote_ref_ok? = ref_result["status"] == "ok"
        status = if push_ok? and remote_ref_ok?, do: "ok", else: "setup_required"

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        push_artifact = %{
          "status" => status,
          "push_status" => push_result["status"] || "unknown",
          "classification" => classification,
          "branch" => branch_name,
          "remote_dir" => remote_dir,
          "steps" => results
        }

        pr_hint = """
        # PR URL Hint

        branch: #{branch_name}
        hint: gh pr create --head #{branch_name} --base main --title "Spec24 push branch"
        """

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @push_result_path, push_artifact)
        {:ok, workspace} = Workspace.write(workspace, @remote_ref_path, ref_result["output"] || "")
        {:ok, workspace} = Workspace.write(workspace, @pr_hint_path, pr_hint)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        {:ok, workspace} = Workspace.stop_session(workspace)
        ScenarioHelpers.put_workspace(workspace)

        {status,
         [
           {"branch", branch_name},
           {"classification", classification},
           {"push_ok", push_ok?},
           {"remote_ref_ok", remote_ref_ok?},
           {"elapsed_ms", elapsed_ms}
         ], workspace}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(workspace, @push_result_path, %{
            "status" => "setup_required",
            "reason" => "sprite_start_failed",
            "error" => inspect(reason),
            "push_status" => "not_run",
            "classification" => "startup_failed"
          })

        {:ok, workspace} = Workspace.write(workspace, @remote_ref_path, "")
        {:ok, workspace} = Workspace.write(workspace, @pr_hint_path, "")

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

  defp classify_push(%{"status" => "ok"}), do: "success"

  defp classify_push(%{"error" => error}) when is_binary(error) do
    cond do
      String.contains?(error, "auth") or String.contains?(error, "permission") -> "auth_failure"
      String.contains?(error, "non-fast-forward") -> "non_fast_forward"
      true -> "push_failed"
    end
  end

  defp classify_push(_), do: "unknown"

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
