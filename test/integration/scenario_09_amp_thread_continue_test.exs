defmodule Jido.Workspace.Integration.Scenario09AmpThreadContinueTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 09 goal: Continue an existing Amp thread and store transcript artifacts.
  """

  alias Jido.Amp
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @result_path "/artifacts/amp_result.txt"
  @transcript_path "/artifacts/thread_transcript.md"
  @diagnostics_path "/artifacts/amp_diagnostics.json"
  @error_path "/artifacts/errors.json"
  @prompt "Continue this thread and reply with OK."

  test "amp thread continue workflow captures transcript artifacts", %{tmp_dir: tmp_dir} do
    previous_amp_cli_path = System.get_env("AMP_CLI_PATH")
    maybe_configured_amp_cli_path = configure_amp_cli_path()

    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("09_amp_thread_continue", "spec-09", tmp_dir)

    on_exit(fn ->
      restore_amp_cli_path(previous_amp_cli_path)
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    started_at_ms = System.monotonic_time(:millisecond)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      {status, summary_fields, workspace} =
        run_amp_thread_continue(workspace, output_root, started_at_ms, maybe_configured_amp_cli_path)

      summary_json =
        ScenarioHelpers.summary_json(
          "09_amp_thread_continue",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      diagnostics_file = Path.join(output_root, "artifacts/amp_diagnostics.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(diagnostics_file)
      assert File.exists?(summary_file)

      case status do
        "ok" ->
          result_file = Path.join(output_root, "artifacts/amp_result.txt")
          transcript_file = Path.join(output_root, "artifacts/thread_transcript.md")

          assert File.exists?(result_file)
          assert File.exists?(transcript_file)

          assert {:ok, transcript_contents} = File.read(transcript_file)
          refute String.trim(transcript_contents) == ""

        "setup_required" ->
          assert {:ok, diagnostics_contents} = File.read(diagnostics_file)
          assert String.contains?(diagnostics_contents, "setup_required")
      end
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_amp_thread_continue(workspace, output_root, started_at_ms, configured_amp_cli_path) do
    case Amp.Compatibility.status() do
      {:ok, compatibility_metadata} ->
        with {:ok, {thread_id, thread_source}} <- resolve_thread_id(),
             {:ok, run_result} <- Amp.run(@prompt, continue_thread: thread_id, cwd: output_root),
             {:ok, transcript_markdown} <- Amp.Threads.markdown(thread_id) do
          elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

          {:ok, workspace} = Workspace.write(workspace, @result_path, run_result)
          ScenarioHelpers.put_workspace(workspace)

          {:ok, workspace} = Workspace.write(workspace, @transcript_path, transcript_markdown)
          ScenarioHelpers.put_workspace(workspace)

          diagnostics = %{
            "status" => "ok",
            "compatibility" => compatibility_metadata,
            "thread_id" => thread_id,
            "thread_source" => thread_source,
            "configured_amp_cli_path" => configured_amp_cli_path,
            "elapsed_ms" => elapsed_ms
          }

          {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
          ScenarioHelpers.put_workspace(workspace)

          {"ok",
           [
             {"thread_id", thread_id},
             {"thread_source", thread_source},
             {"elapsed_ms", elapsed_ms}
           ], workspace}
        else
          {:error, reason} ->
            elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

            diagnostics = %{
              "status" => "setup_required",
              "reason" => "amp_thread_continue_failed",
              "error" => inspect(reason),
              "configured_amp_cli_path" => configured_amp_cli_path,
              "elapsed_ms" => elapsed_ms
            }

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
            ScenarioHelpers.put_workspace(workspace)

            {"setup_required", [{"reason", "amp_thread_continue_failed"}], workspace}
        end

      {:error, compatibility_error} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

        diagnostics = %{
          "status" => "setup_required",
          "reason" => "amp_compatibility_failed",
          "error" => inspect(compatibility_error),
          "compatibility_key" => Map.get(compatibility_error, :key),
          "compatibility_details" => Map.get(compatibility_error, :details, %{}),
          "configured_amp_cli_path" => configured_amp_cli_path,
          "elapsed_ms" => elapsed_ms
        }

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        ScenarioHelpers.put_workspace(workspace)

        {"setup_required", [{"reason", "amp_compatibility_failed"}], workspace}
    end
  end

  defp resolve_thread_id do
    env_thread_id =
      System.get_env("JIDO_WORKSPACE_SPEC_09_THREAD_ID") ||
        System.get_env("JIDO_AMP_THREAD_ID") ||
        System.get_env("AMP_THREAD_ID")

    cond do
      is_binary(env_thread_id) and String.trim(env_thread_id) != "" ->
        {:ok, {String.trim(env_thread_id), "env"}}

      true ->
        case Amp.Threads.new() do
          {:ok, thread_id} when is_binary(thread_id) and thread_id != "" ->
            {:ok, {thread_id, "created"}}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_thread_result, other}}
        end
    end
  end

  defp configure_amp_cli_path do
    case resolve_amp_cli_path() do
      nil ->
        nil

      cli_path ->
        System.put_env("AMP_CLI_PATH", cli_path)
        cli_path
    end
  end

  defp resolve_amp_cli_path do
    cond do
      valid_executable_path?(System.get_env("AMP_CLI_PATH")) ->
        System.get_env("AMP_CLI_PATH")

      true ->
        case System.cmd("asdf", ["which", "amp"], stderr_to_stdout: true) do
          {path, 0} ->
            trimmed = String.trim(path)
            if valid_executable_path?(trimmed), do: trimmed, else: System.find_executable("amp")

          _ ->
            System.find_executable("amp")
        end
    end
  end

  defp valid_executable_path?(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp valid_executable_path?(_), do: false

  defp restore_amp_cli_path(nil), do: System.delete_env("AMP_CLI_PATH")
  defp restore_amp_cli_path(value), do: System.put_env("AMP_CLI_PATH", value)
end
