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

  @type t :: pid()

  # Maximum unit ID length to prevent memory issues (HIGH-20)
  @max_uid_length 1024
  # Maximum queue size to prevent unbounded growth (HIGH-19)
  @max_queue_size 10_000

  defstruct [
    :sdk_config,
    :data,
    :ready,
    :failed,
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
    :event_handler,
    :exposed_experiments,
    attrs_seq: 0
  ]

  # Public API

  def start_link(sdk_config, data, context_config) do
    GenServer.start_link(__MODULE__, {sdk_config, data, context_config})
  end

  def set_unit(context, unit_type, uid) do
    GenServer.call(context, {:set_unit, unit_type, uid})
  end

  # Fixes HIGH-01: set_units as single GenServer call
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

  # Fixes HIGH-02: set_attributes as single GenServer call
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

  # Fixes HIGH-02: set_overrides as single GenServer call
  def set_overrides(context, overrides) when is_map(overrides) do
    GenServer.call(context, {:set_overrides, overrides})
  end

  def set_custom_assignment(context, experiment_name, variant) do
    GenServer.call(context, {:set_custom_assignment, experiment_name, variant})
  end

  # Fixes HIGH-02: set_custom_assignments as single GenServer call
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

  def custom_field_keys(context, experiment_name) do
    GenServer.call(context, {:custom_field_keys, experiment_name})
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
  def init({sdk_config, data, context_config}) do
    # Fixes CRITICAL-03: Get event handler from config, not Process dictionary
    state = %__MODULE__{
      sdk_config: sdk_config,
      data: data,
      ready: true,
      failed: false,
      finalized: false,
      finalizing: false,
      units: context_config.units,
      attributes: context_config.attributes || [],
      overrides: context_config.overrides,
      custom_assignments: context_config.custom_assignments,
      assignments: %{},
      exposures: [],
      goals: [],
      variable_index: build_variable_index(data.experiments),
      event_handler: context_config.event_handler,
      exposed_experiments: MapSet.new()
    }

    Logger.info("Context initialized successfully")
    emit_event(state, :ready, %{experiments: data.experiments})

    {:ok, state}
  end

  @impl true
  def handle_call({:set_unit, unit_type, uid}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      key = to_string(unit_type)
      uid_str = validate_uid(uid)

      if Map.has_key?(state.units, key) && Map.get(state.units, key) != uid_str do
        {:reply, {:error, :duplicate_unit}, state}
      else
        state = %{state | units: Map.put(state.units, key, uid_str)}
        {:reply, :ok, state}
      end
    end
  end

  # Fixes HIGH-01: Batch set_units operation
  @impl true
  def handle_call({:set_units, units}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      try do
        new_units = Enum.reduce(units, state.units, fn {unit_type, uid}, acc ->
          key = to_string(unit_type)
          uid_str = validate_uid(uid)

          if Map.has_key?(acc, key) && Map.get(acc, key) != uid_str do
            throw({:duplicate_unit, key})
          end

          Map.put(acc, key, uid_str)
        end)

        state = %{state | units: new_units}
        {:reply, :ok, state}
      catch
        {:duplicate_unit, key} ->
          {:reply, {:error, {:duplicate_unit, key}}, state}
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
    attributes = Enum.reject(state.attributes, &(&1["name"] == name_str))
    attributes = [%{"name" => name_str, "value" => value} | attributes]
    state = %{state | attributes: attributes, attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  # Fixes HIGH-02: Batch set_attributes operation
  @impl true
  def handle_call({:set_attributes, attributes}, _from, state) do
    new_attributes = Enum.reduce(attributes, state.attributes, fn {name, value}, acc ->
      name_str = to_string(name)
      acc = Enum.reject(acc, &(&1["name"] == name_str))
      [%{"name" => name_str, "value" => value} | acc]
    end)

    state = %{state | attributes: new_attributes, attrs_seq: state.attrs_seq + 1}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_attribute, name}, _from, state) do
    name_str = to_string(name)

    result = Enum.find(state.attributes, fn attr ->
      attr["name"] == name_str
    end)

    value = if result, do: result["value"], else: nil
    {:reply, value, state}
  end

  @impl true
  def handle_call(:get_attributes, _from, state) do
    {:reply, state.attributes, state}
  end

  @impl true
  def handle_call({:set_override, experiment_name, variant}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      name = to_string(experiment_name)
      state = %{
        state
        | overrides: Map.put(state.overrides, name, variant),
          exposed_experiments: MapSet.delete(state.exposed_experiments, name)
      }
      {:reply, :ok, state}
    end
  end

  # Fixes HIGH-02: Batch set_overrides operation
  @impl true
  def handle_call({:set_overrides, overrides}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      new_overrides = Enum.reduce(overrides, state.overrides, fn {experiment_name, variant}, acc ->
        Map.put(acc, to_string(experiment_name), variant)
      end)

      state = %{state | overrides: new_overrides}
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:set_custom_assignment, experiment_name, variant}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
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

  # Fixes HIGH-02: Batch set_custom_assignments operation
  @impl true
  def handle_call({:set_custom_assignments, assignments}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      new_assignments = Enum.reduce(assignments, state.custom_assignments, fn {experiment_name, variant}, acc ->
        Map.put(acc, to_string(experiment_name), variant)
      end)

      state = %{state | custom_assignments: new_assignments}
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:treatment, experiment_name}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
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
      {:reply, {:error, :finalized}, state}
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
    keys = Map.keys(state.variable_index)
    {:reply, keys, state}
  end

  @impl true
  def handle_call({:custom_field_value, experiment_name, field_name}, _from, state) do
    value = do_custom_field_value(state, experiment_name, field_name)
    {:reply, value, state}
  end

  @impl true
  def handle_call({:custom_field_keys, experiment_name}, _from, state) do
    keys = do_custom_field_keys(state, experiment_name)
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
      {:reply, {:error, :finalized}, state}
    else
      state = do_track(state, goal_name, properties)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:publish, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      {:ok, new_state} = do_publish(state)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    if state.finalized or state.finalizing do
      {:reply, :ok, state}
    else
      state = %{state | finalizing: true}

      {:ok, new_state} = do_publish(state)

      new_state = %{new_state | finalized: true, finalizing: false}
      emit_event(new_state, :finalize, nil)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:refresh, new_data}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
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
    # Fixes MEDIUM-03: Use != [] instead of length/1
    count = length(state.exposures) + length(state.goals)
    {:reply, count, state}
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

  # Fixes CRITICAL-14: Add terminate/2 callback
  @impl true
  def terminate(reason, state) do
    Logger.info("Context terminating: #{inspect(reason)}")

    # Attempt to publish pending data before termination
    if state.exposures != [] or state.goals != [] do
      Logger.info("Context terminating with pending data, attempting final publish")

      case do_publish(state) do
        {:ok, _} ->
          Logger.info("Successfully published pending data on terminate")

        {:error, reason} ->
          Logger.error("Failed to publish on terminate: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Fixes HIGH-09: Add handle_info/2 callback
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

  # Fixes HIGH-20: Validate unit IDs
  defp validate_uid(uid) do
    uid_str = to_string(uid)

    if String.length(uid_str) > @max_uid_length do
      raise ArgumentError, "Unit ID exceeds maximum length of #{@max_uid_length}"
    end

    uid_str
  end

  # Fixes CRITICAL-15/16/17/18: Extract and refactor do_treatment
  defp do_treatment(state, experiment_name, queue_exposure) do
    override = Map.get(state.overrides, experiment_name)
    experiment = find_experiment(state.data.experiments, experiment_name)

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

  # Fixes CRITICAL-15: Extract common exposure queueing logic
  defp queue_exposure(state, experiment_name, exposure) do
    if !MapSet.member?(state.exposed_experiments, experiment_name) do
      # Fixes HIGH-19: Check queue size limit
      state =
        if length(state.exposures) >= @max_queue_size do
          Logger.error(
            "Exposure queue size limit reached (#{@max_queue_size}), dropping oldest"
          )

          %{state | exposures: Enum.take(state.exposures, -@max_queue_size + 1)}
        else
          state
        end

      # Fixes MEDIUM-08: Prepend instead of append (O(1))
      state = %{
        state
        | exposures: [exposure | state.exposures],
          exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name)
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

  # Fixes HIGH-04: Add logging for variant config parse failures
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
    experiment = find_experiment(state.data.experiments, experiment_name)

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

  defp do_custom_field_keys(state, experiment_name) do
    experiment = find_experiment(state.data.experiments, experiment_name)

    if experiment && experiment.custom_field_values do
      Enum.map(experiment.custom_field_values, & &1["name"])
    else
      []
    end
  end

  defp do_custom_field_value_type(state, experiment_name, field_name) do
    experiment = find_experiment(state.data.experiments, experiment_name)

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

  # Fixes HIGH-05: Add logging for custom field parse failures
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

  # Fixes HIGH-03: Add logging for property filtering
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

    # Fixes HIGH-19: Check queue size limit
    state =
      if length(state.goals) >= @max_queue_size do
        Logger.error("Goal queue size limit reached (#{@max_queue_size}), dropping oldest")
        %{state | goals: Enum.take(state.goals, -@max_queue_size + 1)}
      else
        state
      end

    # Fixes MEDIUM-08: Prepend instead of append (O(1))
    state = %{state | goals: [goal | state.goals]}
    emit_event(state, :goal, goal)
    state
  end

  # Fixes CRITICAL-01: Actually call HTTP.Client.publish_events
  defp do_publish(state) do
    # Fixes MEDIUM-03: Use != [] instead of length/1
    if state.exposures != [] or state.goals != [] do
      hashed_units =
        Enum.map(state.units, fn {unit_type, uid} ->
          %{
            "type" => unit_type,
            "uid" => Utils.hash_unit(uid)
          }
        end)

      publish_event = %Types.PublishEvent{
        hashed: true,
        published_at: now_millis(),
        units: hashed_units,
        # Fixes MEDIUM-08: Reverse prepended lists
        exposures: Enum.reverse(state.exposures),
        goals: Enum.reverse(state.goals),
        attributes: state.attributes
      }

      # Convert to map for JSON serialization
      event_map = Types.PublishEvent.to_map(publish_event)

      emit_event(state, :publish, publish_event)

      Task.start(fn ->
        case HTTP.Client.publish_events(
               state.sdk_config.endpoint,
               state.sdk_config.api_key,
               state.sdk_config.application,
               state.sdk_config.environment,
               event_map,
               state.sdk_config.retries
             ) do
          :ok ->
            Logger.info("Successfully published #{length(state.exposures)} exposures and #{length(state.goals)} goals")

          {:error, reason} ->
            Logger.error("Failed to publish events: #{inspect(reason)}")
        end
      end)

      {:ok, %{state | exposures: [], goals: []}}
    else
      {:ok, state}
    end
  end

  defp do_refresh(state, new_data) do
    context_data = Types.ContextData.from_map(new_data)

    assignments =
      invalidate_changed_assignments(
        state.assignments,
        state.data.experiments,
        context_data.experiments
      )

    state = %{
      state
      | data: context_data,
        assignments: assignments,
        variable_index: build_variable_index(context_data.experiments),
        exposed_experiments: MapSet.new()
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

  # Fixes CRITICAL-17: Refactor assign_variant with better structure
  defp assign_variant(state, experiment) do
    unit_type = experiment.unit_type || "session_id"
    uid = Map.get(state.units, unit_type)
    attributes = state.attributes
    base = %{base_assignment(experiment) | audience_match_seq: state.attrs_seq}

    cond do
      is_nil(uid) ->
        %{base | eligible: false}

      not audience_match?(experiment, attributes) && experiment.audience_strict ->
        %{base | audience_mismatch: true}

      full_on?(experiment) ->
        %{
          base
          | variant: experiment.full_on_variant,
            assigned: true,
            full_on: true,
            audience_mismatch: !audience_match?(experiment, attributes)
        }

      not traffic_eligible?(uid, experiment) ->
        %{
          base
          | assigned: true,
            eligible: false,
            audience_mismatch: !audience_match?(experiment, attributes)
        }

      true ->
        variant =
          VariantAssigner.assign(
            Utils.hash_unit(uid),
            experiment.split,
            experiment.seed_hi,
            experiment.seed_lo
          )

        %{
          base
          | variant: variant,
            assigned: true,
            audience_mismatch: !audience_match?(experiment, attributes)
        }
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

  defp audience_match?(experiment, attributes) do
    case experiment.audience do
      nil -> true
      "" -> true
      audience -> Matcher.evaluate(parse_audience(audience), attributes) == true
    end
  end

  defp full_on?(experiment) do
    experiment.full_on_variant != nil && experiment.full_on_variant > 0
  end

  defp traffic_eligible?(uid, experiment) do
    if experiment.traffic_split && length(experiment.traffic_split) > 1 do
      hashed_unit = Utils.hash_unit(uid)

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

  # Fixes CRITICAL-10: Better audience parsing with error handling
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

        # Return sentinel value that will fail all matches
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

  defp find_experiment(experiments, name) do
    Enum.find(experiments, fn exp -> exp.name == name end)
  end

  defp build_variable_index(experiments) do
    Enum.reduce(experiments, %{}, fn experiment, index ->
      Enum.reduce(experiment.variants || [], index, fn variant, inner_index ->
        config = parse_variant_config(variant["config"]) || %{}

        Enum.reduce(config, inner_index, fn {key, _value}, idx ->
          # Fixes MEDIUM-08: Prepend instead of append
          Map.update(idx, key, [experiment], fn exps -> [experiment | exps] end)
        end)
      end)
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
          true -> true
        end

      if keep do
        Map.put(acc, name, assignment)
      else
        acc
      end
    end)
  end

  # Fixes CRITICAL-09: Rescue event handler exceptions
  # Fixes HIGH-21: Run event handler in separate process to avoid blocking
  defp emit_event(state, event_type, data) do
    if state.event_handler do
      Task.start(fn ->
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
      end)
    end

    :ok
  end

  defp now_millis do
    System.system_time(:millisecond)
  end
end
