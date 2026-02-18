defmodule Jido.Workspace.Integration.Scenario07HarnessEventLogCaptureTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 07 goal: Validate event persistence contract for replay/debug across providers.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @events_path "/artifacts/events.jsonl"
  @event_summary_path "/artifacts/event_summary.json"
  @final_output_path "/artifacts/final_output.txt"
  @error_path "/artifacts/errors.json"
  @prompt "Respond with one short sentence containing OK."

  test "harness event log capture writes ordered events and summary artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("07_harness_event_log_capture", "spec-07", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      providers = Harness.providers()
      default_provider = Harness.default_provider()
      selected_provider = HarnessScenarioHelpers.select_default_or_first_provider(providers, default_provider)

      {status, summary_fields, workspace} =
        capture_event_log(workspace, selected_provider, providers, default_provider, output_root)

      summary_json =
        ScenarioHelpers.summary_json(
          "07_harness_event_log_capture",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      events_file = Path.join(output_root, "artifacts/events.jsonl")
      event_summary_file = Path.join(output_root, "artifacts/event_summary.json")
      final_output_file = Path.join(output_root, "artifacts/final_output.txt")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(events_file)
      assert File.exists?(event_summary_file)
      assert File.exists?(final_output_file)
      assert File.exists?(summary_file)

      case status do
        "ok" ->
          assert {:ok, events_contents} = File.read(events_file)
          refute String.trim(events_contents) == ""

          assert {:ok, event_summary_contents} = File.read(event_summary_file)
          assert String.contains?(event_summary_contents, "\"event_counts\"")

        "partial_error" ->
          assert {:ok, events_contents} = File.read(events_file)
          assert String.contains?(events_contents, "\"session_failed\"")

        "setup_required" ->
          assert {:ok, event_summary_contents} = File.read(event_summary_file)
          assert String.contains?(event_summary_contents, "setup_required")
      end
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp capture_event_log(workspace, nil, providers, default_provider, _output_root) do
    event_summary = %{
      "status" => "setup_required",
      "reason" => "no_provider_available",
      "default_provider" => format_atom(default_provider),
      "available_providers" => Enum.map(providers, &HarnessScenarioHelpers.provider_to_map/1),
      "event_counts" => %{},
      "event_count" => 0
    }

    {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, [])
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @event_summary_path, event_summary)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = Workspace.write(workspace, @final_output_path, "")
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", "no_provider_available"}], workspace}
  end

  defp capture_event_log(workspace, provider, _providers, _default_provider, output_root) when is_atom(provider) do
    run_opts = [cwd: output_root, timeout_ms: 20_000]

    case Harness.run(provider, @prompt, run_opts) do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 500) do
          {:ok, events, truncated?} ->
            write_event_log_artifacts(workspace, provider, events, truncated?)

          {:error, reason, partial_events} ->
            terminal = HarnessScenarioHelpers.terminal_error_event(provider, reason)
            events = partial_events ++ [terminal]

            {status, summary_fields, workspace} =
              write_event_log_artifacts(workspace, provider, events, false, "partial_error")

            {status, summary_fields ++ [{"reason", "stream_error"}, {"error", inspect(reason)}], workspace}
        end

      {:error, reason} ->
        event_summary = %{
          "status" => "setup_required",
          "provider" => Atom.to_string(provider),
          "reason" => "provider_run_failed",
          "error" => inspect(reason),
          "event_count" => 1,
          "event_counts" => %{"session_failed" => 1}
        }

        terminal = HarnessScenarioHelpers.terminal_error_event(provider, reason)

        {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, [terminal])
        ScenarioHelpers.put_workspace(workspace)

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @event_summary_path, event_summary)
        ScenarioHelpers.put_workspace(workspace)

        {:ok, workspace} = Workspace.write(workspace, @final_output_path, "")
        ScenarioHelpers.put_workspace(workspace)

        {"setup_required",
         [
           {"provider", Atom.to_string(provider)},
           {"reason", "provider_run_failed"}
         ], workspace}
    end
  end

  defp write_event_log_artifacts(workspace, provider, events, truncated?, status \\ "ok") do
    event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)
    event_counts = HarnessScenarioHelpers.event_counts(events)
    final_text = HarnessScenarioHelpers.final_output_text(events)

    event_summary = %{
      "status" => status,
      "provider" => Atom.to_string(provider),
      "event_count" => length(events),
      "event_counts" => event_counts,
      "truncated" => truncated?
    }

    {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, event_maps)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @event_summary_path, event_summary)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = Workspace.write(workspace, @final_output_path, final_text)
    ScenarioHelpers.put_workspace(workspace)

    {status,
     [
       {"provider", Atom.to_string(provider)},
       {"event_count", length(events)},
       {"truncated", truncated?}
     ], workspace}
  end

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(_value), do: nil
end
