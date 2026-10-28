defmodule ABSmartly.Test.OkPublisher do
  @moduledoc """
  Publisher stub that always reports success, so tests of queue/flush logic do
  not depend on (and silently swallow failures of) a real network transport.
  """

  @behaviour ABSmartly.ContextPublisher

  @impl ABSmartly.ContextPublisher
  def publish(_endpoint, _api_key, _application, _environment, _event_map, _retries), do: :ok
end

defmodule ABSmartly.Test.ScriptedPublisher do
  @moduledoc """
  Publisher stub driven by a per-test script of responses.

  `start/1` starts an Agent (linked to the test process) holding the scripted
  responses and returns its name as a string. Pass that string as the
  `SDKConfig.endpoint`; `publish/6` uses it to find the script. Each publish
  attempt consumes the next response and records the event map it was given.
  Once the script is exhausted every attempt succeeds.

  Responses: `:ok`, `{:error, reason}`, `{:raise, message}` or `{:sleep, ms}`.
  """

  @behaviour ABSmartly.ContextPublisher

  def start(responses) when is_list(responses) do
    name = :"scripted_publisher_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> %{responses: responses, attempts: []} end, name: name)
    Atom.to_string(name)
  end

  def attempts(endpoint) do
    Agent.get(String.to_existing_atom(endpoint), fn state -> Enum.reverse(state.attempts) end)
  end

  @impl ABSmartly.ContextPublisher
  def publish(endpoint, _api_key, _application, _environment, event_map, _retries) do
    response =
      Agent.get_and_update(String.to_existing_atom(endpoint), fn state ->
        {next, rest} =
          case state.responses do
            [] -> {:ok, []}
            [head | tail] -> {head, tail}
          end

        {next, %{state | responses: rest, attempts: [event_map | state.attempts]}}
      end)

    case response do
      {:raise, message} ->
        raise message

      {:sleep, ms} ->
        Process.sleep(ms)
        :ok

      other ->
        other
    end
  end
end

ExUnit.start()
