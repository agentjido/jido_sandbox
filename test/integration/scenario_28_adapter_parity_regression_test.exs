defmodule Jido.Workspace.Integration.Scenario28AdapterParityRegressionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 28 goal: Run one canonical prompt through all adapters and compare normalized event behavior.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @parity_report_path "/artifacts/parity_report.json"
  @regression_flags_path "/artifacts/regression_flags.json"
  @provider_matrix_path "/artifacts/provider_matrix.json"
  @error_path "/artifacts/errors.json"

  @prompt "Return only one short sentence containing the token PARITY_OK."

  test "adapter parity harness records per-provider metrics and machine-readable divergences", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("28_adapter_parity_regression", "spec-28", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts/providers")
      ScenarioHelpers.put_workspace(workspace)

      providers = Harness.providers() |> Enum.map(& &1.id)

      {workspace, provider_metrics} =
        Enum.reduce(providers, {workspace, []}, fn provider, {acc_workspace, acc_metrics} ->
          metric = run_provider(provider, output_root)

          events_path = "/artifacts/providers/#{Atom.to_string(provider)}_events.jsonl"

          {:ok, next_workspace} =
            HarnessScenarioHelpers.write_jsonl_artifact(acc_workspace, events_path, metric["event_maps"])

          ScenarioHelpers.put_workspace(next_workspace)
          {next_workspace, acc_metrics ++ [Map.delete(metric, "event_maps")]}
        end)

      baseline =
        provider_metrics
        |> Enum.find(fn metric -> metric["status"] == "ok" and metric["event_count"] > 0 end)

      divergences = build_divergences(provider_metrics, baseline)

      parity_report = %{
        "prompt" => @prompt,
        "provider_count" => length(provider_metrics),
        "baseline_provider" => baseline && baseline["provider"],
        "baseline_event_count" => baseline && baseline["event_count"],
        "divergences" => divergences,
        "providers" => provider_metrics
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @parity_report_path, parity_report)
      ScenarioHelpers.put_workspace(workspace)

      regressions =
        provider_metrics
        |> Enum.filter(fn metric ->
          metric["status"] in ["run_error", "stream_error"] and metric["terminal_state"] != "skipped"
        end)

      regression_flags = %{
        "regression_count" => length(regressions),
        "regressions" => regressions,
        "all_providers_skipped" => Enum.all?(provider_metrics, &(&1["terminal_state"] == "skipped"))
      }

      {:ok, workspace} =
        HarnessScenarioHelpers.write_json_artifact(workspace, @regression_flags_path, regression_flags)

      ScenarioHelpers.put_workspace(workspace)

      provider_matrix = %{
        "providers" =>
          Enum.map(provider_metrics, fn metric ->
            %{
              "provider" => metric["provider"],
              "status" => metric["status"],
              "event_count" => metric["event_count"],
              "latency_ms" => metric["latency_ms"],
              "terminal_state" => metric["terminal_state"]
            }
          end)
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @provider_matrix_path, provider_matrix)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "28_adapter_parity_regression",
          "ok",
          workspace_id,
          [
            {"provider_count", length(provider_metrics)},
            {"divergence_count", length(divergences)},
            {"regression_count", length(regressions)}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      parity_file = Path.join(output_root, "artifacts/parity_report.json")
      regression_file = Path.join(output_root, "artifacts/regression_flags.json")
      matrix_file = Path.join(output_root, "artifacts/provider_matrix.json")

      assert File.exists?(summary_file)
      assert File.exists?(parity_file)
      assert File.exists?(regression_file)
      assert File.exists?(matrix_file)

      assert {:ok, parity_contents} = File.read(parity_file)
      assert String.contains?(parity_contents, "\"divergences\"")
      assert String.contains?(parity_contents, "\"providers\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_provider(provider, output_root) do
    started = System.monotonic_time(:millisecond)

    case Harness.run(provider, @prompt, cwd: output_root, timeout_ms: 10_000) do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 250) do
          {:ok, events, _truncated?} ->
            latency = System.monotonic_time(:millisecond) - started

            %{
              "provider" => Atom.to_string(provider),
              "status" => if(events == [], do: "empty", else: "ok"),
              "event_count" => length(events),
              "event_types" => HarnessScenarioHelpers.event_counts(events),
              "terminal_state" => if(events == [], do: "empty", else: "completed"),
              "latency_ms" => latency,
              "error" => nil,
              "event_maps" => Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)
            }

          {:error, reason, partial_events} ->
            latency = System.monotonic_time(:millisecond) - started

            %{
              "provider" => Atom.to_string(provider),
              "status" => "stream_error",
              "event_count" => length(partial_events),
              "event_types" => HarnessScenarioHelpers.event_counts(partial_events),
              "terminal_state" => "stream_error",
              "latency_ms" => latency,
              "error" => inspect(reason),
              "event_maps" => Enum.map(partial_events, &HarnessScenarioHelpers.event_to_map/1)
            }
        end

      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - started

        %{
          "provider" => Atom.to_string(provider),
          "status" => "run_error",
          "event_count" => 0,
          "event_types" => %{},
          "terminal_state" => "skipped",
          "latency_ms" => latency,
          "error" => inspect(reason),
          "event_maps" => []
        }
    end
  end

  defp build_divergences(provider_metrics, nil) do
    Enum.map(provider_metrics, fn metric ->
      %{
        "provider" => metric["provider"],
        "kind" => "no_baseline",
        "details" => %{"status" => metric["status"], "event_count" => metric["event_count"]}
      }
    end)
  end

  defp build_divergences(provider_metrics, baseline) do
    baseline_types = Map.keys(baseline["event_types"] || %{}) |> MapSet.new()
    baseline_count = baseline["event_count"] || 0

    provider_metrics
    |> Enum.reject(&(&1["provider"] == baseline["provider"]))
    |> Enum.flat_map(fn metric ->
      provider_types = Map.keys(metric["event_types"] || %{}) |> MapSet.new()
      missing_types = MapSet.difference(baseline_types, provider_types) |> MapSet.to_list() |> Enum.sort()
      count_delta = (metric["event_count"] || 0) - baseline_count

      divergence =
        %{
          "provider" => metric["provider"],
          "status" => metric["status"],
          "count_delta" => count_delta,
          "missing_types" => missing_types
        }

      if count_delta != 0 or missing_types != [] or metric["status"] != "ok" do
        [divergence]
      else
        []
      end
    end)
  end
end
