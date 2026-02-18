defmodule Jido.Workspace.TestSupport.HarnessScenarioHelpers do
  @moduledoc false

  alias Jido.Harness
  alias Jido.Harness.Event
  alias Jido.Harness.Provider
  alias Jido.Workspace

  @type failover_attempt :: %{
          provider: atom(),
          status: :provider_unavailable | :run_error | :empty_event_stream | :stream_error | :success,
          details: map()
        }

  @spec select_default_or_first_provider([Provider.t()], atom() | nil) :: atom() | nil
  def select_default_or_first_provider(providers, default_provider) when is_list(providers) do
    provider_ids = Enum.map(providers, & &1.id)

    cond do
      is_atom(default_provider) and default_provider in provider_ids -> default_provider
      provider_ids == [] -> nil
      true -> List.first(provider_ids)
    end
  end

  @spec collect_events(Enumerable.t(), pos_integer()) ::
          {:ok, [term()], boolean()} | {:error, term(), [term()]}
  def collect_events(stream, max_events \\ 250) when is_integer(max_events) and max_events > 0 do
    events_key = {__MODULE__, :collected_events}
    truncated_key = {__MODULE__, :truncated_events}
    Process.put(events_key, [])
    Process.put(truncated_key, false)

    try do
      _ =
        Enum.reduce_while(stream, 0, fn event, count ->
          Process.put(events_key, [event | Process.get(events_key, [])])
          next_count = count + 1

          if next_count >= max_events do
            Process.put(truncated_key, true)
            {:halt, next_count}
          else
            {:cont, next_count}
          end
        end)

      {:ok, collected_events(events_key), Process.get(truncated_key, false)}
    rescue
      error ->
        {:error, error, collected_events(events_key)}
    catch
      kind, reason ->
        {:error, {kind, reason}, collected_events(events_key)}
    after
      Process.delete(events_key)
      Process.delete(truncated_key)
    end
  end

  @spec write_json_artifact(Workspace.t(), String.t(), term()) :: {:ok, Workspace.t()} | {:error, term()}
  def write_json_artifact(%Workspace.Workspace{} = workspace, path, payload) when is_binary(path) do
    Workspace.write(workspace, path, json_encode!(payload, pretty: true))
  end

  @spec write_jsonl_artifact(Workspace.t(), String.t(), [term()]) :: {:ok, Workspace.t()} | {:error, term()}
  def write_jsonl_artifact(%Workspace.Workspace{} = workspace, path, entries)
      when is_binary(path) and is_list(entries) do
    jsonl =
      entries
      |> Enum.map(&json_encode!(&1))
      |> Enum.join("\n")
      |> append_newline_when_present()

    Workspace.write(workspace, path, jsonl)
  end

  @spec provider_to_map(Provider.t()) :: map()
  def provider_to_map(%Provider{} = provider) do
    %{
      "id" => Atom.to_string(provider.id),
      "name" => provider.name,
      "docs_url" => provider.docs_url
    }
  end

  @spec event_to_map(term()) :: map()
  def event_to_map(%Event{} = event) do
    %{
      "type" => to_string(event.type),
      "provider" => to_string(event.provider),
      "session_id" => event.session_id,
      "timestamp" => event.timestamp,
      "payload" => stringify_keys(event.payload || %{}),
      "raw" => stringify_keys(event.raw)
    }
  end

  def event_to_map(%{} = event), do: stringify_keys(event)
  def event_to_map(other), do: %{"value" => inspect(other)}

  @spec event_counts([term()]) :: map()
  def event_counts(events) when is_list(events) do
    events
    |> Enum.map(&event_type/1)
    |> Enum.frequencies()
  end

  @spec final_output_text([term()]) :: String.t()
  def final_output_text(events) when is_list(events) do
    events
    |> Enum.flat_map(fn event ->
      payload_text = get_event_payload_text(event)
      if is_binary(payload_text) and payload_text != "", do: [payload_text], else: []
    end)
    |> Enum.join("\n")
  end

  @spec run_with_failover([atom()], String.t(), keyword(), pos_integer()) ::
          {:ok, %{provider: atom(), events: [term()], truncated?: boolean(), attempts: [failover_attempt()]}}
          | {:error, [failover_attempt()]}
  def run_with_failover(provider_order, prompt, run_opts, max_events \\ 250)
      when is_list(provider_order) and is_binary(prompt) and is_list(run_opts) and is_integer(max_events) and
             max_events > 0 do
    Enum.reduce_while(provider_order, [], fn provider, attempts ->
      if Jido.Harness.Registry.available?(provider) do
        case Harness.run(provider, prompt, run_opts) do
          {:ok, stream} ->
            case collect_events(stream, max_events) do
              {:ok, [], truncated?} ->
                attempt = %{
                  provider: provider,
                  status: :empty_event_stream,
                  details: %{"truncated" => truncated?}
                }

                {:cont, attempts ++ [attempt]}

              {:ok, events, truncated?} ->
                success_attempt = %{
                  provider: provider,
                  status: :success,
                  details: %{"event_count" => length(events), "truncated" => truncated?}
                }

                {:halt,
                 {:ok,
                  %{provider: provider, events: events, truncated?: truncated?, attempts: attempts ++ [success_attempt]}}}

              {:error, reason, partial_events} ->
                attempt = %{
                  provider: provider,
                  status: :stream_error,
                  details: %{
                    "reason" => inspect(reason),
                    "partial_event_count" => length(partial_events)
                  }
                }

                {:cont, attempts ++ [attempt]}
            end

          {:error, reason} ->
            attempt = %{
              provider: provider,
              status: :run_error,
              details: %{"reason" => inspect(reason)}
            }

            {:cont, attempts ++ [attempt]}
        end
      else
        attempt = %{
          provider: provider,
          status: :provider_unavailable,
          details: %{}
        }

        {:cont, attempts ++ [attempt]}
      end
    end)
    |> case do
      {:ok, success} ->
        {:ok, success}

      attempts when is_list(attempts) ->
        {:error, attempts}
    end
  end

  @spec format_attempts([failover_attempt()]) :: [map()]
  def format_attempts(attempts) when is_list(attempts) do
    Enum.map(attempts, fn attempt ->
      %{
        "provider" => Atom.to_string(attempt.provider),
        "status" => Atom.to_string(attempt.status),
        "details" => attempt.details
      }
    end)
  end

  @spec terminal_error_event(atom(), term()) :: map()
  def terminal_error_event(provider, reason) when is_atom(provider) do
    %{
      "type" => "session_failed",
      "provider" => Atom.to_string(provider),
      "session_id" => nil,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{"error" => inspect(reason)},
      "raw" => %{"kind" => "stream_error"}
    }
  end

  defp collected_events(key) do
    key
    |> Process.get([])
    |> Enum.reverse()
  end

  defp append_newline_when_present(""), do: ""
  defp append_newline_when_present(content), do: content <> "\n"

  defp event_type(%Event{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp event_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp event_type(%{type: type}) when is_binary(type), do: type
  defp event_type(%{"type" => type}) when is_binary(type), do: type
  defp event_type(_), do: "unknown"

  defp get_event_payload_text(%Event{payload: payload}) when is_map(payload) do
    Map.get(payload, "text") || Map.get(payload, :text)
  end

  defp get_event_payload_text(%{payload: payload}) when is_map(payload) do
    Map.get(payload, "text") || Map.get(payload, :text)
  end

  defp get_event_payload_text(%{"payload" => payload}) when is_map(payload) do
    Map.get(payload, "text") || Map.get(payload, :text)
  end

  defp get_event_payload_text(_), do: nil

  defp stringify_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp json_encode!(payload, opts \\ []) do
    if Code.ensure_loaded?(Jason) do
      apply(Jason, :encode!, [payload, opts])
    else
      inspect(payload)
    end
  end
end
