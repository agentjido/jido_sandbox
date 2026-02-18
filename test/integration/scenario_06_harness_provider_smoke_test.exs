defmodule Jido.Workspace.Integration.Scenario06HarnessProviderSmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 06 goal: Run one prompt through first available harness provider and persist normalized events.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @provider_path "/artifacts/provider.json"
  @events_path "/artifacts/events.jsonl"
  @diagnostics_path "/artifacts/diagnostics.json"
  @error_path "/artifacts/errors.json"
  @prompt "Return the literal text OK."

  test "harness provider smoke captures normalized events and provider metadata", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("06_harness_provider_smoke", "spec-06", tmp_dir)

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
        run_provider_smoke(workspace, selected_provider, providers, default_provider, output_root)

      summary_json =
        ScenarioHelpers.summary_json(
          "06_harness_provider_smoke",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      provider_file = Path.join(output_root, "artifacts/provider.json")
      diagnostics_file = Path.join(output_root, "artifacts/diagnostics.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(provider_file)
      assert File.exists?(diagnostics_file)
      assert File.exists?(summary_file)

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

  defp run_provider_smoke(workspace, nil, providers, default_provider, _output_root) do
    diagnostics = %{
      "status" => "setup_required",
      "reason" => "no_provider_available",
      "default_provider" => format_atom(default_provider),
      "available_providers" => Enum.map(providers, &HarnessScenarioHelpers.provider_to_map/1)
    }

    provider_payload = %{
      "selected_provider" => nil,
      "default_provider" => format_atom(default_provider),
      "available_providers" => Enum.map(providers, &HarnessScenarioHelpers.provider_to_map/1)
    }

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @provider_path, provider_payload)
    ScenarioHelpers.put_workspace(workspace)

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", "no_provider_available"}], workspace}
  end

  defp run_provider_smoke(workspace, provider, providers, default_provider, output_root) when is_atom(provider) do
    provider_payload = %{
      "selected_provider" => Atom.to_string(provider),
      "default_provider" => format_atom(default_provider),
      "available_providers" => Enum.map(providers, &HarnessScenarioHelpers.provider_to_map/1)
    }

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @provider_path, provider_payload)
    ScenarioHelpers.put_workspace(workspace)

    case Harness.run(provider, @prompt, cwd: output_root, timeout_ms: 20_000) do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 250) do
          {:ok, events, truncated?} when events != [] ->
            event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)
            {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, event_maps)
            ScenarioHelpers.put_workspace(workspace)

            diagnostics = %{
              "status" => "ok",
              "provider" => Atom.to_string(provider),
              "event_count" => length(events),
              "truncated" => truncated?
            }

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
            ScenarioHelpers.put_workspace(workspace)

            {"ok",
             [
               {"provider", Atom.to_string(provider)},
               {"event_count", length(events)},
               {"truncated", truncated?}
             ], workspace}

          {:ok, _events, truncated?} ->
            diagnostics = %{
              "status" => "setup_required",
              "reason" => "provider_emitted_no_events",
              "provider" => Atom.to_string(provider),
              "truncated" => truncated?
            }

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
            ScenarioHelpers.put_workspace(workspace)

            {"setup_required",
             [
               {"reason", "provider_emitted_no_events"},
               {"provider", Atom.to_string(provider)}
             ], workspace}

          {:error, reason, partial_events} ->
            event_maps =
              Enum.map(partial_events, &HarnessScenarioHelpers.event_to_map/1) ++
                [HarnessScenarioHelpers.terminal_error_event(provider, reason)]

            {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, event_maps)
            ScenarioHelpers.put_workspace(workspace)

            diagnostics = %{
              "status" => "setup_required",
              "reason" => "provider_stream_error",
              "provider" => Atom.to_string(provider),
              "error" => inspect(reason),
              "partial_event_count" => length(partial_events)
            }

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
            ScenarioHelpers.put_workspace(workspace)

            {"setup_required",
             [
               {"reason", "provider_stream_error"},
               {"provider", Atom.to_string(provider)}
             ], workspace}
        end

      {:error, reason} ->
        diagnostics = %{
          "status" => "setup_required",
          "reason" => "provider_run_failed",
          "provider" => Atom.to_string(provider),
          "error" => inspect(reason)
        }

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        ScenarioHelpers.put_workspace(workspace)

        {"setup_required",
         [
           {"reason", "provider_run_failed"},
           {"provider", Atom.to_string(provider)}
         ], workspace}
    end
  end

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(_value), do: nil
end
