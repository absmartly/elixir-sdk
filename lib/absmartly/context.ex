defmodule ABSmartly.Context do
  use GenServer

  require Logger

  alias ABSmartly.{
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
    :data_fetcher,
    attrs_seq: 0,
    pending_waiters: [],
    exposure_count: 0,
    goal_count: 0
  ]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(sdk_config, data, context_config, opts \\ []) do
    data_fetcher = Keyword.get(opts, :data_fetcher)
    GenServer.start_link(__MODULE__, {sdk_config, data, context_config, data_fetcher})
  end

  def start_link_async(sdk_config, context_config, opts \\ []) do
    data_fetcher = Keyword.get(opts, :data_fetcher)
    GenServer.start_link(__MODULE__, {:async, sdk_config, context_config, data_fetcher})
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
    GenServer.call(context, :publish)
  end

  def finalize(context) do
    GenServer.call(context, :finalize)
  end

  def close(context) do
    finalize(context)
  end

  def refresh(context) do
    GenServer.call(context, :refresh)
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

  # GenServer callbacks

  @impl true
  def init({:async, sdk_config, context_config}) do
    init({:async, sdk_config, context_config, nil})
  end

  def init({:async, sdk_config, context_config, data_fetcher}) do
    empty_data = %Types.ContextData{experiments: []}
    state = %__MODULE__{
      sdk_config: sdk_config,
      data: empty_data,
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
      data_fetcher: data_fetcher,
      pending_waiters: [],
      exposure_count: 0,
      goal_count: 0
    }

    {:ok, state, {:continue, :fetch_async}}
  end

  @impl true
  def handle_continue(:fetch_async, state) do
    # Fetch context data off the GenServer process so the context stays
    # responsive (set_unit/set_attribute/set_failed/wait_until_ready) while the
    # request is in flight, mirroring the future/callback model of the other SDKs.
    server = self()
    fetcher = state.data_fetcher

    spawn(fn ->
      result =
        if fetcher do
          fetcher.()
        else
          ABSmartly.HTTP.Client.fetch_context(
            state.sdk_config.endpoint,
            state.sdk_config.api_key,
            state.sdk_config.application,
            state.sdk_config.environment
          )
        end

      send(server, {:fetch_async_complete, result})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:fetch_async_complete, _result}, %{ready: true} = state), do: {:noreply, state}
  def handle_info({:fetch_async_complete, _result}, %{failed: true} = state), do: {:noreply, state}

  def handle_info({:fetch_async_complete, {:ok, data}}, state) do
    context_data = Types.ContextData.from_map(data)
    {var_index, exp_index, aud_cache} = build_indexes(context_data.experiments)
    state = %{state |
      data: context_data,
      ready: true,
      variable_index: var_index,
      experiment_index: exp_index,
      audience_cache: aud_cache
    }

    for waiter <- state.pending_waiters do
      GenServer.reply(waiter, :ok)
    end
    state = %{state | pending_waiters: []}

    emit_event(state, :ready, %{experiments: context_data.experiments})
    {:noreply, state}
  end

  def handle_info({:fetch_async_complete, {:error, reason}}, state) do
    state = %{state | failed: true, failed_reason: reason}
    for waiter <- state.pending_waiters do
      GenServer.reply(waiter, {:error, reason})
    end
    {:noreply, %{state | pending_waiters: []}}
  end

  @impl true
  def init({sdk_config, data, context_config}) do
    init({sdk_config, data, context_config, nil})
  end

  def init({sdk_config, data, context_config, data_fetcher}) do
    {var_index, exp_index, aud_cache} = build_indexes(data.experiments)
    state = %__MODULE__{
      sdk_config: sdk_config,
      data: data,
      ready: true,
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
      variable_index: var_index,
      experiment_index: exp_index,
      event_handler: context_config.event_handler,
      exposed_experiments: MapSet.new(),
      audience_cache: aud_cache,
      data_fetcher: data_fetcher,
      exposure_count: 0,
      goal_count: 0
    }

    Logger.info("Context initialized successfully")
    emit_event(state, :ready, %{experiments: data.experiments})

    {:ok, state}
  end

  @impl true
  def handle_call({:set_data, data}, _from, state) do
    context_data = Types.ContextData.from_map(data)
    {var_index, exp_index, aud_cache} = build_indexes(context_data.experiments)
    state = %{state |
      data: context_data,
      ready: true,
      variable_index: var_index,
      experiment_index: exp_index,
      audience_cache: aud_cache
    }
    for waiter <- state.pending_waiters do
      GenServer.reply(waiter, :ok)
    end
    state = %{state | pending_waiters: []}
    emit_event(state, :ready, %{experiments: context_data.experiments})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_failed, reason}, _from, state) do
    state = %{state | failed: true, failed_reason: reason}
    for waiter <- state.pending_waiters do
      GenServer.reply(waiter, {:error, reason})
    end
    state = %{state | pending_waiters: []}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:ready_error, _from, state) do
    {:reply, state.failed_reason, state}
  end

  @impl true
  def handle_call(:wait_until_ready, from, state) do
    cond do
      state.ready ->
        {:reply, :ok, state}
      state.failed ->
        {:reply, {:error, :failed}, state}
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
            state = %{state | units: Map.put(state.units, key, uid_str)}
            {:reply, :ok, state}
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
        new_units = Enum.reduce(units, state.units, fn {unit_type, uid}, acc ->
          key = to_string(unit_type)

          uid_str = case validate_uid_or_error(uid, key) do
            {:error, msg} -> throw({:validation_error, msg})
            {:ok, str} -> str
          end

          if Map.has_key?(acc, key) && Map.get(acc, key) != uid_str do
            throw({:duplicate_unit, key})
          end

          Map.put(acc, key, uid_str)
        end)

        state = %{state | units: new_units}
        {:reply, :ok, state}
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
  def handle_call({:set_attribute, name, value}, _from, state) do
    name_str = to_string(name)
    entry = %{name: name_str, value: value, set_at: now_millis()}
    state = %{state | attributes: state.attributes ++ [entry], attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_attributes, attributes}, _from, state) do
    set_at = now_millis()
    new_entries = Enum.map(attributes, fn {name, value} ->
      %{name: to_string(name), value: value, set_at: set_at}
    end)
    state = %{state | attributes: state.attributes ++ new_entries, attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_attribute, name}, _from, state) do
    name_str = to_string(name)
    value = state.attributes
      |> Enum.filter(fn attr -> attr.name == name_str end)
      |> List.last()
      |> case do
        nil -> nil
        attr -> attr.value
      end
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
    {new_overrides, new_exposed} = Enum.reduce(overrides, {state.overrides, state.exposed_experiments}, fn {experiment_name, variant}, {ov_acc, exp_acc} ->
      name = to_string(experiment_name)
      {Map.put(ov_acc, name, variant), MapSet.delete(exp_acc, name)}
    end)

    state = %{state | overrides: new_overrides, exposed_experiments: new_exposed}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_custom_assignment, experiment_name, variant}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      name = to_string(experiment_name)
      state = %{
        state
        | custom_assignments: Map.put(state.custom_assignments, name, variant),
          exposed_experiments: MapSet.delete(state.exposed_experiments, name)
      }

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:set_custom_assignments, assignments}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      {new_assignments, new_exposed} = Enum.reduce(assignments, {state.custom_assignments, state.exposed_experiments}, fn {experiment_name, variant}, {ca_acc, exp_acc} ->
        name = to_string(experiment_name)
        {Map.put(ca_acc, name, variant), MapSet.delete(exp_acc, name)}
      end)

      state = %{state | custom_assignments: new_assignments, exposed_experiments: new_exposed}
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:treatment, experiment_name}, _from, state) do
    cond do
      not state.ready -> {:reply, 0, state}
      state.finalized -> {:reply, 0, state}
      true ->
        {variant, state} = do_treatment(state, experiment_name, true)
        {:reply, variant, state}
    end
  end

  @impl true
  def handle_call({:peek, experiment_name}, _from, state) do
    {variant, state} = do_treatment(state, experiment_name, false)
    {:reply, variant, state}
  end

  @impl true
  def handle_call({:variable_value, key, default_value}, _from, state) do
    if state.finalized do
      {:reply, default_value, state}
    else
      {value, state} = do_variable_value(state, key, default_value, true)
      {:reply, value, state}
    end
  end

  @impl true
  def handle_call({:peek_variable_value, key, default_value}, _from, state) do
    {value, state} = do_variable_value(state, key, default_value, false)
    {:reply, value, state}
  end

  @impl true
  def handle_call(:variable_keys, _from, state) do
    result = Map.new(state.variable_index, fn {key, experiments} ->
      {key, Enum.map(experiments, & &1.name)}
    end)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:custom_field_value, experiment_name, field_name}, _from, state) do
    value = do_custom_field_value(state, experiment_name, field_name)
    {:reply, value, state}
  end

  @impl true
  def handle_call(:custom_field_keys, _from, state) do
    keys = do_custom_field_keys(state)
    {:reply, keys, state}
  end

  @impl true
  def handle_call({:custom_field_value_type, experiment_name, field_name}, _from, state) do
    type = do_custom_field_value_type(state, experiment_name, field_name)
    {:reply, type, state}
  end

  @impl true
  def handle_call({:track, goal_name, properties}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      state = do_track(state, goal_name, properties)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:publish, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      {result, new_state} = do_publish(state)
      {:reply, result, new_state}
    end
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    if state.finalized or state.finalizing do
      {:reply, :ok, state}
    else
      state = %{state | finalizing: true}

      {_result, new_state} = do_publish(state)

      new_state = %{new_state | finalized: true, finalizing: false}
      emit_event(new_state, :finalize, nil)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    fetch_result = if state.data_fetcher do
      state.data_fetcher.()
    else
      ABSmartly.HTTP.Client.fetch_context(
        state.sdk_config.endpoint,
        state.sdk_config.api_key,
        state.sdk_config.application,
        state.sdk_config.environment
      )
    end

    case fetch_result do
      {:ok, new_data} ->
        handle_call({:refresh, new_data}, nil, state)
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:refresh, new_data}, _from, state) do
    if state.finalized do
      {:reply, {:error, "ABsmartly Context is finalized."}, state}
    else
      state = do_refresh(state, new_data)
      {:reply, :ok, state}
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
    {:reply, state.data, state}
  end

  @impl true
  def handle_call(:experiments, _from, state) do
    names = Enum.map(state.data.experiments, & &1.name)
    {:reply, names, state}
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

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("Context received EXIT signal: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Context received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helper functions

  defp validate_uid(uid, unit_type \\ "unknown") do
    uid_str = to_string(uid)

    if String.length(uid_str) > @max_uid_length do
      raise ArgumentError, "Unit ID exceeds maximum length of #{@max_uid_length}"
    end

    uid_str
  end

  defp validate_uid_or_error(uid, unit_type) do
    uid_str = to_string(uid)

    cond do
      String.trim(uid_str) == "" ->
        {:error, "Unit '#{unit_type}' UID must not be blank."}
      String.length(uid_str) > @max_uid_length ->
        {:error, "Unit ID exceeds maximum length of #{@max_uid_length}"}
      true ->
        {:ok, uid_str}
    end
  end

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
      if queue_exposure do
        exposure = create_exposure(experiment, assignment)
        queue_exposure(state, experiment_name, exposure)
      else
        state
      end

    {assignment.variant, state}
  end

  defp do_treatment_for_override(state, experiment_name, override, queue_exposure) do
    state =
      if queue_exposure do
        exposure = %Types.Exposure{
          id: 0,
          name: experiment_name,
          unit: nil,
          variant: override,
          exposed_at: now_millis(),
          assigned: false,
          eligible: true,
          overridden: true,
          full_on: false,
          custom: false,
          audience_mismatch: false
        }

        queue_exposure(state, experiment_name, exposure)
      else
        state
      end

    {override, state}
  end

  defp do_treatment_for_unknown(state, experiment_name, queue_exposure) do
    state =
      if queue_exposure do
        exposure = %Types.Exposure{
          id: 0,
          name: experiment_name,
          unit: nil,
          variant: 0,
          exposed_at: now_millis(),
          assigned: false,
          eligible: true,
          overridden: false,
          full_on: false,
          custom: false,
          audience_mismatch: false
        }

        queue_exposure(state, experiment_name, exposure)
      else
        state
      end

    {0, state}
  end

  defp queue_exposure(state, experiment_name, exposure) do
    unless MapSet.member?(state.exposed_experiments, experiment_name) do
      state =
        if state.exposure_count >= @max_queue_size do
          Logger.error(
            "Exposure queue size limit reached (#{@max_queue_size}), dropping oldest"
          )

          %{state | exposures: Enum.drop(state.exposures, 1), exposure_count: state.exposure_count - 1}
        else
          state
        end

      state = %{
        state
        | exposures: [exposure | state.exposures],
          exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name),
          exposure_count: state.exposure_count + 1
      }

      emit_event(state, :exposure, exposure)
      state
    else
      state
    end
  end

  defp do_variable_value(state, key, default_value, queue_exposure) do
    experiments = Map.get(state.variable_index, key, [])

    {result, state} =
      Enum.reduce(experiments, {nil, state}, fn exp, {found, acc_state} ->
        {assignment, acc_state} = get_or_assign(acc_state, exp)

        acc_state =
          if queue_exposure do
            exposure = create_exposure(exp, assignment)
            queue_exposure(acc_state, exp.name, exposure)
          else
            acc_state
          end

        if found == nil && (assignment.assigned || assignment.overridden) do
          variant_data = Enum.at(exp.variants, assignment.variant)

          if variant_data do
            config = parse_variant_config(variant_data["config"])

            if is_map(config) && Map.has_key?(config, key) do
              {{exp, assignment, config[key]}, acc_state}
            else
              {found, acc_state}
            end
          else
            {found, acc_state}
          end
        else
          {found, acc_state}
        end
      end)

    case result do
      {_experiment, _assignment, value} ->
        {value, state}

      nil ->
        {default_value, state}
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
        Logger.error(
          "Failed to parse variant config JSON: #{inspect(error)}, config: #{config}"
        )

        nil
    end
  end

  defp parse_variant_config(_), do: nil

  defp do_custom_field_value(state, experiment_name, field_name) do
    experiment = Map.get(state.experiment_index, experiment_name)

    if experiment && experiment.custom_field_values do
      custom_field =
        Enum.find(experiment.custom_field_values, fn field ->
          field["name"] == field_name
        end)

      if custom_field do
        parse_custom_field(custom_field["value"], custom_field["type"])
      end
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
    experiment = Map.get(state.experiment_index, experiment_name)

    if experiment && experiment.custom_field_values do
      custom_field =
        Enum.find(experiment.custom_field_values, fn field ->
          field["name"] == field_name
        end)

      if custom_field do
        custom_field["type"]
      end
    end
  end

  defp parse_custom_field(value, "string"), do: value
  defp parse_custom_field(value, "text"), do: value
  defp parse_custom_field(value, "number"), do: Utils.to_number(value)
  defp parse_custom_field(value, "boolean"), do: value == "true" or value == true

  defp parse_custom_field(value, "json") do
    case Jason.decode(value) do
      {:ok, decoded} ->
        decoded

      {:error, error} ->
        Logger.error(
          "Failed to parse custom field JSON: #{inspect(error)}, value: #{value}"
        )

        nil
    end
  end

  defp parse_custom_field(value, _type), do: value

  defp do_track(state, goal_name, properties) do
    sanitized_properties =
      case properties do
        map when is_map(map) -> map
        nil -> nil
        _other -> nil
      end

    goal = %Types.Goal{
      name: goal_name,
      achieved_at: now_millis(),
      properties: sanitized_properties
    }

    state =
      if state.goal_count >= @max_queue_size do
        Logger.error("Goal queue size limit reached (#{@max_queue_size}), dropping oldest")
        %{state | goals: Enum.drop(state.goals, 1), goal_count: state.goal_count - 1}
      else
        state
      end

    state = %{state | goals: [goal | state.goals], goal_count: state.goal_count + 1}
    emit_event(state, :goal, goal)
    state
  end

  defp do_publish(state) do
    if state.exposures != [] or state.goals != [] do
      event_map = build_publish_event_map(state)

      emit_event(state, :publish, event_map)

      new_state = %{state | exposures: [], goals: [], exposure_count: 0, goal_count: 0}

      publisher = Map.get(state.sdk_config, :publisher, ABSmartly.DefaultContextPublisher)
      task = Task.async(fn ->
        publisher.publish(
          state.sdk_config.endpoint,
          state.sdk_config.api_key,
          state.sdk_config.application,
          state.sdk_config.environment,
          event_map,
          state.sdk_config.retries
        )
      end)

      case Task.yield(task, 5000) || Task.shutdown(task) do
        {:ok, :ok} ->
          Logger.info("Successfully published #{state.exposure_count} exposures and #{state.goal_count} goals")

        {:ok, {:error, reason}} ->
          Logger.error("Failed to publish events: #{inspect(reason)}")

        nil ->
          Logger.error("Publish timed out, events may be lost")
      end

      {:ok, new_state}
    else
      {:ok, state}
    end
  end

  defp do_publish_sync(state) do
    if state.exposures != [] or state.goals != [] do
      event_map = build_publish_event_map(state)

      publisher = Map.get(state.sdk_config, :publisher, ABSmartly.DefaultContextPublisher)
      case publisher.publish(
             state.sdk_config.endpoint,
             state.sdk_config.api_key,
             state.sdk_config.application,
             state.sdk_config.environment,
             event_map,
             min(state.sdk_config.retries, 1)
           ) do
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

    attrs_list = Enum.map(state.attributes, fn attr ->
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

  defp do_refresh(state, %Types.ContextData{} = new_data) do
    do_refresh_with_context_data(state, new_data)
  end

  defp do_refresh(state, new_data) do
    context_data = Types.ContextData.from_map(new_data)
    do_refresh_with_context_data(state, context_data)
  end

  defp do_refresh_with_context_data(state, context_data) do
    changed_names = changed_experiment_names(state.data.experiments, context_data.experiments)

    assignments =
      invalidate_changed_assignments(
        state.assignments,
        state.data.experiments,
        context_data.experiments
      )

    {var_index, exp_index, aud_cache} = build_indexes(context_data.experiments)

    exposed_experiments = Enum.reduce(changed_names, state.exposed_experiments, fn name, acc ->
      if Map.has_key?(state.overrides, name) do
        acc
      else
        MapSet.delete(acc, name)
      end
    end)

    state = %{
      state
      | data: context_data,
        assignments: assignments,
        variable_index: var_index,
        experiment_index: exp_index,
        audience_cache: aud_cache,
        exposed_experiments: exposed_experiments
    }

    Logger.info("Context refreshed with #{length(context_data.experiments)} experiments")
    emit_event(state, :refresh, %{experiments: context_data.experiments})
    state
  end

  defp get_or_assign(state, experiment) do
    name = experiment.name
    override = Map.get(state.overrides, name)

    if override != nil do
      assignment = %Types.Assignment{
        id: experiment.id,
        iteration: experiment.iteration,
        full_on_variant: experiment.full_on_variant,
        traffic_split: experiment.traffic_split,
        variant: override,
        assigned: false,
        overridden: true,
        eligible: true,
        full_on: false,
        custom: false,
        audience_mismatch: false
      }

      {assignment, state}
    else
      cached = Map.get(state.assignments, name)

      {cached, state} = maybe_reassign_for_audience(cached, state, experiment, name)

      if cached != nil do
        custom = Map.get(state.custom_assignments, name)

        if custom != nil && !cached.full_on && cached.eligible do
          custom_assignment = %{cached | variant: custom, custom: true}
          {custom_assignment, state}
        else
          {cached, state}
        end
      else
        assignment = assign_variant(state, experiment)
        state = %{state | assignments: Map.put(state.assignments, name, assignment)}

        custom = Map.get(state.custom_assignments, name)

        if custom != nil && !assignment.full_on && assignment.eligible do
          custom_assignment = %Types.Assignment{
            assignment
            | variant: custom,
              custom: true
          }

          {custom_assignment, state}
        else
          {assignment, state}
        end
      end
    end
  end

  defp maybe_reassign_for_audience(nil, state, _experiment, _name), do: {nil, state}
  defp maybe_reassign_for_audience(cached, state, experiment, name) do
    has_audience = experiment.audience != nil and experiment.audience != ""

    if has_audience and cached.audience_match_seq < state.attrs_seq do
      new_assignment = assign_variant(state, experiment)
      if new_assignment.audience_mismatch != cached.audience_mismatch do
        state = %{state |
          assignments: Map.put(state.assignments, name, new_assignment),
          exposed_experiments: MapSet.delete(state.exposed_experiments, name)
        }
        {new_assignment, state}
      else
        updated = %{cached | audience_match_seq: state.attrs_seq}
        state = %{state | assignments: Map.put(state.assignments, name, updated)}
        {updated, state}
      end
    else
      {cached, state}
    end
  end

  defp assign_variant(state, experiment) do
    unit_type = experiment.unit_type || "session_id"
    uid = Map.get(state.units, unit_type)
    base = %{base_assignment(experiment) | audience_match_seq: state.attrs_seq}

    cond do
      is_nil(uid) ->
        %{base | eligible: false}

      true ->
        hashed_unit = Utils.hash_unit(uid)
        audience_matched = audience_match?(state, experiment)

        cond do
          not audience_matched && experiment.audience_strict ->
            %{base | audience_mismatch: true}

          full_on?(experiment) ->
            %{
              base
              | variant: experiment.full_on_variant,
                assigned: true,
                full_on: true,
                audience_mismatch: !audience_matched
            }

          not traffic_eligible?(hashed_unit, experiment) ->
            %{
              base
              | assigned: true,
                eligible: false,
                audience_mismatch: !audience_matched
            }

          true ->
            variant =
              VariantAssigner.assign(
                hashed_unit,
                experiment.split,
                experiment.seed_hi,
                experiment.seed_lo
              )

            %{
              base
              | variant: variant,
                assigned: true,
                audience_mismatch: !audience_matched
            }
        end
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
      audience_mismatch: false
    }
  end

  defp audience_match?(state, experiment) do
    case experiment.audience do
      nil -> true
      "" -> true
      _audience ->
        parsed = Map.get(state.audience_cache, experiment.name)
        if parsed do
          attrs_list = Enum.map(state.attributes, fn attr ->
            %{"name" => attr.name, "value" => attr.value}
          end)
          Matcher.evaluate(parsed, attrs_list) == true
        else
          true
        end
    end
  end

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
        Logger.error(
          "Failed to parse audience JSON: #{inspect(error)}, audience: #{audience}"
        )

        %{"invalid" => true}
    end
  end

  defp parse_audience(audience) when is_map(audience), do: audience
  defp parse_audience(_), do: nil

  defp create_exposure(experiment, assignment) do
    unit_type = experiment.unit_type || "session_id"

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
      audience_mismatch: assignment.audience_mismatch
    }
  end

  defp build_indexes(experiments) do
    exp_index = Enum.into(experiments, %{}, fn exp -> {exp.name, exp} end)

    aud_cache = Enum.reduce(experiments, %{}, fn experiment, cache ->
      case experiment.audience do
        nil -> cache
        "" -> cache
        audience ->
          parsed = parse_audience(audience)
          if parsed, do: Map.put(cache, experiment.name, parsed), else: cache
      end
    end)

    var_index = Enum.reduce(experiments, %{}, fn experiment, index ->
      keys_in_experiment = Enum.reduce(experiment.variants || [], MapSet.new(), fn variant, keys ->
        config = parse_variant_config(variant["config"]) || %{}
        Enum.reduce(Map.keys(config), keys, &MapSet.put(&2, &1))
      end)

      Enum.reduce(keys_in_experiment, index, fn key, idx ->
        Map.update(idx, key, [experiment], fn exps -> [experiment | exps] end)
      end)
    end)

    reversed_var_index = Map.new(var_index, fn {key, exps} -> {key, Enum.reverse(exps)} end)

    {reversed_var_index, exp_index, aud_cache}
  end

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
        old_exp.split != new_exp.split -> true
        true -> false
      end
    end)
  end

  defp invalidate_changed_assignments(assignments, old_experiments, new_experiments) do
    old_exp_map = Enum.into(old_experiments, %{}, fn exp -> {exp.name, exp} end)
    new_exp_map = Enum.into(new_experiments, %{}, fn exp -> {exp.name, exp} end)

    Enum.reduce(assignments, %{}, fn {name, assignment}, acc ->
      old_exp = Map.get(old_exp_map, name)
      new_exp = Map.get(new_exp_map, name)

      keep =
        cond do
          assignment.overridden -> true
          is_nil(old_exp) && is_nil(new_exp) -> true
          is_nil(old_exp) -> false
          is_nil(new_exp) -> false
          old_exp.id != new_exp.id -> false
          old_exp.iteration != new_exp.iteration -> false
          old_exp.full_on_variant != new_exp.full_on_variant -> false
          old_exp.traffic_split != new_exp.traffic_split -> false
          old_exp.split != new_exp.split -> false
          true -> true
        end

      if keep do
        Map.put(acc, name, assignment)
      else
        acc
      end
    end)
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
          Data: #{inspect(data)}
          """)
      end
    end

    :ok
  end

  defp now_millis do
    System.system_time(:millisecond)
  end
end
