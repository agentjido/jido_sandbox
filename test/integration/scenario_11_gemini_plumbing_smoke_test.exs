defmodule Jido.Workspace.Integration.Scenario11GeminiPlumbingSmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 11 goal: Verify Gemini adapter plumbing path and artifact contract even before full mapping depth.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @contract_path "/artifacts/adapter_contract.json"
  @direct_events_path "/artifacts/direct_events.jsonl"
  @harness_events_path "/artifacts/harness_events.jsonl"
  @todo_path "/artifacts/mapping_todo.md"
  @error_path "/artifacts/errors.json"
  @prompt "Return the literal text OK."

  test "gemini adapter plumbing path is callable and writes contract artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("11_gemini_plumbing_smoke", "spec-11", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      direct_result = collect_result(fn -> JidoGemini.run(@prompt, cwd: output_root, timeout_ms: 20_000) end)
      harness_result = collect_result(fn -> Harness.run(:gemini, @prompt, cwd: output_root, timeout_ms: 20_000) end)

      {:ok, workspace} =
        HarnessScenarioHelpers.write_jsonl_artifact(workspace, @direct_events_path, direct_result.event_maps)

      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} =
        HarnessScenarioHelpers.write_jsonl_artifact(workspace, @harness_events_path, harness_result.event_maps)

      ScenarioHelpers.put_workspace(workspace)

      contract = %{
        "status" => "ok",
        "prompt" => @prompt,
        "direct" => result_to_map(direct_result),
        "harness" => result_to_map(harness_result),
        "empty_stream" => direct_result.empty_stream and harness_result.empty_stream
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @contract_path, contract)
      ScenarioHelpers.put_workspace(workspace)

      todo_md = """
      # Gemini Mapping Expansion TODO

      - Validate output text delta/final mapping parity.
      - Add tool call/tool result mapping fixtures.
      - Capture session lifecycle events when available.
      - Add usage and error payload mapping assertions.
      """

      {:ok, workspace} = Workspace.write(workspace, @todo_path, todo_md)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "11_gemini_plumbing_smoke",
          "ok",
          workspace_id,
          [
            {"direct_status", direct_result.status},
            {"direct_event_count", direct_result.event_count},
            {"harness_status", harness_result.status},
            {"harness_event_count", harness_result.event_count},
            {"empty_stream", direct_result.empty_stream and harness_result.empty_stream}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      contract_file = Path.join(output_root, "artifacts/adapter_contract.json")
      todo_file = Path.join(output_root, "artifacts/mapping_todo.md")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(contract_file)
      assert File.exists?(todo_file)
      assert File.exists?(summary_file)

      assert {:ok, contract_contents} = File.read(contract_file)
      assert String.contains?(contract_contents, "\"empty_stream\"")
      assert String.contains?(contract_contents, "\"direct\"")
      assert String.contains?(contract_contents, "\"harness\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp collect_result(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 250) do
          {:ok, events, truncated?} ->
            event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)

            %{
              status: "ok",
              event_count: length(events),
              empty_stream: events == [],
              truncated: truncated?,
              event_maps: event_maps
            }

          {:error, reason, partial_events} ->
            event_maps =
              Enum.map(partial_events, &HarnessScenarioHelpers.event_to_map/1) ++
                [HarnessScenarioHelpers.terminal_error_event(:gemini, reason)]

            %{
              status: "stream_error",
              event_count: length(partial_events),
              empty_stream: partial_events == [],
              truncated: false,
              error: inspect(reason),
              event_maps: event_maps
            }
        end

      {:error, reason} ->
        %{
          status: "error",
          event_count: 0,
          empty_stream: true,
          truncated: false,
          error: inspect(reason),
          event_maps: []
        }

      other ->
        %{
          status: "unexpected_result",
          event_count: 0,
          empty_stream: true,
          truncated: false,
          error: inspect(other),
          event_maps: []
        }
    end
  end

  defp result_to_map(result) do
    %{
      "status" => result.status,
      "event_count" => result.event_count,
      "empty_stream" => result.empty_stream,
      "truncated" => result.truncated,
      "error" => Map.get(result, :error)
    }
  end
end
