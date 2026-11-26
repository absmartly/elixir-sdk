defmodule ABSmartly.Context do
  use GenServer

  require Logger

  alias ABSmartly.{
    AssignmentRules,
    Types,
    Utils,
    VariantAssigner,
    Matcher,
    HTTP
  }

  @type t :: GenServer.server()

  @max_uid_length 1024
  @max_queue_size 10_000

  defstruct [
    :sdk_config,
    :data,
    :ready,
    :failed,
    :failed_reason,
    :finalized,
    :finalizing,
    :units,
    :attributes,
    :overrides,
    :custom_assignments,
    :assignments,
    :exposures,
    :goals,
    :variable_index,
    :experiment_index,
    :event_handler,
    :exposed_experiments,
    :audience_cache,
    :rules_cache,
    :data_fetcher,
    :attrs_map,
    attrs_seq: 0,
    pending_waiters: [],
    exposure_count: 0,
    goal_count: 0,
    # The holdouts covering each covered experiment, by experiment name:
    # `{key, holdouts}`, the HoldoutData sorted by id and their ids and
    # iterations, precomputed so a cached read compares without allocating.
    # Experiments without coverage have no entry, so a payload without
    # holdouts costs nothing.
    experiment_holdouts: %{},
    # A unit's arm in a holdout, by {holdout id, unit type}, valid while the
    # holdout's iteration is unchanged.
    holdout_assignments: %{},
    # The refs of the exposed arms, like the JavaScript SDK's per-arm
    # `exposed` flag. Each data install keeps only the arms still reachable
    # from a pinned assignment or the arm cache, so it stays bounded.
    holdout_exposed: MapSet.new(),
    # The variant, covering holdouts and arms an override was last read with,
    # by experiment name: overrides are not cached, so this stands in for the
    # overridden assignment the JavaScript SDK pins.
    override_snapshots: %{},
    # Names exposed only by a read while absent from the data: that
    # placeholder never stands in for a covered experiment's exposures.
    placeholder_exposed: MapSet.new()
  ]

  def child_spec(opts) do
    shutdown =
      case opts do
        [%{} = sdk_config | _] -> shutdown_timeout(sdk_config)
        _ -> 5_000
      end

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker,
      restart: :temporary,
      shutdown: shutdown
    }
  end

  def start_link(sdk_config, data, context_config, opts \\ []) do
    data_fetcher = Keyword.get(opts, :data_fetcher)

    with {:ok, units} <- normalize_initial_units(context_config.units) do
      GenServer.start_link(
        __MODULE__,
        {sdk_config, data, %{context_config | units: units}, data_fetcher}
      )
    end
  end

  def start_link_async(sdk_config, context_config, opts \\ []) do
    data_fetcher = Keyword.get(opts, :data_fetcher)

    with {:ok, units} <- normalize_initial_units(context_config.units) do
      GenServer.start_link(
        __MODULE__,
        {:async, sdk_config, %{context_config | units: units}, data_fetcher}
      )
    end
  end

  defp normalize_initial_units(nil), do: {:ok, %{}}

  defp normalize_initial_units(units) when is_map(units) do
    Enum.reduce_while(units, {:ok, %{}}, fn
      {_type, nil}, acc ->
        {:cont, acc}

      {type, uid}, {:ok, normalized} ->
        type = to_string(type)

        case validate_uid_or_error(uid, type) do
          {:ok, uid} -> {:cont, {:ok, Map.put(normalized, type, uid)}}
          error -> {:halt, error}
        end
    end)
  end

  def set_data(context, data) do
    GenServer.call(context, {:set_data, data})
  end

  def set_failed(context, reason) do
    GenServer.call(context, {:set_failed, reason})
  end

  def ready_error(context) do
    GenServer.call(context, :ready_error)
  end

  def wait_until_ready(context, timeout \\ 5000) do
    GenServer.call(context, :wait_until_ready, timeout)
  end

  def set_unit(context, unit_type, uid) do
    GenServer.call(context, {:set_unit, unit_type, uid})
  end

  def set_units(context, units) when is_map(units) do
    GenServer.call(context, {:set_units, units})
  end

  def get_unit(context, unit_type) do
    GenServer.call(context, {:get_unit, unit_type})
  end

  def get_units(context) do
    GenServer.call(context, :get_units)
  end

  def set_attribute(context, name, value) do
    GenServer.call(context, {:set_attribute, name, value})
  end

  def set_attributes(context, attributes) when is_map(attributes) or is_list(attributes) do
    GenServer.call(context, {:set_attributes, attributes})
  end

  def get_attribute(context, name) do
    GenServer.call(context, {:get_attribute, name})
  end

  def get_attributes(context) do
    GenServer.call(context, :get_attributes)
  end

  def set_override(context, experiment_name, variant) do
    GenServer.call(context, {:set_override, experiment_name, variant})
  end

  def set_overrides(context, overrides) when is_map(overrides) do
    GenServer.call(context, {:set_overrides, overrides})
  end

  def set_custom_assignment(context, experiment_name, variant) do
    GenServer.call(context, {:set_custom_assignment, experiment_name, variant})
  end

  def set_custom_assignments(context, assignments) when is_map(assignments) do
    GenServer.call(context, {:set_custom_assignments, assignments})
  end

  def treatment(context, experiment_name) do
    GenServer.call(context, {:treatment, experiment_name})
  end

  def peek(context, experiment_name) do
    GenServer.call(context, {:peek, experiment_name})
  end

  def variable_value(context, key, default_value \\ nil) do
    GenServer.call(context, {:variable_value, key, default_value})
  end

  def peek_variable_value(context, key, default_value \\ nil) do
    GenServer.call(context, {:peek_variable_value, key, default_value})
  end

  def variable_keys(context) do
    GenServer.call(context, :variable_keys)
  end

  def custom_field_value(context, experiment_name, field_name) do
    GenServer.call(context, {:custom_field_value, experiment_name, field_name})
  end

  def custom_field_keys(context) do
    GenServer.call(context, :custom_field_keys)
  end

  def custom_field_value_type(context, experiment_name, field_name) do
    GenServer.call(context, {:custom_field_value_type, experiment_name, field_name})
  end

  def track(context, goal_name, properties \\ nil) do
    GenServer.call(context, {:track, goal_name, properties})
  end

  def publish(context) do
    GenServer.call(context, :publish, :infinity)
  end

  def finalize(context) do
    GenServer.call(context, :finalize, :infinity)
  end

  def close(context) do
    finalize(context)
  end

  @doc """
  Finalizes the context and then stops its process, releasing the supervised
  process and everything it retains (data, attributes, assignment caches).

  Use this at the end of a request/session lifecycle. Disposal always releases
  the process: if the final publish keeps failing, it is retried up to
  `:attempts` times (default 3, with `:backoff` ms between attempts, default
  100), after which the unpublished events are discarded, the process is
  stopped anyway and `{:error, {:disposed_unpublished, reason}}` is
  returned so the caller can observe that events were not delivered. Returns
  `:ok` when everything was published.

  After `dispose/1` the pid is dead, so inspection helpers such as
  `is_finalized?/1` must be called before it.
  """
  def dispose(context, opts \\ []) do
    attempts = max(Keyword.get(opts, :attempts, 3), 1)
    backoff = Keyword.get(opts, :backoff, 100)

    result = finalize_with_retries(context, attempts, backoff)

    # Events that could not be published are dropped (and reported below) so the
    # termination hook makes no further, unbounded publisher call.
    if result != :ok do
      try do
        GenServer.call(context, :discard_pending, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    try do
      GenServer.stop(context, :normal)
    catch
      :exit, _ -> :ok
    end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:disposed_unpublished, reason}}
    end
  end

  defp finalize_with_retries(context, attempts, backoff) do
    case finalize(context) do
      :ok ->
        :ok

      {:error, _reason} = error when attempts <= 1 ->
        error

      {:error, _reason} ->
        Process.sleep(backoff)
        finalize_with_retries(context, attempts - 1, backoff)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  def refresh(context) do
    GenServer.call(context, :refresh, :infinity)
  end

  def refresh(context, new_data) do
    GenServer.call(context, {:refresh, new_data})
  end

  def is_ready?(context) do
    GenServer.call(context, :is_ready)
  end

  def is_failed?(context) do
    GenServer.call(context, :is_failed)
  end

  def is_finalized?(context) do
    GenServer.call(context, :is_finalized)
  end

  def is_finalizing?(context) do
    GenServer.call(context, :is_finalizing)
  end

  def is_closed?(context) do
    is_finalized?(context)
  end

  def is_closing?(context) do
    is_finalizing?(context)
  end

  def pending(context) do
    GenServer.call(context, :pending)
  end

  def data(context) do
    GenServer.call(context, :data)
  end

  def experiments(context) do
    GenServer.call(context, :experiments)
  end

  @impl true
  def init({:async, sdk_config, context_config}) do
    init({:async, sdk_config, context_config, nil})
  end

  def init({:async, sdk_config, context_config, data_fetcher}) do
    # Trap exits so supervisor-driven shutdown runs terminate/2 (pending-event publish).
    Process.flag(:trap_exit, true)
    state = initial_state(sdk_config, context_config, data_fetcher)
    {:ok, state, {:continue, :fetch_async}}
  end

  @impl true
  def init({sdk_config, data, context_config}) do
    init({sdk_config, data, context_config, nil})
  end

  def init({sdk_config, data, context_config, data_fetcher}) do
    Process.flag(:trap_exit, true)
    state = initial_state(sdk_config, context_config, data_fetcher) |> mark_ready(data)
    Logger.info("Context initialized successfully")
    {:ok, state}
  end

  defp initial_state(sdk_config, context_config, data_fetcher) do
    %__MODULE__{
      sdk_config: sdk_config,
      data: %Types.ContextData{experiments: []},
      ready: false,
      failed: false,
      failed_reason: nil,
      finalized: false,
      finalizing: false,
      units: context_config.units,
      attributes: config_attributes_to_list(context_config.attributes),
      overrides: context_config.overrides,
      custom_assignments: context_config.custom_assignments,
      assignments: %{},
      exposures: [],
      goals: [],
      variable_index: %{},
      experiment_index: %{},
      event_handler: context_config.event_handler,
      exposed_experiments: MapSet.new(),
      audience_cache: %{},
      rules_cache: %{},
      data_fetcher: data_fetcher,
      pending_waiters: [],
      exposure_count: 0,
      goal_count: 0
    }
  end

  @impl true
  def handle_continue(:fetch_async, state) do
    # Fetch context data off the GenServer process so the context stays
    # responsive (set_unit/set_attribute/set_failed/wait_until_ready) while the
    # request is in flight, mirroring the future/callback model of the other SDKs.
    server = self()
    spawn(fn -> send(server, {:fetch_async_complete, fetch_data(state)}) end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:fetch_async_complete, _result}, %{ready: true} = state), do: {:noreply, state}

  def handle_info({:fetch_async_complete, _result}, %{failed: true} = state),
    do: {:noreply, state}

  def handle_info({:fetch_async_complete, {:ok, data}}, state) do
    case safe_context_data_with_indexes(data) do
      {:ok, context_data, indexes} -> {:noreply, mark_ready(state, context_data, indexes)}
      {:error, reason} -> handle_info({:fetch_async_complete, {:error, reason}}, state)
    end
  end

  def handle_info({:fetch_async_complete, {:error, reason}}, state) do
    {:noreply, mark_failed(state, reason)}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("Context received EXIT signal: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Context received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Converts raw context data and builds indexes so schema-invalid nested fields
  # are reported before committing a new context state.
  defp safe_context_data_with_indexes(data) do
    context_data = Types.ContextData.from_map(data)
    {:ok, context_data, build_indexes(context_data.experiments)}
  rescue
    exception -> {:error, "Invalid context data: " <> Exception.message(exception)}
  end

  @doc false
  def safe_context_data(data) do
    case safe_context_data_with_indexes(data) do
      {:ok, context_data, _indexes} -> {:ok, context_data}
      error -> error
    end
  end

  defp mark_ready(state, context_data, indexes \\ nil) do
    {var_index, exp_index, aud_cache, rules_cache} =
      indexes || build_indexes(context_data.experiments)

    experiment_holdouts = build_holdout_index(context_data)

    state = %{
      state
      | data: context_data,
        ready: true,
        variable_index: var_index,
        experiment_index: exp_index,
        audience_cache: aud_cache,
        rules_cache: rules_cache,
        experiment_holdouts: experiment_holdouts
    }

    state = prune_holdout_exposed(state)

    # Emit before waking waiters so the event is observable once
    # wait_until_ready/2 returns.
    emit_event(state, :ready, %{experiments: context_data.experiments})

    for waiter <- state.pending_waiters do
      GenServer.reply(waiter, :ok)
    end

    %{state | pending_waiters: []}
  end

  @impl true
  def handle_call({:set_data, data}, _from, state) do
    context_data = Types.ContextData.from_map(data)
    {:reply, :ok, mark_ready(state, context_data)}
  end

  @impl true
  def handle_call({:set_failed, reason}, _from, state) do
    {:reply, :ok, mark_failed(state, reason)}
  end

  @impl true
  def handle_call(:ready_error, _from, state) do
    {:reply, state.failed_reason, state}
  end

  @impl true
  def handle_call(:wait_until_ready, from, state) do
    cond do
      state.failed ->
        {:reply, {:error, state.failed_reason}, state}

      state.ready ->
        {:reply, :ok, state}

      true ->
        {:noreply, %{state | pending_waiters: [from | state.pending_waiters]}}
    end
  end

  @impl true
  def handle_call({:set_unit, unit_type, uid}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      key = to_string(unit_type)

      case validate_uid_or_error(uid, key) do
        {:error, msg} ->
          {:reply, {:error, msg}, state}

        {:ok, uid_str} ->
          if Map.has_key?(state.units, key) && Map.get(state.units, key) != uid_str do
            {:reply, {:error, "Unit '#{key}' UID already set."}, state}
          else
            added = if Map.has_key?(state.units, key), do: [], else: [key]
            state = %{state | units: Map.put(state.units, key, uid_str)}
            {:reply, :ok, invalidate_rules_missing_unit(state, added)}
          end
      end
    end
  end

  @impl true
  def handle_call({:set_units, units}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      try do
        new_units =
          Enum.reduce(units, state.units, fn {unit_type, uid}, acc ->
            key = to_string(unit_type)

            uid_str =
              case validate_uid_or_error(uid, key) do
                {:error, msg} -> throw({:validation_error, msg})
                {:ok, str} -> str
              end

            if Map.has_key?(acc, key) && Map.get(acc, key) != uid_str do
              throw({:duplicate_unit, key})
            end

            Map.put(acc, key, uid_str)
          end)

        added = Map.keys(new_units) -- Map.keys(state.units)
        state = %{state | units: new_units}
        {:reply, :ok, invalidate_rules_missing_unit(state, added)}
      catch
        {:duplicate_unit, key} ->
          {:reply, {:error, "Unit '#{key}' UID already set."}, state}

        {:validation_error, msg} ->
          {:reply, {:error, msg}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_unit, unit_type}, _from, state) do
    value = Map.get(state.units, to_string(unit_type))
    {:reply, value, state}
  end

  @impl true
  def handle_call(:get_units, _from, state) do
    {:reply, state.units, state}
  end

  @impl true
  def handle_call({:set_attribute, _name, _value}, _from, %{finalized: true} = state) do
    {:reply, {:error, "ABsmartly Context is finalized."}, state}
  end

  def handle_call({:set_attribute, name, value}, _from, state) do
    name_str = to_string(name)
    entry = %{name: name_str, value: value, set_at: now_millis()}
    state = %{state | attributes: state.attributes ++ [entry], attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_attributes, _attributes}, _from, %{finalized: true} = state) do
    {:reply, {:error, "ABsmartly Context is finalized."}, state}
  end

  def handle_call({:set_attributes, attributes}, _from, state) do
    set_at = now_millis()

    new_entries =
      Enum.map(attributes, fn {name, value} ->
        %{name: to_string(name), value: value, set_at: set_at}
      end)

    state = %{state | attributes: state.attributes ++ new_entries, attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_attribute, name}, _from, state) do
    name_str = to_string(name)

    value =
      Enum.reduce(state.attributes, nil, fn attr, last ->
        if attr.name == name_str, do: attr.value, else: last
      end)

    {:reply, value, state}
  end

  @impl true
  def handle_call(:get_attributes, _from, state) do
    {:reply, state.attributes, state}
  end

  @impl true
  def handle_call({:set_override, experiment_name, variant}, _from, state) do
    name = to_string(experiment_name)

    state = %{
      state
      | overrides: Map.put(state.overrides, name, variant),
        exposed_experiments: MapSet.delete(state.exposed_experiments, name)
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_overrides, overrides}, _from, state) do
    {new_overrides, new_exposed} =
      Enum.reduce(overrides, {state.overrides, state.exposed_experiments}, fn {experiment_name,
                                                                               variant},
                                                                              {ov_acc, exp_acc} ->
        name = to_string(experiment_name)
        {Map.put(ov_acc, name, variant), MapSet.delete(exp_acc, name)}
      end)

    state = %{state | overrides: new_overrides, exposed_experiments: new_exposed}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_custom_assignment, experiment_name, variant}, _from, state) do
    name = to_string(experiment_name)

    state = %{
      state
      | custom_assignments: Map.put(state.custom_assignments, name, variant),
        exposed_experiments: reset_exposed_for_custom(state, state.exposed_experiments, name)
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_custom_assignments, assignments}, _from, state) do
    {new_assignments, new_exposed} =
      Enum.reduce(
        assignments,
        {state.custom_assignments, state.exposed_experiments},
        fn {experiment_name, variant}, {ca_acc, exp_acc} ->
          name = to_string(experiment_name)
          {Map.put(ca_acc, name, variant), reset_exposed_for_custom(state, exp_acc, name)}
        end
      )

    {:reply, :ok,
     %{state | custom_assignments: new_assignments, exposed_experiments: new_exposed}}
  end

  @impl true
  def handle_call({:treatment, experiment_name}, _from, state) do
    with_ready(state, true, fn ->
      do_treatment(state, experiment_name, true)
    end)
  end

  @impl true
  def handle_call({:peek, experiment_name}, _from, state) do
    with_ready(state, true, fn ->
      do_treatment(state, experiment_name, false)
    end)
  end

  @impl true
  def handle_call({:variable_value, key, default_value}, _from, state) do
    with_ready(state, true, fn ->
      do_variable_value(state, key, default_value, true)
    end)
  end

  @impl true
  def handle_call({:peek_variable_value, key, default_value}, _from, state) do
    with_ready(state, true, fn ->
      do_variable_value(state, key, default_value, false)
    end)
  end

  @impl true
  def handle_call(:variable_keys, _from, state) do
    with_ready(state, true, fn ->
      result =
        Map.new(state.variable_index, fn {key, experiments} ->
          {key, Enum.map(experiments, & &1.name)}
        end)

      {result, state}
    end)
  end

  @impl true
  def handle_call({:custom_field_value, experiment_name, field_name}, _from, state) do
    with_ready(state, true, fn ->
      {do_custom_field_value(state, experiment_name, field_name), state}
    end)
  end

  @impl true
  def handle_call(:custom_field_keys, _from, state) do
    with_ready(state, true, fn -> {do_custom_field_keys(state), state} end)
  end

  @impl true
  def handle_call({:custom_field_value_type, experiment_name, field_name}, _from, state) do
    with_ready(state, true, fn ->
      {do_custom_field_value_type(state, experiment_name, field_name), state}
    end)
  end

  @impl true
  def handle_call({:track, goal_name, properties}, _from, state) do
    cond do
      state.finalized ->
        {:reply, {:error, "ABsmartly Context is finalized."}, state}

      not (is_nil(properties) or Utils.object?(properties)) ->
        {:reply, {:error, "Goal '#{goal_name}' properties must be of type object."}, state}

      true ->
        {:reply, :ok, do_track(state, goal_name, properties)}
    end
  end

  @impl true
  def handle_call(:publish, _from, state) do
    with_ready(state, true, fn -> do_publish(state) end)
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    if state.finalized or state.finalizing do
      {:reply, :ok, state}
    else
      case do_publish(%{state | finalizing: true}) do
        {:ok, new_state} ->
          new_state = %{new_state | finalized: true, finalizing: false}
          emit_event(new_state, :finalize, nil)
          {:reply, :ok, new_state}

        # The context stays open with its events queued, so finalize/1 can be
        # retried.
        {{:error, _reason} = error, new_state} ->
          {:reply, error, %{new_state | finalizing: false}}
      end
    end
  end

  @impl true
  def handle_call(:discard_pending, _from, state) do
    {:reply, :ok, %{state | exposures: [], goals: []}}
  end

  # Like the JavaScript SDK, refreshing a context whose data failed to load is a
  # successful no-op: a failed context is never recovered by a refresh.
  @impl true
  def handle_call(:refresh, _from, state) do
    case check_ready(state, true) do
      :ok when state.failed ->
        {:reply, :ok, state}

      :ok ->
        case run_fetch(state) do
          {:ok, new_data} ->
            handle_call({:refresh, new_data}, nil, state)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:refresh, new_data}, _from, state) do
    case check_ready(state, true) do
      :ok when state.failed ->
        {:reply, :ok, state}

      :ok ->
        apply_refresh(state, new_data)

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:is_ready, _from, state) do
    {:reply, state.ready, state}
  end

  @impl true
  def handle_call(:is_failed, _from, state) do
    {:reply, state.failed, state}
  end

  @impl true
  def handle_call(:is_finalized, _from, state) do
    {:reply, state.finalized, state}
  end

  @impl true
  def handle_call(:is_finalizing, _from, state) do
    {:reply, state.finalizing, state}
  end

  @impl true
  def handle_call(:pending, _from, state) do
    {:reply, state.exposure_count + state.goal_count, state}
  end

  @impl true
  def handle_call(:data, _from, state) do
    case check_ready(state, false) do
      :ok -> {:reply, state.data, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:experiments, _from, state) do
    case check_ready(state, false) do
      :ok -> {:reply, Enum.map(state.data.experiments, & &1.name), state}
      error -> {:reply, error, state}
    end
  end

  defp apply_refresh(state, new_data) do
    context_data =
      if match?(%Types.ContextData{}, new_data),
        do: new_data,
        else: Types.ContextData.from_map(new_data)

    indexes = build_indexes(context_data.experiments)
    {:reply, :ok, do_refresh(state, context_data, indexes)}
  rescue
    exception ->
      {:reply, {:error, "Invalid context data: " <> Exception.message(exception)}, state}
  end

  # Mirrors the JavaScript SDK's `_checkReady(expectNotFinalized)`: reads before
  # the context data has settled (loaded or failed) return a "not yet ready"
  # error, and reads after finalize (or while finalizing) return a finalized
  # error. A failed context counts as ready and reads from its empty data.
  defp check_ready(state, expect_not_finalized) do
    cond do
      not (state.ready or state.failed) -> {:error, "ABsmartly Context is not yet ready."}
      expect_not_finalized and state.finalized -> {:error, "ABsmartly Context is finalized."}
      expect_not_finalized and state.finalizing -> {:error, "ABsmartly Context is finalizing."}
      true -> :ok
    end
  end

  defp with_ready(state, expect_not_finalized, fun) do
    case check_ready(state, expect_not_finalized) do
      :ok ->
        {result, state} = fun.()
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Context terminating: #{inspect(reason)}")

    if state.exposures != [] or state.goals != [] do
      Logger.info("Context terminating with pending data, attempting final publish")
      do_publish_sync(state)
    end

    :ok
  end

  # Mirrors the JavaScript SDK's `unit()`: string UIDs are trimmed and must not
  # be blank, numbers are kept as numbers, anything else is rejected.
  defp validate_uid_or_error(uid, unit_type) when is_binary(uid) do
    uid = String.trim(uid)

    cond do
      uid == "" ->
        {:error, "Unit '#{unit_type}' UID must not be blank."}

      String.length(uid) > @max_uid_length ->
        {:error, "Unit ID exceeds maximum length of #{@max_uid_length}"}

      true ->
        {:ok, uid}
    end
  end

  defp validate_uid_or_error(uid, _unit_type) when is_number(uid), do: {:ok, uid}

  defp validate_uid_or_error(_uid, unit_type),
    do: {:error, "Unit '#{unit_type}' must be a string or a number."}

  defp config_attributes_to_list(nil), do: []

  defp config_attributes_to_list(attrs) when is_map(attrs) do
    set_at = now_millis()

    Enum.map(attrs, fn {name, value} ->
      %{name: to_string(name), value: value, set_at: set_at}
    end)
  end

  defp config_attributes_to_list(attrs) when is_list(attrs) do
    set_at = now_millis()

    Enum.flat_map(attrs, fn
      %{"name" => name, "value" => value} -> [%{name: name, value: value, set_at: set_at}]
      {name, value} -> [%{name: to_string(name), value: value, set_at: set_at}]
      _ -> []
    end)
  end

  defp do_treatment(state, experiment_name, queue_exposure) do
    override = Map.get(state.overrides, experiment_name)
    experiment = Map.get(state.experiment_index, experiment_name)

    case {experiment, override} do
      {nil, nil} when is_map_key(state.assignments, experiment_name) ->
        cached = Map.fetch!(state.assignments, experiment_name)

        if saved_unassigned_holdout?(cached) do
          state =
            if queue_exposure and not cached.holdout_exposed do
              if cached.suppressed do
                state = mark_holdout_exposed(state, experiment_name, cached)
                queue_holdout_exposures(state, cached.holdout_arms)
              else
                saved = %{
                  id: cached.id,
                  name: experiment_name,
                  unit_type: cached.holdout_unit_type
                }

                expose(state, experiment_name, saved, cached)
              end
            else
              state
            end

          {cached.variant, state}
        else
          do_treatment_for_unknown(state, experiment_name, queue_exposure)
        end

      {exp, _} when not is_nil(exp) ->
        do_treatment_for_experiment(state, experiment_name, exp, queue_exposure)

      {nil, ov} when not is_nil(ov) ->
        do_treatment_for_override(state, experiment_name, ov, queue_exposure)

      {nil, nil} ->
        do_treatment_for_unknown(state, experiment_name, queue_exposure)
    end
  end

  defp do_treatment_for_experiment(state, experiment_name, experiment, queue_exposure) do
    {assignment, state} = get_or_assign(state, experiment)

    state =
      if queue_exposure,
        do: expose(state, experiment_name, experiment, assignment),
        else: state

    {assignment.variant, state}
  end

  # Mirrors the JavaScript SDK's `_treatment`/`_triggerExposures`: the first
  # exposing read of an experiment queues its own exposure, unless a holdout
  # suppressed it, and then the exposure of each holdout covering it that was
  # not exposed yet, in holdout id order.
  defp expose(state, experiment_name, experiment, assignment) do
    if MapSet.member?(state.exposed_experiments, experiment_name) and
         not placeholder_only?(state, experiment_name, assignment) do
      state
    else
      state = %{
        state
        | exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name),
          placeholder_exposed: MapSet.delete(state.placeholder_exposed, experiment_name)
      }

      # An override's exposure is not the decision underneath it.
      state = if assignment.overridden, do: state, else: pin_exposed(state, experiment_name)

      state =
        if assignment.suppressed and not assignment.overridden and not assignment.rule_override,
          do: state,
          else: enqueue_exposure(state, create_exposure(experiment, assignment))

      state
      |> mark_holdout_exposed(experiment_name, assignment)
      |> queue_holdout_exposures(assignment.holdout_arms)
    end
  end

  # Like the JavaScript SDK's per-assignment `exposed` flag: set_unit never
  # re-resolves a covered decision once it was really exposed, whatever later
  # clears the name's exposure marker (a custom write, a refresh).
  defp mark_holdout_exposed(state, name, %{holdout_key: [_ | _], overridden: false}) do
    case Map.get(state.assignments, name) do
      %Types.Assignment{holdout_exposed: false} = cached ->
        %{
          state
          | assignments: Map.put(state.assignments, name, %{cached | holdout_exposed: true})
        }

      _ ->
        state
    end
  end

  defp mark_holdout_exposed(state, _name, _assignment), do: state

  # A covered experiment whose only exposure is a placeholder from a read while
  # it was absent is exposed with its holdouts at its first real read.
  defp placeholder_only?(state, name, assignment),
    do: assignment.holdout_key != nil and MapSet.member?(state.placeholder_exposed, name)

  defp do_treatment_for_override(state, experiment_name, override, queue_exposure) do
    state =
      if queue_exposure and not MapSet.member?(state.exposed_experiments, experiment_name) do
        exposure = %Types.Exposure{
          id: 0,
          name: experiment_name,
          unit: nil,
          variant: override || 0,
          exposed_at: now_millis(),
          assigned: false,
          eligible: true,
          overridden: override != nil,
          full_on: false,
          custom: false,
          audience_mismatch: false,
          rule_override: false
        }

        state = %{
          state
          | exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name),
            placeholder_exposed: MapSet.put(state.placeholder_exposed, experiment_name)
        }

        enqueue_exposure(state, exposure)
      else
        state
      end

    {override || 0, state}
  end

  defp do_treatment_for_unknown(state, experiment_name, queue_exposure),
    do: do_treatment_for_override(state, experiment_name, nil, queue_exposure)

  defp enqueue_exposure(state, exposure) do
    state =
      if state.exposure_count >= @max_queue_size do
        Logger.error("Exposure queue size limit reached (#{@max_queue_size}), dropping oldest")

        %{
          state
          | exposures: Enum.drop(state.exposures, -1),
            exposure_count: state.exposure_count - 1
        }
      else
        state
      end

    state = %{
      state
      | exposures: [exposure | state.exposures],
        exposure_count: state.exposure_count + 1
    }

    emit_event(state, :exposure, exposure)
    state
  end

  # Mirrors the Java SDK's `getVariableAssignment`. The candidates are the
  # experiments whose variants define the key, by id ascending; the winner is
  # the first the unit is assigned to, overridden into or given by a rule. A
  # held-out candidate never wins over one of those, but the first one is the
  # winner (for its control value) when none qualifies. The winner's variant
  # supplies the value, or the default when it lacks the key: the arm a unit
  # got never passes the key on to a later candidate. Only the winner is
  # exposed. On an exposing read every candidate checked, the winner included,
  # first fires the holdouts covering it, as in Java, so a covered winner's
  # holdout exposures come before its own. A peek exposes nothing.
  defp do_variable_value(state, key, default_value, queue_exposure) do
    {winner, state} =
      variable_winner(state, Map.get(state.variable_index, key, []), queue_exposure)

    case winner do
      nil ->
        {default_value, state}

      {exp, assignment} ->
        state =
          if queue_exposure,
            do: expose(state, exp.name, exp, assignment),
            else: state

        case variant_config(exp, assignment) do
          %{^key => value} -> {value, state}
          _ -> {default_value, state}
        end
    end
  end

  defp variable_winner(state, experiments, queue_exposure) do
    Enum.reduce_while(experiments, {nil, state}, fn exp, {fallback, acc} ->
      {assignment, acc} = get_or_assign(acc, exp)

      acc = mark_variable_unassigned(acc, exp, assignment)

      acc =
        if queue_exposure,
          do: queue_holdout_exposures(acc, assignment.holdout_arms),
          else: acc

      cond do
        assignment.assigned || assignment.overridden || assignment.rule_override ->
          {:halt, {{exp, assignment}, acc}}

        assignment.suppressed and fallback == nil ->
          {:cont, {{exp, assignment}, acc}}

        true ->
          {:cont, {fallback, acc}}
      end
    end)
  end

  # A candidate passed over because its unit is missing is decided again once
  # that unit is set, unless it was ever exposed: only the winner is exposed,
  # so an unexposed loser's provisional control must not stick after login. A
  # decision cached while the unit was already set is left as it is.
  defp mark_variable_unassigned(state, experiment, assignment) do
    if assignment.variable_unassigned or assignment.exposed or
         not unit_missing?(state, experiment, assignment) do
      state
    else
      updated = %{assignment | variable_unassigned: true}
      %{state | assignments: Map.put(state.assignments, experiment.name, updated)}
    end
  end

  defp unit_missing?(state, experiment, assignment) do
    not (assignment.assigned or assignment.overridden or assignment.rule_override) and
      not Map.has_key?(state.units, unit_type(experiment))
  end

  # The cached decision stays what the user saw, even when a later write (a
  # custom assignment) clears the exposed marker.
  defp pin_exposed(state, name) do
    case Map.get(state.assignments, name) do
      %Types.Assignment{exposed: false} = cached ->
        pinned = %{cached | exposed: true, variable_unassigned: false}
        %{state | assignments: Map.put(state.assignments, name, pinned)}

      _ ->
        state
    end
  end

  defp variant_config(experiment, assignment) do
    case Enum.at(experiment.variants, assignment.variant) do
      nil -> nil
      variant_data -> parse_variant_config(variant_data["config"])
    end
  end

  defp parse_variant_config(nil), do: nil
  defp parse_variant_config(config) when is_map(config), do: config

  defp parse_variant_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      {:ok, decoded} ->
        Logger.warning("Variant config decoded but not a map: #{inspect(decoded)}")
        nil

      {:error, error} ->
        Logger.error("Failed to parse variant config JSON: #{inspect(error)}, config: #{config}")

        nil
    end
  end

  defp parse_variant_config(_), do: nil

  defp find_custom_field(state, experiment_name, field_name) do
    experiment = Map.get(state.experiment_index, experiment_name)

    if experiment,
      do: Enum.find(experiment.custom_field_values || [], &(&1["name"] == field_name))
  end

  defp do_custom_field_value(state, experiment_name, field_name) do
    if field = find_custom_field(state, experiment_name, field_name) do
      parse_custom_field(field["value"], field["type"])
    end
  end

  defp do_custom_field_keys(state) do
    state.experiment_index
    |> Map.values()
    |> Enum.flat_map(fn experiment ->
      if experiment.custom_field_values do
        Enum.map(experiment.custom_field_values, & &1["name"])
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp do_custom_field_value_type(state, experiment_name, field_name) do
    if field = find_custom_field(state, experiment_name, field_name), do: field["type"]
  end

  defp parse_custom_field(value, "string"), do: value
  defp parse_custom_field(value, "text"), do: value
  defp parse_custom_field(value, "number"), do: Utils.to_number(value)
  defp parse_custom_field(value, "boolean"), do: value == "true" or value == true

  defp parse_custom_field(value, "json") when not is_binary(value), do: nil

  defp parse_custom_field(value, "json") do
    case Jason.decode(value) do
      {:ok, decoded} ->
        decoded

      {:error, error} ->
        Logger.error("Failed to parse custom field JSON: #{inspect(error)}, value: #{value}")

        nil
    end
  end

  defp parse_custom_field(value, _type), do: value

  defp do_track(state, goal_name, properties) do
    goal = %Types.Goal{
      name: goal_name,
      achieved_at: now_millis(),
      properties: properties
    }

    state =
      if state.goal_count >= @max_queue_size do
        Logger.error("Goal queue size limit reached (#{@max_queue_size}), dropping oldest")
        %{state | goals: Enum.drop(state.goals, -1), goal_count: state.goal_count - 1}
      else
        state
      end

    state = %{state | goals: [goal | state.goals], goal_count: state.goal_count + 1}
    emit_event(state, :goal, goal)
    state
  end

  # Sends the queued exposures and goals to the publisher. The queues are only
  # cleared once the publisher accepts them; on any failure they are kept for
  # the next publish/finalize, an `:error` event is emitted and
  # `{:error, reason}` is returned. The `:publish` event is emitted only after
  # the publisher succeeds.
  #
  # The GenServer is blocked for the duration of the call, so no events can be
  # queued in between and the state can be used as-is on either outcome.
  defp do_publish(state) do
    if state.exposures != [] or state.goals != [] do
      event_map = build_publish_event_map(state)

      case run_publisher(state, event_map) do
        :ok ->
          Logger.info(
            "Successfully published #{state.exposure_count} exposures and #{state.goal_count} goals"
          )

          emit_event(state, :publish, event_map)
          {:ok, %{state | exposures: [], goals: [], exposure_count: 0, goal_count: 0}}

        {:error, reason} ->
          Logger.error("Failed to publish events, keeping them queued: #{inspect(reason)}")
          emit_event(state, :error, reason)
          {{:error, reason}, state}
      end
    else
      {:ok, state}
    end
  end

  @doc """
  Supervisor shutdown budget (ms) so a context can finish its bounded final publish.
  """
  def shutdown_timeout(sdk_config) do
    publisher = Map.get(sdk_config, :publisher) || ABSmartly.DefaultContextPublisher
    capped = Map.put(sdk_config, :retries, min(Map.get(sdk_config, :retries) || 0, 1))
    publish_deadline(capped, publisher) + 2_000
  end

  # Worst case for the default HTTP publisher: every attempt may spend the
  # connect plus receive timeout, plus the exponential backoff between attempts.
  defp publish_deadline(sdk_config) do
    HTTP.Client.request_deadline(
      Map.get(sdk_config, :timeout) || 30_000,
      Map.get(sdk_config, :retries) || 0
    )
  end

  # Custom publishers that only implement publish/6 carry no timeout budget, so
  # keep the historical 5s floor for them; the HTTP-derived deadline is a floor too.
  defp publish_deadline(sdk_config, publisher) do
    Code.ensure_loaded(publisher)
    derived = publish_deadline(sdk_config)

    if function_exported?(publisher, :publish, 7), do: derived, else: max(derived, 5_000)
  end

  defp call_publisher(publisher, c, event_map) do
    Code.ensure_loaded(publisher)

    if function_exported?(publisher, :publish, 7) do
      publisher.publish(
        c.endpoint,
        c.api_key,
        c.application,
        c.environment,
        event_map,
        c.retries,
        c.timeout
      )
    else
      publisher.publish(c.endpoint, c.api_key, c.application, c.environment, event_map, c.retries)
    end
  end

  # Runs the refresh fetch in a task so the context can still react to the
  # supervisor's shutdown signal while HTTP retries/backoff are in progress.
  defp fetch_data(state) do
    if state.data_fetcher do
      state.data_fetcher.()
    else
      HTTP.Client.fetch_context(
        state.sdk_config.endpoint,
        state.sdk_config.api_key,
        state.sdk_config.application,
        state.sdk_config.environment,
        state.sdk_config.retries,
        state.sdk_config.timeout
      )
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_fetch(state) do
    task = Task.async(fn -> fetch_data(state) end)

    case await_task(task, publish_deadline(state.sdk_config)) do
      {:ok, {:ok, _} = ok} -> ok
      {:ok, {:error, _} = error} -> error
      {:ok, other} -> {:error, {:unexpected_fetch_result, other}}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, "Context refresh timed out"}
    end
  end

  defp run_publisher(state, event_map) do
    publisher = Map.get(state.sdk_config, :publisher, ABSmartly.DefaultContextPublisher)

    task =
      Task.async(fn ->
        try do
          call_publisher(publisher, state.sdk_config, event_map)
        rescue
          exception -> {:error, Exception.message(exception)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    await_publisher(task, publish_deadline(state.sdk_config, publisher))
  end

  # Waits for the task, but also reacts to the supervisor's shutdown signal (we
  # trap exits) so in-flight work cannot outlive the child shutdown budget: the
  # task is killed and the shutdown reason is re-raised so terminate/2 runs its
  # bounded final publish.
  defp await_task(%Task{ref: ref, pid: task_pid} = task, timeout) do
    parent = parent_pid()

    result =
      receive do
        {^ref, result} ->
          Process.demonitor(ref, [:flush])
          {:ok, result}

        {:DOWN, ^ref, _, _, reason} ->
          {:exit, reason}

        {:EXIT, ^parent, reason} when parent != nil ->
          Task.shutdown(task, :brutal_kill)
          exit(reason)
      after
        timeout -> Task.shutdown(task, :brutal_kill)
      end

    flush_task_exit(task_pid)
    result
  end

  defp await_publisher(task, timeout) do
    case await_task(task, timeout) do
      {:ok, result} -> normalize_publish_result(result)
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, "Publish timed out"}
    end
  end

  defp normalize_publish_result(:ok), do: :ok
  defp normalize_publish_result({:error, _reason} = error), do: error
  defp normalize_publish_result(other), do: {:error, {:unexpected_publisher_result, other}}

  defp flush_task_exit(task_pid) do
    receive do
      {:EXIT, ^task_pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp parent_pid do
    case Process.get(:"$ancestors") do
      [parent | _] when is_pid(parent) -> parent
      [name | _] when is_atom(name) -> Process.whereis(name)
      _ -> nil
    end
  end

  defp do_publish_sync(state) do
    if state.exposures != [] or state.goals != [] do
      event_map = build_publish_event_map(state)

      sync_state = %{
        state
        | sdk_config: %{state.sdk_config | retries: min(state.sdk_config.retries, 1)}
      }

      case run_publisher(sync_state, event_map) do
        :ok ->
          Logger.info("Successfully published pending data on terminate")

        {:error, reason} ->
          Logger.error("Failed to publish on terminate: #{inspect(reason)}")
      end
    end
  end

  defp build_publish_event_map(state) do
    hashed_units =
      Enum.map(state.units, fn {unit_type, uid} ->
        %{
          "type" => unit_type,
          "uid" => Utils.hash_unit(uid)
        }
      end)

    attrs_list =
      Enum.map(state.attributes, fn attr ->
        %{"name" => attr.name, "value" => attr.value, "setAt" => attr.set_at}
      end)

    publish_event = %Types.PublishEvent{
      hashed: true,
      published_at: now_millis(),
      units: hashed_units,
      exposures: Enum.reverse(state.exposures),
      goals: Enum.reverse(state.goals),
      attributes: attrs_list
    }

    Types.PublishEvent.to_map(publish_event)
  end

  defp do_refresh(state, context_data, {var_index, exp_index, aud_cache, rules_cache}) do
    changed_names = changed_experiment_names(state.data.experiments, context_data.experiments)

    assignments =
      invalidate_changed_assignments(state.assignments, changed_names, exp_index)

    exposed_experiments =
      Enum.reduce(changed_names, state.exposed_experiments, fn name, acc ->
        if Map.has_key?(state.overrides, name) or
             keep_saved_holdout?(Map.get(assignments, name), Map.get(exp_index, name)) do
          acc
        else
          MapSet.delete(acc, name)
        end
      end)

    experiment_holdouts = build_holdout_index(context_data)

    state = %{
      state
      | data: context_data,
        assignments: assignments,
        variable_index: var_index,
        experiment_index: exp_index,
        audience_cache: aud_cache,
        rules_cache: rules_cache,
        exposed_experiments: exposed_experiments,
        experiment_holdouts: experiment_holdouts
    }

    state = prune_holdout_exposed(state)

    Logger.info("Context refreshed with #{length(context_data.experiments)} experiments")
    emit_event(state, :refresh, %{experiments: context_data.experiments})
    state
  end

  defp get_or_assign(state, experiment) do
    name = experiment.name
    override = Map.get(state.overrides, name)

    if override != nil do
      # Overrides expose their holdouts too (see override_holdout_arms/4).
      state = unpin_holdout_exposed(state, name)
      key = holdout_key(state, experiment)

      state =
        if key != nil or match?(%{holdout_key: [_ | _]}, Map.get(state.assignments, name)),
          do: %{state | assignments: Map.delete(state.assignments, name)},
          else: state

      {holdout_arms, state} = override_holdout_arms(state, experiment, override, key)

      assignment = %{
        base_assignment(experiment)
        | variant: override,
          overridden: true,
          holdout_arms: holdout_arms,
          holdout_key: key
      }

      {assignment, state}
    else
      # A normal decision supersedes the arms an earlier override pinned, as
      # the JavaScript SDK keeps one assignment per experiment.
      state =
        if state.override_snapshots == %{},
          do: state,
          else: %{state | override_snapshots: Map.delete(state.override_snapshots, name)}

      # A read while the custom differs rebuilds the assignment unexposed in
      # the JavaScript SDK, so the covered decision is no longer pinned.
      state =
        if state.custom_assignments != %{} and
             custom_stale?(state, name, Map.get(state.assignments, name)),
           do: rebuild_custom_pin(state, name),
           else: state

      cached = Map.get(state.assignments, name)

      {cached, state} = maybe_reassign(cached, state, experiment, name)

      {assignment, state} =
        if cached != nil do
          {cached, state}
        else
          state = cache_evaluation_vars(state, experiment)
          {assignment, state} = assign_variant(state, experiment)
          {assignment, %{state | assignments: Map.put(state.assignments, name, assignment)}}
        end

      custom = Map.get(state.custom_assignments, name)

      assignment =
        if custom_applies?(custom, assignment),
          do: %{assignment | variant: custom, custom: true},
          else: assignment

      {assignment, state}
    end
  end

  # A new custom assignment re-exposes the experiment, except when its cached
  # assignment was won by a rule: a rule wins over a custom assignment (as in
  # the JavaScript SDK, a custom mismatch is not staleness for it), so the
  # served variant and its exposure stay the same, and an exposed split
  # resolved without its unit stays pinned. (A suppressed experiment never
  # queues its own exposure, and its holdouts expose once, so re-marking it
  # changes nothing.)
  # An override read rebuilds the assignment unexposed in the JavaScript SDK,
  # so its covered decision is no longer pinned.
  defp unpin_holdout_exposed(state, name) do
    case Map.get(state.assignments, name) do
      %Types.Assignment{holdout_exposed: true} = cached ->
        %{
          state
          | assignments: Map.put(state.assignments, name, %{cached | holdout_exposed: false})
        }

      _ ->
        state
    end
  end

  defp rebuild_custom_pin(state, name) do
    case Map.get(state.assignments, name) do
      %Types.Assignment{holdout_key: [_ | _], suppressed: false} ->
        %{
          state
          | assignments: Map.delete(state.assignments, name),
            exposed_experiments: MapSet.delete(state.exposed_experiments, name)
        }

      _ ->
        state
    end
  end

  defp reset_exposed_for_custom(state, exposed, name) do
    case Map.get(state.assignments, name) do
      %Types.Assignment{rule_override: true} -> exposed
      _ -> MapSet.delete(exposed, name)
    end
  end

  # As in the JavaScript SDK, a custom assignment only replaces a randomized
  # assignment: not a full-on, traffic-excluded, missing-unit or strict
  # audience-excluded one (those are all unassigned or ineligible).
  defp custom_applies?(custom, assignment),
    do: custom != nil and assignment.assigned and assignment.eligible and not assignment.full_on

  defp maybe_reassign(nil, state, _experiment, _name), do: {nil, state}

  # Mirrors the JavaScript SDK's `holdoutSetMatches` and `audienceMatches`
  # (context.ts).
  defp maybe_reassign(cached, state, experiment, name) do
    rules_changed = cached.rule_key != experiment.assignment_rules

    cond do
      # A shared-key candidate passed over while its unit was missing. (While
      # it still is, a rebuild would only give the same control.)
      cached.variable_unassigned and Map.has_key?(state.units, unit_type(experiment)) ->
        reassign(cache_evaluation_vars(state, experiment), experiment, name)

      (cached.holdout_key != nil or state.experiment_holdouts != %{}) and
          (cached.holdout_key != holdout_key(state, experiment) or
             (cached.holdout_unit_type != nil and
                cached.holdout_unit_type != unit_type(experiment))) ->
        reassign(cache_evaluation_vars(state, experiment), experiment, name)

      rules_changed and experiment.assignment_rules == nil and
          (cached.rule_variant != nil or cached.rule_override) ->
        reassign(state, experiment, name)

      rules_changed or cached.audience_match_seq < state.attrs_seq ->
        recheck(cached, cache_evaluation_vars(state, experiment), experiment, name)

      true ->
        {cached, state}
    end
  end

  defp recheck(cached, state, experiment, name) do
    with {:ok, cached} <- recheck_rule(cached, state, experiment, name),
         :ok <- recheck_audience(cached, state, experiment) do
      updated = %{
        cached
        | rule_key: experiment.assignment_rules,
          audience_match_seq: state.attrs_seq
      }

      {updated, %{state | assignments: Map.put(state.assignments, name, updated)}}
    else
      :stale -> reassign(state, experiment, name)
    end
  end

  # Experiments without (parseable) rules resolve to no rule, so a rule
  # variant cached from rules that were since replaced by invalid ones is stale.
  defp recheck_rule(cached, state, experiment, name) do
    # An exposed split resolved without its unit keeps resolving as if the
    # unit were still missing, so a unit set afterwards cannot switch the
    # variant the user already saw.
    pinned_missing =
      cached.rule_missing_unit and MapSet.member?(state.exposed_experiments, name)

    {rule_variant, missing_unit} = resolve_rule(state, experiment, pinned_missing)

    if rule_variant == cached.rule_variant,
      do: {:ok, %{cached | rule_missing_unit: missing_unit}},
      else: :stale
  end

  defp recheck_audience(%{rule_override: true}, _state, _experiment), do: :ok
  defp recheck_audience(%{suppressed: true}, _state, _experiment), do: :ok

  defp recheck_audience(cached, state, experiment) do
    # An indeterminate (nil) audience result keeps the cached flag.
    new_mismatch =
      case audience_result(state, experiment) do
        nil -> cached.audience_mismatch
        result -> not result
      end

    if new_mismatch == cached.audience_mismatch, do: :ok, else: :stale
  end

  defp reassign(state, experiment, name) do
    {assignment, state} = assign_variant(state, experiment)

    # A rebuild while the unit is still missing keeps waiting for it.
    assignment =
      if match?(%{variable_unassigned: true}, Map.get(state.assignments, name)) and
           not Map.has_key?(state.units, unit_type(experiment)),
         do: %{assignment | variable_unassigned: true},
         else: assignment

    state = %{
      state
      | assignments: Map.put(state.assignments, name, assignment),
        exposed_experiments: MapSet.delete(state.exposed_experiments, name)
    }

    {assignment, state}
  end

  # Same decision order as the JavaScript SDK's `_assign` (context.ts): a
  # matching assignment rule wins over everything but an override (holdout
  # suppression included), then a unit held out by a covering holdout gets
  # variant 0 unassigned, then the audience is evaluated, a strict mismatch
  # forces variant 0, a full-on experiment is assigned its full-on variant
  # even without a unit, and only a running experiment needs the unit for the
  # traffic and variant split.
  defp assign_variant(state, experiment) do
    {rule_variant, missing_unit} = resolve_rule(state, experiment, false)
    {holdout_arms, state} = holdout_arms(state, experiment)

    base = %{
      base_assignment(experiment)
      | audience_match_seq: state.attrs_seq,
        rule_key: experiment.assignment_rules,
        rule_variant: rule_variant,
        rule_missing_unit: missing_unit,
        holdout_arms: holdout_arms,
        holdout_key: holdout_key(state, experiment),
        holdout_unit_type: holdout_arms && unit_type(experiment),
        suppressed: held_out?(holdout_arms, experiment)
    }

    assignment =
      cond do
        rule_variant != nil -> %{base | variant: rule_variant, rule_override: true}
        base.suppressed -> base
        true -> assign_without_rule(state, experiment, base)
      end

    {assignment, state}
  end

  # The unit's arm in each holdout covering the experiment, as a list of
  # `{holdout name, arm}` in holdout id order (nil when not covered). An arm
  # is nil while the experiment's unit is missing. Pinned in the assignment,
  # so its exposures always match the decision made from them. Mirrors the
  # JavaScript SDK's `_getHoldoutAssignment`: the arm is computed on the
  # covered experiment's unit type (never the holdout's own), once per
  # holdout iteration, so a same-iteration seed or split edit does not move
  # the unit, and the arm count it was computed with stays with it.
  defp holdout_arms(state, experiment) do
    case Map.get(state.experiment_holdouts, experiment.name) do
      nil ->
        {nil, state}

      {_key, holdouts} ->
        Enum.map_reduce(holdouts, state, fn holdout, acc ->
          {arm, acc} = holdout_arm(acc, holdout, unit_type(experiment))
          {{holdout.name, arm}, acc}
        end)
    end
  end

  # `holdout` is always the installed definition: arms are resolved from the
  # current index, never from a definition pinned before a refresh.
  defp holdout_arm(state, holdout, unit_type) do
    key = {holdout.id, unit_type}

    case Map.get(state.holdout_assignments, key) do
      %{iteration: iteration} = arm when iteration == holdout.iteration ->
        {arm, state}

      _ ->
        case Map.get(state.units, unit_type) do
          nil ->
            {nil, state}

          uid ->
            arm = %{
              ref: make_ref(),
              id: holdout.id,
              iteration: holdout.iteration,
              unit_type: unit_type,
              variant:
                VariantAssigner.assign(
                  Utils.hash_unit(uid),
                  holdout.split,
                  holdout.seed_hi,
                  holdout.seed_lo
                ),
              arm_count: length(holdout.split)
            }

            {arm, %{state | holdout_assignments: Map.put(state.holdout_assignments, key, arm)}}
        end
    end
  end

  defp held_out?(nil, _experiment), do: false

  defp held_out?(holdout_arms, experiment) do
    Enum.any?(holdout_arms, fn
      {_name, nil} -> false
      {_name, arm} -> held_out_by?(arm.variant, arm.arm_count, experiment.full_on_variant)
    end)
  end

  # Mirrors the JavaScript SDK's `isHeldOutBy`: arm 0 always holds the unit
  # out, and arm 1 of a three-arm holdout holds it out of experiments that are
  # not full-on. The arity comes from the split, never from `holdoutType`. A
  # missing fullOnVariant is not full-on here, as in assignment (`full_on?/1`).
  defp held_out_by?(0, _arm_count, _full_on_variant), do: true
  defp held_out_by?(1, 3, full_on_variant), do: full_on_variant in [0, nil]
  defp held_out_by?(_variant, _arm_count, _full_on_variant), do: false

  defp holdout_unit_missing?(%{holdout_arms: nil}), do: false

  defp holdout_unit_missing?(%{holdout_arms: arms}),
    do: Enum.any?(arms, fn {_name, arm} -> arm == nil end)

  defp prune_holdout_exposed(state) do
    if MapSet.size(state.holdout_exposed) == 0 do
      state
    else
      reachable = reachable_arm_refs(state)
      %{state | holdout_exposed: MapSet.intersection(state.holdout_exposed, reachable)}
    end
  end

  # The refs of the arms a pinned assignment, an override or the arm cache
  # can still serve.
  defp reachable_arm_refs(state) do
    pinned =
      for {_name, %Types.Assignment{holdout_arms: [_ | _] = arms}} <- state.assignments,
          {_holdout, %{ref: ref}} <- arms,
          do: ref

    overridden =
      for {_name, {_variant, _key, [_ | _] = arms}} <- state.override_snapshots,
          {_holdout, %{ref: ref}} <- arms,
          do: ref

    cached = for {_key, %{ref: ref}} <- state.holdout_assignments, do: ref
    MapSet.new(pinned ++ overridden ++ cached)
  end

  defp queue_holdout_exposures(state, nil), do: state

  defp queue_holdout_exposures(state, arms) do
    Enum.reduce(arms, state, fn
      {_name, nil}, acc ->
        acc

      {name, arm}, acc ->
        if MapSet.member?(acc.holdout_exposed, arm.ref) do
          acc
        else
          acc = %{acc | holdout_exposed: MapSet.put(acc.holdout_exposed, arm.ref)}

          enqueue_exposure(acc, %Types.Exposure{
            id: arm.id,
            name: name,
            unit: arm.unit_type,
            variant: arm.variant,
            exposed_at: now_millis(),
            assigned: true,
            eligible: true,
            overridden: false,
            full_on: false,
            custom: false,
            audience_mismatch: false,
            rule_override: false
          })
        end
    end)
  end

  defp assign_without_rule(state, experiment, base) do
    uid = Map.get(state.units, unit_type(experiment))

    audience_mismatch = audience_result(state, experiment) == false
    base = %{base | audience_mismatch: audience_mismatch}

    cond do
      audience_mismatch and experiment.audience_strict == true ->
        base

      full_on?(experiment) ->
        %{base | variant: experiment.full_on_variant, assigned: true, full_on: true}

      is_nil(uid) ->
        base

      true ->
        hashed_unit = Utils.hash_unit(uid)

        if traffic_eligible?(hashed_unit, experiment) do
          variant =
            VariantAssigner.assign(
              hashed_unit,
              experiment.split,
              experiment.seed_hi,
              experiment.seed_lo
            )

          %{base | variant: variant, assigned: true}
        else
          %{base | assigned: true, eligible: false}
        end
    end
  end

  # Without parsed rules there is nothing to resolve, so the evaluation map is
  # not needed.
  defp resolve_rule(state, experiment, pinned_missing) do
    case Map.get(state.rules_cache, experiment.name) do
      nil ->
        {nil, false}

      rules ->
        uid = if pinned_missing, do: nil, else: Map.get(state.units, unit_type(experiment))

        AssignmentRules.resolve(
          rules,
          experiment,
          rules_environment(state),
          evaluation_vars(state),
          uid
        )
    end
  end

  defp unit_type(experiment), do: experiment.unit_type || "session_id"

  defp rules_environment(state) do
    case Map.get(state.sdk_config, :environment) do
      "" -> nil
      environment -> environment
    end
  end

  # Like the JavaScript SDK's `_invalidateAssignmentsPinnedWithMissingUnit`:
  # a split rule resolved without its unit is dropped once that unit is set,
  # so the next read randomizes it. An exposed one is kept (it stays pinned
  # to the variant the user already saw).
  defp invalidate_rules_missing_unit(state, []), do: state

  defp invalidate_rules_missing_unit(state, added_unit_types) do
    {dropped, assignments} =
      Map.split_with(state.assignments, fn {name, assignment} ->
        missing_unit_resolves?(state, name, assignment, added_unit_types)
      end)

    # A dropped decision that was exposed is rebuilt unexposed, as in the
    # JavaScript SDK, so its replacement and holdouts are exposed.
    exposed =
      Enum.reduce(dropped, state.exposed_experiments, fn
        {name, %Types.Assignment{holdout_exposed: true}}, acc ->
          if MapSet.member?(state.placeholder_exposed, name),
            do: acc,
            else: MapSet.delete(acc, name)

        _, acc ->
          acc
      end)

    %{state | assignments: assignments, exposed_experiments: exposed}
  end

  # A split rule resolved without its unit is judged on the installed
  # experiment, as on main. A covered decision made without its unit is
  # judged on itself, like the JavaScript SDK's assignment `unitType` and
  # `exposed` flag, so it also resolves while its experiment is absent.
  defp missing_unit_resolves?(state, name, assignment, added_unit_types) do
    experiment = Map.get(state.experiment_index, name)

    rule_resolves =
      assignment.rule_missing_unit and experiment != nil and
        unit_type(experiment) in added_unit_types and
        not MapSet.member?(state.exposed_experiments, name)

    rule_resolves or
      (holdout_unit_missing?(assignment) and
         (not assignment.holdout_exposed or custom_stale?(state, name, assignment)) and
         assignment.holdout_unit_type in added_unit_types)
  end

  # Like the JavaScript SDK's read-time check: a custom variant other than the
  # cached one makes an assignment not won by a rule stale, as of now, not as
  # of the custom write. (A decision still waiting for its unit has no arm, so
  # it is never held out.)
  defp custom_stale?(_state, _name, nil), do: false
  defp custom_stale?(_state, _name, %{rule_override: true}), do: false

  defp custom_stale?(state, name, assignment) do
    case Map.get(state.custom_assignments, name) do
      nil ->
        false

      custom ->
        served = if custom_applies?(custom, assignment), do: custom, else: assignment.variant
        custom != served
    end
  end

  defp base_assignment(experiment) do
    %Types.Assignment{
      id: experiment.id,
      iteration: experiment.iteration,
      full_on_variant: experiment.full_on_variant,
      traffic_split: experiment.traffic_split,
      variant: 0,
      assigned: false,
      overridden: false,
      eligible: true,
      full_on: false,
      custom: false,
      audience_mismatch: false,
      rule_override: false
    }
  end

  # true / false, or nil when the audience cannot be evaluated (no filter,
  # invalid JSON or an invalid filter), which the JavaScript SDK treats as
  # neither a match nor a mismatch.
  defp audience_result(state, experiment) do
    case experiment.audience do
      nil ->
        nil

      "" ->
        nil

      _audience ->
        Matcher.evaluate(Map.get(state.audience_cache, experiment.name), evaluation_vars(state))
    end
  end

  # Builds the evaluation map once per attribute change, and only for an
  # experiment that needs it (one with parsed rules or an audience), so it is
  # shared by every experiment assigned before the next change. Mirrors the
  # JavaScript SDK's `_getAttributesMap` cache.
  defp cache_evaluation_vars(state, experiment) do
    needs_vars =
      Map.has_key?(state.rules_cache, experiment.name) or
        experiment.audience not in [nil, ""]

    case state.attrs_map do
      {seq, _vars} when seq == state.attrs_seq -> state
      _ when needs_vars -> %{state | attrs_map: {state.attrs_seq, build_evaluation_vars(state)}}
      _ -> state
    end
  end

  defp evaluation_vars(state) do
    case state.attrs_map do
      {seq, vars} when seq == state.attrs_seq -> vars
      _ -> build_evaluation_vars(state)
    end
  end

  # The map audience filters are evaluated against: the SDK's `application` and
  # `environment` names first (the collector adds the same two to every event
  # server-side, so audiences can target them), then the user-set attributes on
  # top so a value the user set with the same name always wins, even one set
  # after an assignment was cached. Empty/absent system names are left out
  # rather than mapped to nil. `app_version` is deliberately not injected.
  # Mirrors the JavaScript SDK's `_getAttributesMap`.
  defp build_evaluation_vars(state) do
    Enum.reduce(state.attributes, system_attributes(state), fn attr, acc ->
      Map.put(acc, attr.name, attr.value)
    end)
  end

  defp system_attributes(state) do
    %{}
    |> put_non_empty("application", Map.get(state.sdk_config, :application))
    |> put_non_empty("environment", Map.get(state.sdk_config, :environment))
  end

  defp put_non_empty(map, _key, nil), do: map
  defp put_non_empty(map, _key, ""), do: map
  defp put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp full_on?(experiment) do
    experiment.full_on_variant != nil && experiment.full_on_variant > 0
  end

  defp traffic_eligible?(hashed_unit, experiment) do
    if experiment.traffic_split && length(experiment.traffic_split) > 1 do
      traffic_variant =
        VariantAssigner.assign(
          hashed_unit,
          experiment.traffic_split,
          experiment.traffic_seed_hi || 0,
          experiment.traffic_seed_lo || 0
        )

      traffic_variant != 0
    else
      true
    end
  end

  defp parse_audience(nil), do: nil
  defp parse_audience(""), do: nil
  defp parse_audience("null"), do: nil
  defp parse_audience("{}"), do: %{}

  defp parse_audience(audience) when is_binary(audience) do
    case Jason.decode(audience) do
      {:ok, decoded} ->
        decoded

      {:error, error} ->
        Logger.error("Failed to parse audience JSON: #{inspect(error)}, audience: #{audience}")

        %{"invalid" => true}
    end
  end

  defp parse_audience(audience) when is_map(audience), do: audience
  defp parse_audience(_), do: nil

  defp create_exposure(experiment, assignment) do
    unit_type = unit_type(experiment)

    %Types.Exposure{
      id: experiment.id,
      name: experiment.name,
      unit: unit_type,
      variant: assignment.variant,
      exposed_at: now_millis(),
      assigned: assignment.assigned,
      eligible: assignment.eligible,
      overridden: assignment.overridden,
      full_on: assignment.full_on,
      custom: assignment.custom,
      audience_mismatch: assignment.audience_mismatch,
      rule_override: assignment.rule_override
    }
  end

  defp build_indexes(experiments) do
    exp_index = Enum.into(experiments, %{}, fn exp -> {exp.name, exp} end)

    aud_cache =
      Enum.reduce(experiments, %{}, fn experiment, cache ->
        case experiment.audience do
          nil ->
            cache

          "" ->
            cache

          audience ->
            parsed = parse_audience(audience)
            if parsed, do: Map.put(cache, experiment.name, parsed), else: cache
        end
      end)

    var_index =
      Enum.reduce(experiments, %{}, fn experiment, index ->
        keys_in_experiment =
          Enum.reduce(experiment.variants || [], MapSet.new(), fn variant, keys ->
            config = parse_variant_config(variant["config"]) || %{}
            Enum.reduce(Map.keys(config), keys, &MapSet.put(&2, &1))
          end)

        Enum.reduce(keys_in_experiment, index, fn key, idx ->
          Map.update(idx, key, [experiment], fn exps -> [experiment | exps] end)
        end)
      end)

    # Candidates for a shared key are tried by experiment id ascending, as in
    # the Java SDK, whatever order the experiments arrive in. Like Java, only
    # the first experiment in the data with a given id is a candidate, and the
    # id is read as Java reads it into an `int` (`5.0`, `5.7` and `" 5"` are 5).
    sorted_var_index =
      Map.new(var_index, fn {key, exps} ->
        {key, exps |> Enum.reverse() |> Enum.sort_by(&java_id/1) |> Enum.uniq_by(&java_id/1)}
      end)

    # Parsed once per installed data, so an experiment's rules are not
    # re-decoded on every assignment.
    rules_cache =
      Enum.reduce(experiments, %{}, fn experiment, cache ->
        case AssignmentRules.parse(experiment.assignment_rules) do
          nil -> cache
          rules -> Map.put(cache, experiment.name, rules)
        end
      end)

    {sorted_var_index, exp_index, aud_cache, rules_cache}
  end

  # Jackson truncates a float id and parses a string of ASCII digits, ignoring
  # surrounding whitespace (an empty string is 0). Any other id is kept as
  # itself, which Erlang term order sorts after every number. Ids the backend
  # does not send (non-ASCII digits or spaces) can differ from Java.
  defp java_id(%{id: id}) when is_integer(id), do: id
  defp java_id(%{id: id}) when is_float(id), do: trunc(id)

  defp java_id(%{id: id}) when is_binary(id) do
    case String.trim(id) do
      "" ->
        0

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} -> int
          _ -> id
        end
    end
  end

  defp java_id(%{id: id}), do: id

  # Mirrors the JavaScript SDK's `_init`: only holdouts with a non-empty split
  # are kept, and each experiment's `holdoutIds` resolve to those holdouts,
  # deduplicated and sorted by id. Ids without a holdout are ignored.
  defp build_holdout_index(%Types.ContextData{holdouts: holdouts, experiments: experiments})
       when holdouts not in [nil, []] do
    holdouts_by_id =
      for %Types.HoldoutData{split: [_ | _] = split, seed_hi: seed_hi, seed_lo: seed_lo} =
            holdout <- holdouts,
          is_integer(seed_hi) and is_integer(seed_lo),
          Types.HoldoutData.valid_split?(split),
          into: %{},
          do: {holdout.id, holdout}

    for %{holdout_ids: [_ | _] = ids} = experiment <- experiments,
        covering =
          ids
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.flat_map(&List.wrap(Map.get(holdouts_by_id, &1))),
        covering != [],
        into: %{},
        do: {experiment.name, {Enum.map(covering, &{&1.id, &1.iteration}), covering}}
  end

  defp build_holdout_index(_context_data), do: %{}

  # The ids and iterations of the holdouts covering an experiment (nil when
  # not covered): a change re-resolves it at the next read, so the new
  # holdouts are exposed. A same-iteration seed or split edit changes nothing.
  defp holdout_key(state, experiment) do
    case Map.get(state.experiment_holdouts, experiment.name) do
      nil -> nil
      {key, _holdouts} -> key
    end
  end

  # Like the JavaScript SDK's pinned overridden assignment, an override read
  # again with the same variant and covering holdouts reuses its arms (unless
  # one waited for a missing unit). Other covering holdouts than its last read,
  # including the first ones after a read of its absent experiment, expose it
  # again.
  defp override_holdout_arms(state, experiment, variant, key) do
    name = experiment.name

    case Map.get(state.override_snapshots, name) do
      {^variant, ^key, arms} when is_list(arms) ->
        if Enum.any?(arms, &match?({_name, nil}, &1)) and
             not MapSet.member?(state.exposed_experiments, name),
           do: snapshot_override(state, experiment, variant, key),
           else: {arms, state}

      {^variant, ^key, nil} ->
        {nil, state}

      nil when key == nil ->
        snapshot_override(state, experiment, variant, key)

      _changed ->
        state = %{state | exposed_experiments: MapSet.delete(state.exposed_experiments, name)}
        snapshot_override(state, experiment, variant, key)
    end
  end

  defp snapshot_override(state, experiment, variant, key) do
    {arms, state} = holdout_arms(state, experiment)
    snapshots = Map.put(state.override_snapshots, experiment.name, {variant, key, arms})
    {arms, %{state | override_snapshots: snapshots}}
  end

  # Assignments are sticky across a refresh, as in the JavaScript SDK's
  # `experimentMatches` (context.ts): only a change of id, iteration,
  # fullOnVariant, trafficSplit or unitType invalidates a cached assignment.
  # Seeds, split, variant configs and audience edits deliberately do not, so a
  # refresh never re-buckets a user or queues a duplicate exposure for them.
  defp changed_experiment_names(old_experiments, new_experiments) do
    old_exp_map = Enum.into(old_experiments, %{}, fn exp -> {exp.name, exp} end)
    new_exp_map = Enum.into(new_experiments, %{}, fn exp -> {exp.name, exp} end)
    all_names = MapSet.union(MapSet.new(Map.keys(old_exp_map)), MapSet.new(Map.keys(new_exp_map)))

    Enum.filter(all_names, fn name ->
      old_exp = Map.get(old_exp_map, name)
      new_exp = Map.get(new_exp_map, name)

      cond do
        is_nil(old_exp) || is_nil(new_exp) -> true
        old_exp.id != new_exp.id -> true
        old_exp.iteration != new_exp.iteration -> true
        old_exp.full_on_variant != new_exp.full_on_variant -> true
        old_exp.traffic_split != new_exp.traffic_split -> true
        old_exp.unit_type != new_exp.unit_type -> true
        true -> false
      end
    end)
  end

  defp saved_unassigned_holdout?(nil), do: false

  defp saved_unassigned_holdout?(assignment),
    do: assignment.holdout_key != nil and not assignment.assigned and not assignment.rule_override

  defp keep_saved_holdout?(nil, _experiment), do: false
  defp keep_saved_holdout?(assignment, nil), do: saved_unassigned_holdout?(assignment)

  defp keep_saved_holdout?(assignment, experiment),
    do:
      saved_unassigned_holdout?(assignment) and assignment.id == experiment.id and
        assignment.iteration == experiment.iteration and
        assignment.full_on_variant == experiment.full_on_variant and
        assignment.traffic_split == experiment.traffic_split

  defp invalidate_changed_assignments(assignments, changed_names, exp_index) do
    changed_names = MapSet.new(changed_names)

    Map.reject(assignments, fn {name, assignment} ->
      not assignment.overridden and MapSet.member?(changed_names, name) and
        not keep_saved_holdout?(assignment, Map.get(exp_index, name))
    end)
  end

  # Marks the context as failed to load, wakes up wait_until_ready/2 callers
  # with the reason, and reports it through the `:error` event.
  defp mark_failed(state, reason) do
    waiters = state.pending_waiters

    # Like the JS SDK, a failed context is ready with empty data so reads
    # return control/default values.
    state = %{
      state
      | failed: true,
        ready: true,
        failed_reason: reason,
        pending_waiters: [],
        data: %Types.ContextData{experiments: []},
        variable_index: %{},
        experiment_index: %{},
        audience_cache: %{},
        rules_cache: %{},
        experiment_holdouts: %{}
    }

    emit_event(state, :error, reason)

    for waiter <- waiters do
      GenServer.reply(waiter, {:error, reason})
    end

    state
  end

  defp emit_event(state, event_type, data) do
    if state.event_handler do
      # Deliver synchronously so events are observable immediately after the
      # operation that produced them returns (e.g. track() -> goal event).
      try do
        state.event_handler.(event_type, data)
      rescue
        exception ->
          Logger.error("""
          Event handler crashed for event #{event_type}
          Exception: #{Exception.format(:error, exception, __STACKTRACE__)}
          Data: <redacted>
          """)
      catch
        kind, reason ->
          Logger.error(
            "Event handler for #{event_type} exited with #{inspect(kind)}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp now_millis do
    System.system_time(:millisecond)
  end
end
