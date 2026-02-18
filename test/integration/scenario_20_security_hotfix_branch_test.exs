defmodule Jido.Workspace.Integration.Scenario20SecurityHotfixBranchTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 20 goal: Apply targeted security fix and produce branch-ready patch bundle.
  """

  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @advisory_map_path "/artifacts/advisory_map.json"
  @security_checks_path "/artifacts/security_checks.json"
  @unit_output_path "/artifacts/unit_test_output.txt"
  @threat_delta_path "/artifacts/threat_model_delta.json"
  @branch_summary_path "/artifacts/branch_summary.md"
  @error_path "/artifacts/errors.json"

  @advisory_id "CVE-2026-4099"
  @advisory_path "/advisories/CVE-2026-4099.md"
  @target_module_path "/project/lib/token_guard.ex"
  @target_test_path "/project/test/token_guard_test.exs"

  test "security hotfix applies patch, validates checks, and emits branch bundle", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("20_security_hotfix_branch", "spec-20", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      {:ok, workspace} = write_hotfix_project(workspace)
      ScenarioHelpers.put_workspace(workspace)

      impacted_files = [@target_module_path, @target_test_path]
      advisory = advisory_payload()

      advisory_map = %{
        "advisory_id" => @advisory_id,
        "advisory_path" => @advisory_path,
        "impacted_files" => impacted_files,
        "summary" => advisory
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @advisory_map_path, advisory_map)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, snapshot_id, workspace} = Workspace.snapshot(workspace)
      ScenarioHelpers.put_workspace(workspace)

      {:ok, workspace} = Workspace.write(workspace, @target_module_path, secure_token_guard_module())
      {:ok, workspace} = Workspace.write(workspace, @target_test_path, secure_token_guard_tests())
      ScenarioHelpers.put_workspace(workspace)

      {:ok, patched_module} = Workspace.read(workspace, @target_module_path)
      security_findings = run_security_checks(patched_module)

      project_root = Path.join(output_root, "project")
      {unit_output, unit_exit} = run_mix(project_root, ["test"])
      checks_passed = security_findings == [] and unit_exit == 0

      {workspace, restored_snapshot?, restore_error} =
        if checks_passed do
          {workspace, false, nil}
        else
          case Workspace.restore(workspace, snapshot_id) do
            {:ok, restored_workspace} ->
              ScenarioHelpers.put_workspace(restored_workspace)
              {restored_workspace, true, nil}

            {:error, reason} ->
              {workspace, false, inspect(reason)}
          end
        end

      workspace = ensure_artifacts_dir(workspace)
      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @advisory_map_path, advisory_map)
      {:ok, workspace} = Workspace.write(workspace, @unit_output_path, unit_output)
      ScenarioHelpers.put_workspace(workspace)

      security_report = %{
        "advisory_id" => @advisory_id,
        "checks_passed" => checks_passed,
        "unit_test_exit_code" => unit_exit,
        "restored_snapshot" => restored_snapshot?,
        "restore_error" => restore_error,
        "findings" => security_findings
      }

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @security_checks_path, security_report)
      ScenarioHelpers.put_workspace(workspace)

      threat_model_delta =
        if checks_passed do
          %{
            "risk_before" => "high",
            "risk_after" => "low",
            "controls_added" => [
              "constant-time token comparison",
              "minimum token length guard",
              "security regression tests"
            ],
            "unresolved_risks" => []
          }
        else
          %{
            "risk_before" => "high",
            "risk_after" => "high",
            "controls_added" => [],
            "unresolved_risks" => [
              "hotfix verification failed",
              "workspace restored to pre-patch snapshot #{snapshot_id}"
            ]
          }
        end

      {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @threat_delta_path, threat_model_delta)
      ScenarioHelpers.put_workspace(workspace)

      branch_name = "hotfix/cve-2026-4099-token-compare"
      commit_message = "fix(security): harden token comparison for #{@advisory_id}"

      branch_summary = """
      # Security Hotfix Branch Summary

      - advisory: #{@advisory_id}
      - branch: #{branch_name}
      - checks_passed: #{checks_passed}
      - unit_test_exit_code: #{unit_exit}
      - restored_snapshot: #{restored_snapshot?}
      - restore_error: #{restore_error || "none"}

      ## Commit Message Suggestion
      #{commit_message}
      """

      {:ok, workspace} = Workspace.write(workspace, @branch_summary_path, branch_summary)
      ScenarioHelpers.put_workspace(workspace)

      status = if checks_passed, do: "ok", else: "setup_required"

      summary_json =
        ScenarioHelpers.summary_json(
          "20_security_hotfix_branch",
          status,
          workspace_id,
          [
            {"advisory_id", @advisory_id},
            {"branch", branch_name},
            {"unit_test_exit_code", unit_exit},
            {"finding_count", length(security_findings)},
            {"restored_snapshot", restored_snapshot?},
            {"restore_error", restore_error || ""}
          ]
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      advisory_map_file = Path.join(output_root, "artifacts/advisory_map.json")
      security_checks_file = Path.join(output_root, "artifacts/security_checks.json")
      unit_output_file = Path.join(output_root, "artifacts/unit_test_output.txt")
      threat_delta_file = Path.join(output_root, "artifacts/threat_model_delta.json")
      branch_summary_file = Path.join(output_root, "artifacts/branch_summary.md")

      assert File.exists?(summary_file)
      assert File.exists?(advisory_map_file)
      assert File.exists?(security_checks_file)
      assert File.exists?(unit_output_file)
      assert File.exists?(threat_delta_file)
      assert File.exists?(branch_summary_file)

      assert {:ok, branch_summary_contents} = File.read(branch_summary_file)
      assert String.contains?(branch_summary_contents, "hotfix/cve-2026-4099-token-compare")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp write_hotfix_project(workspace) do
    files = [
      {@advisory_path, advisory_payload()},
      {"/project/mix.exs", security_mix_exs()},
      {@target_module_path, vulnerable_token_guard_module()},
      {@target_test_path, vulnerable_token_guard_tests()},
      {"/project/test/test_helper.exs", "ExUnit.start()\n"}
    ]

    Enum.reduce_while(files, {:ok, workspace}, fn {path, content}, {:ok, acc_workspace} ->
      case Workspace.write(acc_workspace, path, content) do
        {:ok, next_workspace} -> {:cont, {:ok, next_workspace}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp advisory_payload do
    """
    #{@advisory_id}
    Severity: HIGH
    Title: Non-constant-time token comparison
    Details: Token verification used direct equality and accepted short tokens.
    Required Fix: Use constant-time compare and enforce minimum token length.
    """
  end

  defp security_mix_exs do
    """
    defmodule SecurityHotfixSample.MixProject do
      use Mix.Project

      def project do
        [
          app: :security_hotfix_sample,
          version: "0.2.0",
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

  defp vulnerable_token_guard_module do
    """
    defmodule TokenGuard do
      def verify(expected, provided) when is_binary(expected) and is_binary(provided) do
        expected != "" and expected == provided
      end
    end
    """
  end

  defp vulnerable_token_guard_tests do
    """
    defmodule TokenGuardTest do
      use ExUnit.Case, async: true

      test "allows exact token match" do
        assert TokenGuard.verify("shared-secret", "shared-secret")
      end

      test "rejects non matching tokens" do
        refute TokenGuard.verify("shared-secret", "different-secret")
      end
    end
    """
  end

  defp secure_token_guard_module do
    """
    defmodule TokenGuard do
      import Bitwise

      @minimum_token_bytes 8

      def verify(expected, provided) when is_binary(expected) and is_binary(provided) do
        byte_size(expected) >= @minimum_token_bytes and
          byte_size(provided) == byte_size(expected) and
          secure_compare(expected, provided)
      end

      def verify(_expected, _provided), do: false

      defp secure_compare(left, right) do
        left
        |> :binary.bin_to_list()
        |> Enum.zip(:binary.bin_to_list(right))
        |> Enum.reduce(0, fn {a, b}, acc -> bor(acc, bxor(a, b)) end)
        |> Kernel.==(0)
      end
    end
    """
  end

  defp secure_token_guard_tests do
    """
    defmodule TokenGuardTest do
      use ExUnit.Case, async: true

      test "allows exact token match for long token" do
        assert TokenGuard.verify("shared-secret", "shared-secret")
      end

      test "rejects non matching tokens" do
        refute TokenGuard.verify("shared-secret", "different-secret")
      end

      test "rejects short tokens even when equal" do
        refute TokenGuard.verify("short", "short")
      end
    end
    """
  end

  defp run_security_checks(module_source) do
    findings = []

    findings =
      if Regex.match?(~r/expected\s*==\s*provided/, module_source) do
        ["insecure direct token equality remains" | findings]
      else
        findings
      end

    if Regex.match?(~r/@minimum_token_bytes\s+8/, module_source) do
      findings
    else
      ["minimum token length guard missing" | findings]
    end
  end

  defp run_mix(project_root, args) do
    try do
      System.cmd("mix", args, cd: project_root, stderr_to_stdout: true, timeout: 90_000)
    rescue
      error ->
        {"mix #{Enum.join(args, " ")} failed: #{Exception.message(error)}\n", 1}
    catch
      :exit, reason ->
        {"mix #{Enum.join(args, " ")} failed: #{inspect(reason)}\n", 124}
    end
  end

  defp ensure_artifacts_dir(workspace) do
    case Workspace.mkdir(workspace, "/artifacts") do
      {:ok, ensured_workspace} -> ensured_workspace
      {:error, _reason} -> workspace
    end
  end
end
