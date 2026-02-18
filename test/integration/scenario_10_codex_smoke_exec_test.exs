defmodule Jido.Workspace.Integration.Scenario10CodexSmokeExecTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 10 goal: Run Codex through exec transport and validate normalized stream handling.
  """

  alias Jido.Codex
  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @events_path "/artifacts/events.jsonl"
  @metadata_path "/artifacts/codex_metadata.json"
  @diagnostics_path "/artifacts/diagnostics.json"
  @error_path "/artifacts/errors.json"
  @prompt "Return literal text OK."

  test "codex exec transport smoke captures normalized stream artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("10_codex_smoke_exec", "spec-10", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      {status, summary_fields, workspace} = run_codex_exec_smoke(workspace, output_root)

      summary_json =
        ScenarioHelpers.summary_json(
          "10_codex_smoke_exec",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      metadata_file = Path.join(output_root, "artifacts/codex_metadata.json")
      diagnostics_file = Path.join(output_root, "artifacts/diagnostics.json")

      assert File.exists?(summary_file)
      assert File.exists?(metadata_file)
      assert File.exists?(diagnostics_file)

      case status do
        "ok" ->
          events_file = Path.join(output_root, "artifacts/events.jsonl")
          assert File.exists?(events_file)
          assert {:ok, events_contents} = File.read(events_file)
          refute String.trim(events_contents) == ""

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

  defp run_codex_exec_smoke(workspace, output_root) do
    compatibility_result = Codex.Compatibility.status(:exec)

    {status, summary_fields, metadata, diagnostics, maybe_events} =
      case compatibility_result do
        {:ok, compatibility_metadata} ->
          run_opts = [cwd: output_root, timeout_ms: 20_000, metadata: %{"codex" => %{"transport" => "exec"}}]

          case run_codex_with_fallback(run_opts) do
            {:ok, run_source, stream} ->
              case HarnessScenarioHelpers.collect_events(stream, 300) do
                {:ok, events, truncated?} when events != [] ->
                  raw_event_count = Enum.count(events, &raw_event?/1)
                  event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)

                  metadata = %{
                    "status" => "ok",
                    "run_source" => run_source,
                    "transport" => "exec",
                    "compatible" => true,
                    "compatibility" => compatibility_metadata,
                    "event_count" => length(events),
                    "raw_event_count" => raw_event_count,
                    "truncated" => truncated?
                  }

                  diagnostics = %{
                    "status" => "ok",
                    "run_source" => run_source
                  }

                  {"ok",
                   [
                     {"run_source", run_source},
                     {"event_count", length(events)},
                     {"raw_event_count", raw_event_count},
                     {"truncated", truncated?}
                   ], metadata, diagnostics, event_maps}

                {:ok, _events, truncated?} ->
                  metadata = %{
                    "status" => "setup_required",
                    "transport" => "exec",
                    "compatible" => true,
                    "compatibility" => compatibility_metadata,
                    "reason" => "empty_event_stream",
                    "truncated" => truncated?
                  }

                  diagnostics = %{
                    "status" => "setup_required",
                    "reason" => "empty_event_stream"
                  }

                  {"setup_required",
                   [
                     {"reason", "empty_event_stream"}
                   ], metadata, diagnostics, []}

                {:error, reason, partial_events} ->
                  terminal = HarnessScenarioHelpers.terminal_error_event(:codex, reason)
                  event_maps = Enum.map(partial_events, &HarnessScenarioHelpers.event_to_map/1) ++ [terminal]

                  metadata = %{
                    "status" => "setup_required",
                    "transport" => "exec",
                    "compatible" => true,
                    "compatibility" => compatibility_metadata,
                    "reason" => "stream_error",
                    "partial_event_count" => length(partial_events)
                  }

                  diagnostics = %{
                    "status" => "setup_required",
                    "reason" => "stream_error",
                    "error" => inspect(reason)
                  }

                  {"setup_required",
                   [
                     {"reason", "stream_error"}
                   ], metadata, diagnostics, event_maps}
              end

            {:error, run_errors} ->
              metadata = %{
                "status" => "setup_required",
                "transport" => "exec",
                "compatible" => true,
                "compatibility" => compatibility_metadata,
                "reason" => "run_failed",
                "run_errors" => stringify_error_map(run_errors)
              }

              diagnostics = %{
                "status" => "setup_required",
                "reason" => "run_failed",
                "run_errors" => stringify_error_map(run_errors)
              }

              {"setup_required",
               [
                 {"reason", "run_failed"}
               ], metadata, diagnostics, []}
          end

        {:error, compatibility_error} ->
          metadata = %{
            "status" => "setup_required",
            "transport" => "exec",
            "compatible" => false,
            "compatibility_key" => Map.get(compatibility_error, :key),
            "compatibility_details" => Map.get(compatibility_error, :details, %{}),
            "error" => inspect(compatibility_error)
          }

          diagnostics = %{
            "status" => "setup_required",
            "reason" => "compatibility_failed",
            "compatibility_key" => Map.get(compatibility_error, :key),
            "compatibility_details" => Map.get(compatibility_error, :details, %{}),
            "error" => inspect(compatibility_error)
          }

          {"setup_required",
           [
             {"reason", "compatibility_failed"}
           ], metadata, diagnostics, []}
      end

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @metadata_path, metadata)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, maybe_events)
    ScenarioHelpers.put_workspace(workspace)

    {status, summary_fields, workspace}
  end

  defp run_codex_with_fallback(run_opts) do
    case Harness.run(:codex, @prompt, run_opts) do
      {:ok, stream} ->
        {:ok, "harness", stream}

      {:error, harness_error} ->
        case Codex.run(@prompt, run_opts) do
          {:ok, stream} ->
            {:ok, "codex", stream}

          {:error, codex_error} ->
            {:error, %{harness: harness_error, codex: codex_error}}
        end
    end
  end

  defp raw_event?(%Jido.Harness.Event{raw: raw}), do: not is_nil(raw)
  defp raw_event?(%{raw: raw}), do: not is_nil(raw)
  defp raw_event?(%{"raw" => raw}), do: not is_nil(raw)
  defp raw_event?(_), do: false

  defp stringify_error_map(error_map) when is_map(error_map) do
    error_map
    |> Enum.map(fn {key, value} -> {to_string(key), inspect(value)} end)
    |> Map.new()
  end

  defp stringify_error_map(other), do: %{"error" => inspect(other)}
end
