defmodule Jido.Workspace.Integration.Scenario12ClaudeMixTaskSmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 12 goal: Run Claude task in repo cwd and capture output artifacts through script wrapper.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @stdout_path "/artifacts/claude_stdout.txt"
  @stderr_path "/artifacts/claude_stderr.txt"
  @invocation_path "/artifacts/invocation.json"
  @error_path "/artifacts/errors.json"

  test "claude mix task smoke captures invocation outputs in workspace cwd", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("12_claude_mix_task_smoke", "spec-12", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    claude_root = Path.expand("../../../jido_claude", __DIR__)

    args = [
      "jido_claude",
      "--cwd",
      output_root,
      "--max-turns",
      "1",
      "Return the literal text OK."
    ]

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      run_result = run_mix_task(claude_root, args)

      {:ok, workspace} = Workspace.write(workspace, @stdout_path, run_result.stdout)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, @stderr_path, run_result.stderr)
      ScenarioHelpers.put_workspace(workspace)

      invocation = %{
        "status" => run_result.status,
        "exit_code" => run_result.exit_code,
        "error" => run_result.error,
        "cwd" => claude_root,
        "args" => args,
        "env" => %{
          "ANTHROPIC_API_KEY" => env_state("ANTHROPIC_API_KEY"),
          "ANTHROPIC_AUTH_TOKEN" => env_state("ANTHROPIC_AUTH_TOKEN"),
          "ANTHROPIC_BASE_URL" => env_state("ANTHROPIC_BASE_URL"),
          "ANTHROPIC_DEFAULT_HAIKU_MODEL" => env_state("ANTHROPIC_DEFAULT_HAIKU_MODEL"),
          "ANTHROPIC_DEFAULT_SONNET_MODEL" => env_state("ANTHROPIC_DEFAULT_SONNET_MODEL"),
          "ANTHROPIC_DEFAULT_OPUS_MODEL" => env_state("ANTHROPIC_DEFAULT_OPUS_MODEL"),
          "CLAUDE_API_KEY" => env_state("CLAUDE_API_KEY"),
          "CLAUDE_CODE_API_KEY" => env_state("CLAUDE_CODE_API_KEY")
        }
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @invocation_path, invocation)
      ScenarioHelpers.put_workspace(workspace)

      status = if run_result.exit_code == 0, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "12_claude_mix_task_smoke",
          status,
          workspace_id,
          [
            {"exit_code", run_result.exit_code},
            {"status", run_result.status},
            {"cwd", claude_root}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      stdout_file = Path.join(output_root, "artifacts/claude_stdout.txt")
      stderr_file = Path.join(output_root, "artifacts/claude_stderr.txt")
      invocation_file = Path.join(output_root, "artifacts/invocation.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(stdout_file)
      assert File.exists?(stderr_file)
      assert File.exists?(invocation_file)
      assert File.exists?(summary_file)

      assert {:ok, invocation_contents} = File.read(invocation_file)
      assert String.contains?(invocation_contents, "\"args\"")
      assert String.contains?(invocation_contents, "\"exit_code\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_mix_task(claude_root, args) do
    cond do
      not File.dir?(claude_root) ->
        %{
          status: "missing_project",
          exit_code: 127,
          stdout: "",
          stderr: "jido_claude project not found at #{claude_root}",
          error: "missing_project"
        }

      true ->
        try do
          {output, exit_code} =
            System.cmd("mix", args,
              cd: claude_root,
              stderr_to_stdout: true,
              env: [{"MIX_ENV", "test"}],
              timeout: 25_000
            )

          %{
            status: if(exit_code == 0, do: "ok", else: "command_failed"),
            exit_code: exit_code,
            stdout: output,
            stderr: "",
            error: nil
          }
        rescue
          error ->
            %{
              status: "command_exception",
              exit_code: 1,
              stdout: "",
              stderr: Exception.message(error),
              error: Exception.message(error)
            }
        catch
          :exit, reason ->
            %{
              status: "command_exception",
              exit_code: 124,
              stdout: "",
              stderr: inspect(reason),
              error: inspect(reason)
            }
        end
    end
  end

  defp env_state(name) do
    if is_binary(System.get_env(name)), do: "set", else: "unset"
  end
end
