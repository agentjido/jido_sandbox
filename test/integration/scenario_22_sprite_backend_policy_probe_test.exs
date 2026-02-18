defmodule Jido.Workspace.Integration.Scenario22SpriteBackendPolicyProbeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scenario 22 goal: Validate remote Sprite shell execution with explicit network policy transitions.
  """

  alias Jido.Shell.Backend.Sprite
  alias Jido.Workspace
  alias Jido.Workspace.TestSupport.HarnessScenarioHelpers
  alias Jido.Workspace.TestSupport.ScenarioHelpers

  @moduletag :integration
  @moduletag :tmp_dir

  @summary_path "/artifacts/run_summary.json"
  @probe_path "/artifacts/policy_probe.json"
  @timings_path "/artifacts/timings.json"
  @diagnostics_path "/artifacts/startup_diagnostics.json"
  @error_path "/artifacts/errors.json"

  test "sprite backend policy probe captures remote execution and policy transition artifacts", %{tmp_dir: tmp_dir} do
    %{workspace: workspace, workspace_id: workspace_id, output_root: output_root} =
      ScenarioHelpers.new_local_workspace!("22_sprite_backend_policy_probe", "spec-22", tmp_dir)

    on_exit(fn ->
      :ok = ScenarioHelpers.close_workspace_if_present()
    end)

    started_at = System.monotonic_time(:millisecond)

    try do
      {:ok, workspace} = Workspace.mkdir(workspace, "/artifacts")
      ScenarioHelpers.put_workspace(workspace)

      sprite_config = sprite_backend_config()

      {status, summary_fields, workspace} =
        run_sprite_policy_probe(workspace, sprite_config, output_root, started_at)

      assert status == "ok",
             "expected live sprite execution, got status=#{status} fields=#{inspect(summary_fields)}"

      summary_json =
        ScenarioHelpers.summary_json(
          "22_sprite_backend_policy_probe",
          status,
          workspace_id,
          summary_fields
        )

      {:ok, workspace} = Workspace.write(workspace, @summary_path, summary_json)
      ScenarioHelpers.put_workspace(workspace)

      summary_file = Path.join(output_root, "artifacts/run_summary.json")
      probe_file = Path.join(output_root, "artifacts/policy_probe.json")
      timings_file = Path.join(output_root, "artifacts/timings.json")
      diagnostics_file = Path.join(output_root, "artifacts/startup_diagnostics.json")

      assert File.exists?(summary_file)
      assert File.exists?(probe_file)
      assert File.exists?(timings_file)
      assert File.exists?(diagnostics_file)

      assert {:ok, probe_contents} = File.read(probe_file)
      assert String.contains?(probe_contents, "\"blocked_network_attempt\"")
      assert String.contains?(probe_contents, "\"allowlisted_network_attempt\"")
    rescue
      error ->
        stacktrace = __STACKTRACE__
        :ok = ScenarioHelpers.write_error_artifact(@error_path, error, stacktrace)
        reraise(error, stacktrace)
    end
  end

  defp run_sprite_policy_probe(workspace, {:error, reason, diagnostics}, _output_root, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    probe = %{
      "status" => "setup_required",
      "reason" => reason,
      "blocked_network_attempt" => %{},
      "allowlisted_network_attempt" => %{}
    }

    timings = %{"elapsed_ms" => elapsed_ms}

    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @probe_path, probe)
    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @timings_path, timings)
    {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
    ScenarioHelpers.put_workspace(workspace)

    {"setup_required", [{"reason", reason}, {"elapsed_ms", elapsed_ms}], workspace}
  end

  defp run_sprite_policy_probe(workspace, {:ok, backend_config, diagnostics}, _output_root, started_at) do
    case Workspace.start_session(workspace, backend: {Sprite, backend_config}, cwd: "/") do
      {:ok, workspace} ->
        ScenarioHelpers.put_workspace(workspace)

        {workspace, pwd_result} = run_command(workspace, "pwd")
        {workspace, uname_result} = run_command(workspace, "uname -s")

        blocked_context = %{network: %{default: :deny}}

        allowlist_context = %{
          network: %{default: :deny, allow_domains: ["example.com"], allow_ports: [443]}
        }

        network_cmd =
          "sh -lc 'command -v curl >/dev/null && curl -Is https://example.com | head -n 1 || echo curl-unavailable'"

        {workspace, blocked_result} = run_command(workspace, network_cmd, execution_context: blocked_context)
        {workspace, allowlisted_result} = run_command(workspace, network_cmd, execution_context: allowlist_context)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        probe = %{
          "status" => "ok",
          "baseline" => %{"pwd" => pwd_result, "uname" => uname_result},
          "blocked_network_attempt" => blocked_result,
          "allowlisted_network_attempt" => allowlisted_result
        }

        timings = %{
          "elapsed_ms" => elapsed_ms,
          "commands" => [
            %{"name" => "pwd", "status" => pwd_result["status"]},
            %{"name" => "uname", "status" => uname_result["status"]},
            %{"name" => "blocked_network", "status" => blocked_result["status"]},
            %{"name" => "allowlisted_network", "status" => allowlisted_result["status"]}
          ]
        }

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @probe_path, probe)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @timings_path, timings)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        {:ok, workspace} = Workspace.stop_session(workspace)
        ScenarioHelpers.put_workspace(workspace)

        status =
          if pwd_result["status"] == "ok" and uname_result["status"] == "ok",
            do: "ok",
            else: "setup_required"

        {status,
         [
           {"sprite_name", Map.get(backend_config, :sprite_name)},
           {"elapsed_ms", elapsed_ms},
           {"baseline_ok", status == "ok"}
         ], workspace}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        probe = %{
          "status" => "setup_required",
          "reason" => "sprite_start_failed",
          "error" => inspect(reason),
          "blocked_network_attempt" => %{},
          "allowlisted_network_attempt" => %{}
        }

        timings = %{"elapsed_ms" => elapsed_ms}

        diagnostics =
          diagnostics
          |> Map.put("start_error", inspect(reason))
          |> Map.put("status", "setup_required")

        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @probe_path, probe)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @timings_path, timings)
        {:ok, workspace} = HarnessScenarioHelpers.write_json_artifact(workspace, @diagnostics_path, diagnostics)
        ScenarioHelpers.put_workspace(workspace)

        {"setup_required", [{"reason", "sprite_start_failed"}, {"elapsed_ms", elapsed_ms}], workspace}
    end
  end

  defp run_command(workspace, command, opts \\ []) do
    case Workspace.run(workspace, command, opts) do
      {:ok, output, updated_workspace} ->
        ScenarioHelpers.put_workspace(updated_workspace)

        {updated_workspace,
         %{
           "status" => "ok",
           "output" => String.trim(output),
           "error" => nil
         }}

      {:error, reason, updated_workspace} ->
        ScenarioHelpers.put_workspace(updated_workspace)

        {updated_workspace,
         %{
           "status" => "error",
           "output" => "",
           "error" => inspect(reason)
         }}
    end
  end

  defp sprite_backend_config do
    token = System.get_env("SPRITES_TOKEN")
    sprite_name_env = System.get_env("JIDO_WORKSPACE_SPEC_22_SPRITE_NAME")
    base_url = System.get_env("SPRITES_BASE_URL")
    create? = parse_bool(System.get_env("JIDO_WORKSPACE_SPEC_22_CREATE"), true)

    diagnostics = %{
      "token" => if(is_binary(token) and token != "", do: "set", else: "unset"),
      "sprite_name" => sprite_name_env || "(generated)",
      "base_url" => if(is_binary(base_url) and base_url != "", do: "set", else: "unset"),
      "create" => create?
    }

    if is_binary(token) and String.trim(token) != "" do
      sprite_name =
        if is_binary(sprite_name_env) and String.trim(sprite_name_env) != "" do
          String.trim(sprite_name_env)
        else
          "jido-workspace-spec22-#{System.unique_integer([:positive])}"
        end

      backend_config =
        %{
          token: String.trim(token),
          sprite_name: sprite_name,
          create: create?
        }
        |> maybe_put_base_url(base_url)

      {:ok, backend_config, Map.put(diagnostics, "resolved_sprite_name", sprite_name)}
    else
      {:error, "missing_sprite_token", Map.put(diagnostics, "status", "setup_required")}
    end
  end

  defp maybe_put_base_url(config, base_url) do
    if is_binary(base_url) and String.trim(base_url) != "" do
      Map.put(config, :base_url, String.trim(base_url))
    else
      config
    end
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when value in ["1", "true", "TRUE", "yes"], do: true
  defp parse_bool(value, _default) when value in ["0", "false", "FALSE", "no"], do: false
  defp parse_bool(_value, default), do: default
end
