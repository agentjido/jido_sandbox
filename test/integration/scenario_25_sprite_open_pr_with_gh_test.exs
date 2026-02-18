defmodule Jido.Workspace.Integration.Scenario25SpriteOpenPrWithGhTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 25 goal: Create a pull request from pushed branch using GitHub CLI on Sprite.
  """

  alias Jido.Shell.Backend.Sprite
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @request_path "/artifacts/pr_request.md"
  @response_path "/artifacts/pr_response.json"
  @publish_summary_path "/artifacts/publish_summary.json"
  @fallback_command_path "/artifacts/fallback_pr_command.sh"
  @diagnostics_path "/artifacts/startup_diagnostics.json"
  @error_path "/artifacts/errors.json"

  test "sprite gh PR workflow writes request response and fallback artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("25_sprite_open_pr_with_gh", "spec-25", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    started_at = System.monotonic_time(:millisecond)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      sprite_config = sprite_backend_config("25")
      {status, summary_fields, workspace} = run_pr_flow(workspace, sprite_config, started_at)

      assert status == "ok",
             "expected live sprite execution, got status=#{status} fields=#{inspect(summary_fields)}"

      summary_json =
        ScenarioHelpers.summary_json(
          "25_sprite_open_pr_with_gh",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      request_file = Path.join(output_root, "artifacts/pr_request.md")
      response_file = Path.join(output_root, "artifacts/pr_response.json")
      publish_summary_file = Path.join(output_root, "artifacts/publish_summary.json")
      fallback_command_file = Path.join(output_root, "artifacts/fallback_pr_command.sh")
      diagnostics_file = Path.join(output_root, "artifacts/startup_diagnostics.json")

      assert File.exists?(summary_file)
      assert File.exists?(request_file)
      assert File.exists?(response_file)
      assert File.exists?(publish_summary_file)
      assert File.exists?(fallback_command_file)
      assert File.exists?(diagnostics_file)

      assert {:ok, response_contents} = File.read(response_file)
      assert String.contains?(response_contents, "\"pr_status\"")
      assert String.contains?(response_contents, "\"gh_status\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_pr_flow(workspace, {:error, reason, diagnostics}, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    {:ok, workspace} = Workspace.write(workspace, @request_path, "")
    {:ok, workspace} = Workspace.write(workspace, @fallback_command_path, "# setup required\n")

    {:ok, workspace} =
      HarnessScenarioHelpers.write_json_artifact(workspace, @response_path, %{
        "status" => "setup_required",
        "reason" => reason,
        "gh_status" => "not_run",
        "pr_status" => "not_created"
      })

    {:ok, workspace} =
      HarnessScenarioHelpers.write_json_artifact(workspace, @publish_summary_path, %{
        "status" => "setup_required",
        "reason" => reason
      })

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", reason}, {"elapsed_ms", elapsed_ms}], workspace}
  end

  defp run_pr_flow(workspace, {:ok, backend_config, diagnostics}, started_at) do
    gh_token = System.get_env("GH_TOKEN")
    repo_slug = System.get_env("JIDO_WORKSPACE_SPEC_25_REPO")
    base_branch = System.get_env("JIDO_WORKSPACE_SPEC_25_BASE") || "main"

    case Workspace.start_session(workspace, backend: {Sprite, backend_config}, cwd: "/") do
      {:ok, workspace} ->
        ScenarioHelpers.put_workspace(workspace)

        root_dir = "/tmp/spec25_#{System.unique_integer([:positive])}"
        work_dir = "#{root_dir}/work"
        branch_name = "spec25/pr-#{System.unique_integer([:positive])}"

        clone_url =
          if is_binary(gh_token) and String.trim(gh_token) != "" and is_binary(repo_slug) and
               String.trim(repo_slug) != "" do
            "https://x-access-token:#{String.trim(gh_token)}@github.com/#{String.trim(repo_slug)}.git"
          else
            ""
          end

        setup_steps = [
          {"cleanup", "rm -rf #{root_dir} && mkdir -p #{root_dir}"},
          {"clone", "git clone #{clone_url} #{work_dir} 2>&1"},
          {"git_config",
           "cd #{work_dir} && git config user.email 'spec25@example.com' && git config user.name 'Spec 25 Bot'"},
          {"create_branch", "cd #{work_dir} && git checkout -b #{branch_name}"},
          {"seed_commit",
           "cd #{work_dir} && printf 'spec25 #{branch_name}\\n' >> README.md && git add README.md && git commit -m 'chore: spec25 baseline'"},
          {"push_branch", "cd #{work_dir} && git push origin #{branch_name} 2>&1"},
          {"gh_version", "gh --version"}
        ]

        {workspace, setup_results} =
          Enum.reduce(setup_steps, {workspace, []}, fn {name, command}, {acc_workspace, acc_results} ->
            {next_workspace, result} = run_command(acc_workspace, command)
            {next_workspace, acc_results ++ [Map.put(result, "step", name)]}
          end)

        request_markdown =
          """
          # PR Request

          - branch: #{branch_name}
          - base: #{base_branch}
          - repo: #{repo_slug || "(not configured)"}

          ## Summary
          Automated PR creation attempt from scenario 25.
          """

        fallback_command =
          "gh pr create --repo <owner/repo> --head #{branch_name} --base #{base_branch} --title \"Spec25 remote PR\" --body \"Generated by scenario 25\""

        gh_available? =
          setup_results
          |> Enum.find(&(&1["step"] == "gh_version"))
          |> case do
            %{"status" => "ok"} -> true
            _ -> false
          end

        can_attempt_pr? =
          gh_available? and is_binary(gh_token) and String.trim(gh_token) != "" and is_binary(repo_slug) and
            String.trim(repo_slug) != ""

        {workspace, pr_result} =
          if can_attempt_pr? do
            gh_cmd =
              "cd #{work_dir} && GH_TOKEN=#{String.trim(gh_token)} gh pr create --repo #{String.trim(repo_slug)} --head #{branch_name} --base #{base_branch} --title 'Spec25 remote PR' --body 'Generated by scenario 25' 2>&1"

            run_command(workspace, gh_cmd)
          else
            {workspace,
             %{
               "status" => "skipped",
               "output" => "",
               "error" => "missing gh setup (gh cli, GH_TOKEN, or repo slug)"
             }}
          end

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        pr_status = if pr_result["status"] == "ok", do: "created", else: "not_created"
        status = if pr_status == "created", do: "ok", else: "setup_required"

        response = %{
          "status" => status,
          "pr_status" => pr_status,
          "gh_status" => if(gh_available?, do: "available", else: "missing"),
          "repo" => repo_slug || "",
          "branch" => branch_name,
          "setup_steps" => setup_results,
          "pr_attempt" => pr_result
        }

        publish_summary = %{
          "status" => status,
          "pr_status" => pr_status,
          "branch" => branch_name,
          "elapsed_ms" => elapsed_ms,
          "fallback_command_written" => true
        }

        {:ok, workspace} = Workspace.write(workspace, @request_path, request_markdown)
        {:ok, workspace} = Workspace.write(workspace, @fallback_command_path, fallback_command <> "\n")
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @response_path, response)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @publish_summary_path, publish_summary)

        diagnostics =
          diagnostics
          |> Map.put("gh_token", if(is_binary(gh_token) and gh_token != "", do: "set", else: "unset"))
          |> Map.put("repo_slug", repo_slug || "(unset)")

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        {:ok, workspace} = Workspace.stop_session(workspace)
        ScenarioHelpers.put_workspace(workspace)

        {status,
         [
           {"branch", branch_name},
           {"pr_status", pr_status},
           {"gh_available", gh_available?},
           {"elapsed_ms", elapsed_ms}
         ], workspace}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        {:ok, workspace} = Workspace.write(workspace, @request_path, "")
        {:ok, workspace} = Workspace.write(workspace, @fallback_command_path, "# sprite startup failed\n")

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(workspace, @response_path, %{
            "status" => "setup_required",
            "reason" => "sprite_start_failed",
            "error" => inspect(reason),
            "gh_status" => "unknown",
            "pr_status" => "not_created"
          })

        {:ok, workspace} =
          HarnessScenarioHelpers.write_json_artifact(workspace, @publish_summary_path, %{
            "status" => "setup_required",
            "reason" => "sprite_start_failed"
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

  defp run_command(workspace, command, opts \\ []) do
    case Workspace.run(workspace, command, opts) do
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
