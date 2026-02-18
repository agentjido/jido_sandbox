defmodule Jido.Workspace.Integration.Scenario27MultiProviderConsensusPatchTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 27 goal: Generate patch with one provider, critique with second, and finalize after consensus checks.
  """

  alias Jido.Harness
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @provider_a_path "/artifacts/provider_a_response.md"
  @provider_b_path "/artifacts/provider_b_critique.md"
  @consensus_log_path "/artifacts/consensus_log.json"
  @conflict_matrix_path "/artifacts/conflict_matrix.json"
  @patch_path "/artifacts/final_patch.diff"
  @verification_log_path "/artifacts/verification.log"
  @error_path "/artifacts/errors.json"

  test "multi-provider consensus workflow records decisions and validation artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("27_multi_provider_consensus_patch", "spec-27", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = write_project(workspace)
      ScenarioHelpers.put_workspace(workspace)

      provider_ids = Harness.providers() |> Enum.map(& &1.id)
      {provider_a, provider_b} = select_two_providers(provider_ids)

      proposal_prompt = "Propose a concise patch plan to fix Calculator.subtract/2."
      critique_prompt = "Critique patch risks and required tests for Calculator.subtract/2."

      proposal = run_provider(provider_a, proposal_prompt, output_root)
      critique = run_provider(provider_b, critique_prompt, output_root)

      {:ok, workspace} = Workspace.write(workspace, @provider_a_path, provider_markdown(provider_a, proposal))
      {:ok, workspace} = Workspace.write(workspace, @provider_b_path, provider_markdown(provider_b, critique))
      ScenarioHelpers.put_workspace(workspace)

      consensus_possible? =
        proposal["status"] == "ok" and critique["status"] == "ok" and proposal["text"] != "" and
          critique["text"] != ""

      {verification_log, verify_exit, patch_text, consensus_status, workspace} =
        if consensus_possible? do
          {:ok, workspace} = Workspace.write(workspace, "/project/lib/calculator.ex", fixed_calculator_module())
          ScenarioHelpers.put_workspace(workspace)

          project_root = Path.join(output_root, "project")
          {verify_log, verify_exit} = run_mix(project_root, ["test"])

          patch_text =
            """
            --- a/lib/calculator.ex
            +++ b/lib/calculator.ex
            @@
            -def subtract(a, b), do: a + b
            +def subtract(a, b), do: a - b
            """

          {"#{verify_log}", verify_exit, patch_text,
           if(verify_exit == 0, do: "consensus_applied", else: "verify_failed"), workspace}
        else
          {
            "consensus not reached; patch not applied",
            1,
            "",
            "conflict",
            workspace
          }
        end

      {:ok, workspace} = Workspace.write(workspace, @patch_path, patch_text)
      {:ok, workspace} = Workspace.write(workspace, @verification_log_path, verification_log)
      ScenarioHelpers.put_workspace(workspace)

      conflict_matrix = %{
        "provider_a" => provider_result_summary(provider_a, proposal),
        "provider_b" => provider_result_summary(provider_b, critique),
        "consensus_possible" => consensus_possible?,
        "consensus_status" => consensus_status
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @conflict_matrix_path, conflict_matrix)
      ScenarioHelpers.put_workspace(workspace)

      consensus_log = %{
        "provider_a" => atom_to_string(provider_a),
        "provider_b" => atom_to_string(provider_b),
        "proposal_status" => proposal["status"],
        "critique_status" => critique["status"],
        "consensus_status" => consensus_status,
        "verification_exit_code" => verify_exit
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @consensus_log_path, consensus_log)
      ScenarioHelpers.put_workspace(workspace)

      status = if consensus_status == "consensus_applied", do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "27_multi_provider_consensus_patch",
          status,
          workspace_id,
          [
            {"provider_a", atom_to_string(provider_a)},
            {"provider_b", atom_to_string(provider_b)},
            {"consensus_status", consensus_status},
            {"verification_exit_code", verify_exit}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      consensus_log_file = Path.join(output_root, "artifacts/consensus_log.json")
      conflict_matrix_file = Path.join(output_root, "artifacts/conflict_matrix.json")
      patch_file = Path.join(output_root, "artifacts/final_patch.diff")
      verification_file = Path.join(output_root, "artifacts/verification.log")

      assert File.exists?(summary_file)
      assert File.exists?(consensus_log_file)
      assert File.exists?(conflict_matrix_file)
      assert File.exists?(patch_file)
      assert File.exists?(verification_file)

      assert {:ok, consensus_contents} = File.read(consensus_log_file)
      assert String.contains?(consensus_contents, "\"provider_a\"")
      assert String.contains?(consensus_contents, "\"provider_b\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp select_two_providers([a, b | _rest]), do: {a, b}
  defp select_two_providers([a]), do: {a, nil}
  defp select_two_providers([]), do: {nil, nil}

  defp run_provider(nil, _prompt, _output_root) do
    %{"status" => "unavailable", "text" => "", "error" => "provider missing"}
  end

  defp run_provider(provider, prompt, output_root) do
    case Harness.run(provider, prompt, cwd: output_root, timeout_ms: 10_000) do
      {:ok, stream} ->
        case HarnessScenarioHelpers.collect_events(stream, 200) do
          {:ok, events, _truncated?} ->
            %{
              "status" => if(events == [], do: "empty", else: "ok"),
              "text" => HarnessScenarioHelpers.final_output_text(events),
              "event_count" => length(events),
              "error" => nil
            }

          {:error, reason, partial_events} ->
            %{
              "status" => "stream_error",
              "text" => HarnessScenarioHelpers.final_output_text(partial_events),
              "event_count" => length(partial_events),
              "error" => inspect(reason)
            }
        end

      {:error, reason} ->
        %{"status" => "run_error", "text" => "", "event_count" => 0, "error" => inspect(reason)}
    end
  end

  defp provider_markdown(provider, result) do
    """
    # Provider #{atom_to_string(provider)}

    - status: #{result["status"]}
    - event_count: #{result["event_count"] || 0}
    - error: #{result["error"] || "none"}

    ## Output
    #{result["text"]}
    """
  end

  defp provider_result_summary(provider, result) do
    %{
      "provider" => atom_to_string(provider),
      "status" => result["status"],
      "event_count" => result["event_count"] || 0,
      "error" => result["error"]
    }
  end

  defp run_mix(project_root, args) do
    try do
      System.cmd("mix", args, cd: project_root, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true, timeout: 90_000)
    rescue
      error ->
        {"mix #{Enum.join(args, " ")} failed: #{Exception.message(error)}\n", 1}
    catch
      :exit, reason ->
        {"mix #{Enum.join(args, " ")} failed: #{inspect(reason)}\n", 124}
    end
  end

  defp write_project(workspace) do
    files = [
      {"/project/mix.exs", project_mix_exs()},
      {"/project/lib/calculator.ex", buggy_calculator_module()},
      {"/project/test/test_helper.exs", "ExUnit.start()\n"},
      {"/project/test/calculator_test.exs", calculator_test_module()}
    ]

    Enum.reduce_while(files, {:ok, workspace}, fn {path, content}, {:ok, acc_workspace} ->
      case Workspace.write(acc_workspace, path, content) do
        {:ok, next_workspace} -> {:cont, {:ok, next_workspace}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp project_mix_exs do
    """
    defmodule ConsensusSample.MixProject do
      use Mix.Project

      def project do
        [
          app: :consensus_sample,
          version: "0.1.0",
          elixir: "~> 1.14",
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """
  end

  defp buggy_calculator_module do
    """
    defmodule Calculator do
      def subtract(a, b), do: a + b
    end
    """
  end

  defp fixed_calculator_module do
    """
    defmodule Calculator do
      def subtract(a, b), do: a - b
    end
    """
  end

  defp calculator_test_module do
    """
    defmodule CalculatorTest do
      use ExUnit.Case, async: true

      test "subtract/2" do
        assert Calculator.subtract(7, 2) == 5
      end
    end
    """
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(other), do: inspect(other)
end
