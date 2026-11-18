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

defmodule ABSmartly.SwitchbackTestSupport do
  @moduledoc """
  Helpers shared by the switchback tests (a port of the Java SDK's
  `SwitchbackTestSupport`): a settable clock, passed to the context through
  its internal `:clock` start option, and a context whose events are
  captured.
  """

  alias ABSmartly.{Context, Types}

  # An :atomics clock, so a context outliving the test process (its final
  # publish on terminate) can still read it. Slot 2 holds a one-shot read.
  @no_read -0x8000000000000000

  @doc "A clock at `now`; `set/2` moves it and `next_read/2` overrides one read."
  def clock(now) do
    clock = :atomics.new(2, signed: true)
    :atomics.put(clock, 1, now)
    :atomics.put(clock, 2, @no_read)
    clock
  end

  def set(clock, now), do: :atomics.put(clock, 1, now)
  def next_read(clock, value), do: :atomics.put(clock, 2, value)

  def read(clock) do
    case :atomics.exchange(clock, 2, @no_read) do
      @no_read -> :atomics.get(clock, 1)
      value -> value
    end
  end

  @doc """
  Starts a context over `data` (a raw payload map, decoded as the SDK's
  fetch decodes it) and returns `{ctx, events}`; `events` is an Agent
  holding `{type, data}` in emission order.
  """
  def start(clock, units, data, opts \\ []) do
    {:ok, events} = Agent.start_link(fn -> [] end)

    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: ABSmartly.Test.OkPublisher
    }

    context_config = %Types.ContextConfig{
      units: units,
      attributes: Keyword.get(opts, :attributes, []),
      event_handler: fn type, payload -> Agent.update(events, &[{type, payload} | &1]) end
    }

    {:ok, ctx} =
      Context.start_link(sdk_config, context_data(data), context_config,
        clock: fn -> read(clock) end
      )

    {ctx, events}
  end

  @doc "A raw payload map as the SDK's fetch would decode it."
  def context_data(data) do
    {:ok, decoded} = data |> Jason.encode!() |> ABSmartly.Switchback.Json.decode()
    Types.ContextData.from_map(decoded)
  end

  @doc "Publishes and returns the published exposures as wire maps."
  def publish_exposures(ctx, events) do
    Agent.update(events, fn _ -> [] end)
    :ok = Context.publish(ctx)

    events
    |> Agent.get(&Enum.reverse/1)
    |> Enum.flat_map(fn
      {:publish, event} -> event["exposures"]
      _ -> []
    end)
  end

  @doc "Publishes and returns the published event maps."
  def publish_events(ctx, events) do
    Agent.update(events, fn _ -> [] end)
    :ok = Context.publish(ctx)

    events
    |> Agent.get(&Enum.reverse/1)
    |> Enum.flat_map(fn
      {:publish, event} -> [event]
      _ -> []
    end)
  end

  @doc "An ordered switchbackClusters value."
  def clusters(pairs), do: %Jason.OrderedObject{values: pairs}
end
