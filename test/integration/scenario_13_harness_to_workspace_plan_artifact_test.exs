defmodule Jido.Workspace.Integration.Scenario13HarnessToWorkspacePlanArtifactTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 13 goal: Use harness output to generate a concrete implementation plan artifact in workspace.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @plan_json_path "/artifacts/plan.json"
  @plan_md_path "/artifacts/plan.md"
  @assumptions_path "/artifacts/assumptions.json"
  @events_path "/artifacts/events.jsonl"
  @error_path "/artifacts/errors.json"

  @prompt """
  Produce a concise implementation plan as JSON.
  Return exactly one JSON object with key "steps" and value array of strings.
  Keep to at most 5 steps.
  """

  test "harness output is converted into plan artifacts with parser fallback", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("13_harness_to_workspace_plan_artifact", "spec-13", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      providers = Harness.providers()
      default_provider = Harness.default_provider()
      selected_provider = HarnessScenarioHelpers.select_default_or_first_provider(providers, default_provider)

      {result, workspace} = run_planning_prompt(workspace, selected_provider, output_root)

      {:ok, workspace} =
        HarnessScenarioHelpers.write_json_artifact(workspace, @plan_json_path, %{"steps" => result.steps})

      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, @plan_md_path, to_markdown_plan(result.steps))
      ScenarioHelpers.put_workspace(workspace)

      assumptions = %{
        "provider" => format_atom(selected_provider),
        "provider_status" => result.provider_status,
        "parse_warning" => result.parse_warning,
        "parse_errors" => result.parse_errors
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @assumptions_path, assumptions)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = HarnessScenarioHelpers.write_jsonl_artifact(workspace, @events_path, result.event_maps)
      ScenarioHelpers.put_workspace(workspace)

      summary_json =
        ScenarioHelpers.summary_json(
          "13_harness_to_workspace_plan_artifact",
          "ok",
          workspace_id,
          [
            {"provider", format_atom(selected_provider)},
            {"provider_status", result.provider_status},
            {"step_count", length(result.steps)},
            {"parse_warning", result.parse_warning}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      plan_json_file = Path.join(output_root, "artifacts/plan.json")
      plan_md_file = Path.join(output_root, "artifacts/plan.md")
      assumptions_file = Path.join(output_root, "artifacts/assumptions.json")
      summary_file = Path.join(output_root, "artifacts/run_summary.json")

      assert File.exists?(plan_json_file)
      assert File.exists?(plan_md_file)
      assert File.exists?(assumptions_file)
      assert File.exists?(summary_file)

      assert {:ok, plan_md_contents} = File.read(plan_md_file)
      assert String.contains?(plan_md_contents, "1. ")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_planning_prompt(workspace, nil, _output_root) do
    {%{
       steps: fallback_steps(),
       provider_status: "no_provider_available",
       parse_warning: true,
       parse_errors: ["no provider available"],
       event_maps: []
     }, workspace}
  end

  defp run_planning_prompt(workspace, provider, output_root) do
    case Harness.run(provider, @prompt, cwd: output_root, timeout_ms: 25_000) do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 400) do
          {:ok, events, _truncated?} ->
            event_maps = Enum.map(events, &HarnessScenarioHelpers.event_to_map/1)
            final_text = HarnessScenarioHelpers.final_output_text(events)
            plan_result = parse_or_fallback_plan(final_text)

            {%{
               steps: plan_result.steps,
               provider_status: "ok",
               parse_warning: plan_result.parse_warning,
               parse_errors: plan_result.parse_errors,
               event_maps: event_maps
             }, workspace}

          {:error, reason, partial_events} ->
            event_maps =
              Enum.map(partial_events, &HarnessScenarioHelpers.event_to_map/1) ++
                [HarnessScenarioHelpers.terminal_error_event(provider, reason)]

            {%{
               steps: fallback_steps(),
               provider_status: "stream_error",
               parse_warning: true,
               parse_errors: ["stream error: #{inspect(reason)}"],
               event_maps: event_maps
             }, workspace}
        end

      {:error, reason} ->
        {%{
           steps: fallback_steps(),
           provider_status: "run_error",
           parse_warning: true,
           parse_errors: ["run error: #{inspect(reason)}"],
           event_maps: []
         }, workspace}
    end
  end

  defp parse_or_fallback_plan(text) when is_binary(text) do
    case parse_plan_steps(text) do
      [] ->
        %{steps: fallback_steps(), parse_warning: true, parse_errors: ["plan parse fallback used"]}

      steps ->
        %{steps: steps, parse_warning: false, parse_errors: []}
    end
  end

  defp parse_plan_steps(text) do
    text
    |> parse_json_steps()
    |> case do
      [] -> parse_numbered_lines(text)
      steps -> steps
    end
    |> Enum.take(5)
  end

  defp parse_json_steps(text) do
    candidates = [String.trim(text), extract_fenced_json(text)]

    Enum.find_value(candidates, [], fn candidate ->
      case candidate do
        value when is_binary(value) and value != "" ->
          case Jason.decode(value) do
            {:ok, decoded} -> normalize_json_steps(decoded)
            {:error, _} -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp normalize_json_steps(%{"steps" => steps}) when is_list(steps), do: normalize_step_list(steps)
  defp normalize_json_steps(%{steps: steps}) when is_list(steps), do: normalize_step_list(steps)
  defp normalize_json_steps(steps) when is_list(steps), do: normalize_step_list(steps)
  defp normalize_json_steps(_), do: []

  defp normalize_step_list(steps) do
    steps
    |> Enum.map(fn
      value when is_binary(value) ->
        String.trim(value)

      %{"text" => text} when is_binary(text) ->
        String.trim(text)

      %{text: text} when is_binary(text) ->
        String.trim(text)

      other ->
        other |> inspect() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_numbered_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.filter(&Regex.match?(~r/^\s*\d+[\.\)]\s+.+$/, &1))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*\d+[\.\)]\s+/, "")
      |> String.trim()
    end)
  end

  defp extract_fenced_json(text) do
    case Regex.run(~r/```(?:json)?\s*(\{[\s\S]*?\}|\[[\s\S]*?\])\s*```/i, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> ""
    end
  end

  defp fallback_steps do
    [
      "Confirm scope and constraints for the requested change.",
      "Implement the smallest safe code change.",
      "Run focused verification and capture artifacts."
    ]
  end

  defp to_markdown_plan(steps) do
    heading = "# Implementation Plan\n\n"

    body =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, idx} -> "#{idx}. #{step}" end)

    heading <> body <> "\n"
  end

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(_), do: nil
end
