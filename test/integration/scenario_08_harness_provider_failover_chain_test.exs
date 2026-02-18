defmodule Jido.Workspace.Integration.Scenario08HarnessProviderFailoverChainTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 08 goal: Attempt providers in order until one run succeeds, recording all failures.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @events_path "/artifacts/events.jsonl"
  @failures_path "/artifacts/failover_failures.json"
  @error_path "/artifacts/errors.json"
  @prompt "Return the literal token OK."
  @provider_order [:codex, :amp, :gemini]

  test "provider failover selects first success or records all failures", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("08_harness_provider_failover_chain", "spec-08", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      run_opts = [cwd: output_root, timeout_ms: 15_000]

      {status, summary_fields, workspace} =
        case HarnessScenarioHelpers.run_with_failover(@provider_order, @prompt, run_opts, 300) do
          {:ok, %{provider: provider, events: events, truncated?: truncated?, attempts: attempts}} ->
            event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)
            formatted_attempts = HarnessScenarioHelpers.format_attempts(attempts)

            {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, event_maps)
            ScenarioHelpers.put_workspace(workspace)

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @failures_path, formatted_attempts)
            ScenarioHelpers.put_workspace(workspace)

            {"ok",
             [
               {"winning_provider", Atom.to_string(provider)},
               {"event_count", length(events)},
               {"attempt_count", length(attempts)},
               {"truncated", truncated?}
             ], workspace}

          {:error, attempts} ->
            formatted_attempts = HarnessScenarioHelpers.format_attempts(attempts)

            {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, [])
            ScenarioHelpers.put_workspace(workspace)

            {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @failures_path, formatted_attempts)
            ScenarioHelpers.put_workspace(workspace)

            {"setup_required",
             [
               {"reason", "all_providers_failed"},
               {"attempt_count", length(attempts)}
             ], workspace}
        end

      summary_json =
        ScenarioHelpers.summary_json(
          "08_harness_provider_failover_chain",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      events_file = Path.join(output_root, "artifacts/events.jsonl")
      failures_file = Path.join(output_root, "artifacts/failover_failures.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(events_file)
      assert File.exists?(failures_file)
      assert File.exists?(summary_file)

      assert {:ok, failures_contents} = File.read(failures_file)
      assert String.contains?(failures_contents, "\"provider\"")

      case status do
        "ok" ->
          assert {:ok, events_contents} = File.read(events_file)
          refute String.trim(events_contents) == ""

        "setup_required" ->
          assert String.contains?(failures_contents, "provider_unavailable") or
                   String.contains?(failures_contents, "run_error") or
                   String.contains?(failures_contents, "stream_error") or
                   String.contains?(failures_contents, "empty_event_stream")
      end
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end
end
