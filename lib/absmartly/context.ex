defmodule ABSmartly.Context do
  use GenServer

  alias ABSmartly.{
    Types,
    Utils,
    VariantAssigner,
    Matcher
  }

  @type t :: pid()

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
    :exposed_experiments
  ]

  def start_link(sdk_config, data, context_config) do
    GenServer.start_link(__MODULE__, {sdk_config, data, context_config})
  end

  def set_unit(context, unit_type, uid) do
    GenServer.call(context, {:set_unit, unit_type, uid})
  end

  def set_units(context, units) when is_map(units) do
    for {unit_type, uid} <- units do
      set_unit(context, unit_type, uid)
    end
    :ok
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

  def set_attributes(context, attributes) when is_map(attributes) do
    for {name, value} <- attributes do
      set_attribute(context, name, value)
    end
    :ok
  end

  def set_attributes(context, attributes) when is_list(attributes) do
    for {name, value} <- attributes do
      set_attribute(context, name, value)
    end
    :ok
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
    for {experiment_name, variant} <- overrides do
      set_override(context, experiment_name, variant)
    end
    :ok
  end

  def set_custom_assignment(context, experiment_name, variant) do
    GenServer.call(context, {:set_custom_assignment, experiment_name, variant})
  end

  def set_custom_assignments(context, assignments) when is_map(assignments) do
    for {experiment_name, variant} <- assignments do
      set_custom_assignment(context, experiment_name, variant)
    end
    :ok
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

  @impl true
  def init({sdk_config, data, context_config}) do
    event_handler = Process.get(:event_handler)

    state = %__MODULE__{
      sdk_config: sdk_config,
      data: data,
      ready: true,
      failed: false,
      finalized: false,
      finalizing: false,
      units: context_config.units || %{},
      attributes: [],
      overrides: context_config.overrides || %{},
      custom_assignments: context_config.custom_assignments || %{},
      assignments: %{},
      exposures: [],
      goals: [],
      variable_index: build_variable_index(data.experiments),
      event_handler: event_handler,
      exposed_experiments: MapSet.new()
    }

    state =
      if context_config.attributes && is_list(context_config.attributes) && length(context_config.attributes) > 0 do
        %{state | attributes: context_config.attributes}
      else
        state
      end

    emit_event(state, :ready, %{experiments: data.experiments})

    {:ok, state}
  end

  @impl true
  def handle_call({:set_unit, unit_type, uid}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      key = to_string(unit_type)
      if Map.has_key?(state.units, key) && Map.get(state.units, key) != uid do
        {:reply, {:error, :duplicate_unit}, state}
      else
        state = %{state | units: Map.put(state.units, key, to_string(uid))}
        {:reply, :ok, state}
      end
    end
  end

  def handle_call({:get_unit, unit_type}, _from, state) do
    value = Map.get(state.units, to_string(unit_type))
    {:reply, value, state}
  end

  def handle_call(:get_units, _from, state) do
    {:reply, state.units, state}
  end

  def handle_call({:set_attribute, name, value}, _from, state) do
    name_str = to_string(name)
    attributes =
      Enum.reject(state.attributes, fn attr ->
        case attr do
          %{"name" => ^name_str} -> true
          _ -> false
        end
      end)

    attributes = attributes ++ [%{"name" => name_str, "value" => value}]
    state = %{state | attributes: attributes}
    {:reply, :ok, state}
  end

  def handle_call({:get_attribute, name}, _from, state) do
    name_str = to_string(name)

    value =
      Enum.find_value(state.attributes, fn attr ->
        case attr do
          %{"name" => ^name_str, "value" => v} -> {:found, v}
          _ -> nil
        end
      end)

    result = case value do
      {:found, v} -> v
      nil -> nil
    end

    {:reply, result, state}
  end

  def handle_call(:get_attributes, _from, state) do
    {:reply, state.attributes, state}
  end

  def handle_call({:set_override, experiment_name, variant}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      state = %{state | overrides: Map.put(state.overrides, to_string(experiment_name), variant)}
      {:reply, :ok, state}
    end
  end

  def handle_call({:set_custom_assignment, experiment_name, variant}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      state = %{
        state
        | custom_assignments: Map.put(state.custom_assignments, to_string(experiment_name), variant)
      }
      {:reply, :ok, state}
    end
  end

  def handle_call({:treatment, experiment_name}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      {variant, state} = do_treatment(state, experiment_name, true)
      {:reply, variant, state}
    end
  end

  def handle_call({:peek, experiment_name}, _from, state) do
    {variant, state} = do_treatment(state, experiment_name, false)
    {:reply, variant, state}
  end

  def handle_call({:variable_value, key, default_value}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      {value, state} = do_variable_value(state, key, default_value, true)
      {:reply, value, state}
    end
  end

  def handle_call({:peek_variable_value, key, default_value}, _from, state) do
    {value, state} = do_variable_value(state, key, default_value, false)
    {:reply, value, state}
  end

  def handle_call(:variable_keys, _from, state) do
    keys = Map.keys(state.variable_index)
    {:reply, keys, state}
  end

  def handle_call({:custom_field_value, experiment_name, field_name}, _from, state) do
    value = do_custom_field_value(state, experiment_name, field_name)
    {:reply, value, state}
  end

  def handle_call({:custom_field_keys, experiment_name}, _from, state) do
    keys = do_custom_field_keys(state, experiment_name)
    {:reply, keys, state}
  end

  def handle_call({:custom_field_value_type, experiment_name, field_name}, _from, state) do
    type = do_custom_field_value_type(state, experiment_name, field_name)
    {:reply, type, state}
  end

  def handle_call({:track, goal_name, properties}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      state = do_track(state, goal_name, properties)
      {:reply, :ok, state}
    end
  end

  def handle_call(:publish, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      {result, state} = do_publish(state)
      {:reply, result, state}
    end
  end

  def handle_call(:finalize, _from, state) do
    if state.finalized or state.finalizing do
      {:reply, :ok, state}
    else
      state = %{state | finalizing: true}
      {_result, state} = do_publish(state)
      state = %{state | finalized: true, finalizing: false}
      emit_event(state, :finalize, nil)
      {:reply, :ok, state}
    end
  end

  def handle_call({:refresh, new_data}, _from, state) do
    if state.finalized do
      {:reply, {:error, :finalized}, state}
    else
      state = do_refresh(state, new_data)
      {:reply, :ok, state}
    end
  end

  def handle_call(:is_ready, _from, state) do
    {:reply, state.ready, state}
  end

  def handle_call(:is_failed, _from, state) do
    {:reply, state.failed, state}
  end

  def handle_call(:is_finalized, _from, state) do
    {:reply, state.finalized, state}
  end

  def handle_call(:is_finalizing, _from, state) do
    {:reply, state.finalizing, state}
  end

  def handle_call(:pending, _from, state) do
    count = length(state.exposures) + length(state.goals)
    {:reply, count, state}
  end

  def handle_call(:data, _from, state) do
    {:reply, state.data, state}
  end

  def handle_call(:experiments, _from, state) do
    names = Enum.map(state.data.experiments, & &1.name)
    {:reply, names, state}
  end

  defp do_treatment(state, experiment_name, queue_exposure) do
    override = Map.get(state.overrides, experiment_name)
    experiment = find_experiment(state.data.experiments, experiment_name)

    if experiment do
      {assignment, state} = get_or_assign(state, experiment)

      state =
        if queue_exposure && !MapSet.member?(state.exposed_experiments, experiment_name) do
          exposure = create_exposure(experiment, assignment)
          state = %{state | exposures: state.exposures ++ [exposure]}
          state = %{state | exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name)}
          emit_event(state, :exposure, exposure)
          state
        else
          state
        end

      {assignment.variant, state}
    else
      if override != nil do
        if queue_exposure && !MapSet.member?(state.exposed_experiments, experiment_name) do
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
          state = %{state | exposures: state.exposures ++ [exposure]}
          state = %{state | exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name)}
          emit_event(state, :exposure, exposure)
          {override, state}
        else
          {override, state}
        end
      else
        if queue_exposure && !MapSet.member?(state.exposed_experiments, experiment_name) do
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
          state = %{state | exposures: state.exposures ++ [exposure]}
          state = %{state | exposed_experiments: MapSet.put(state.exposed_experiments, experiment_name)}
          emit_event(state, :exposure, exposure)
          {0, state}
        else
          {0, state}
        end
      end
    end
  end

  defp do_variable_value(state, key, default_value, queue_exposure) do
    experiments = Map.get(state.variable_index, key, [])

    {result, state} =
      Enum.reduce(experiments, {nil, state}, fn exp, {found, acc_state} ->
        {assignment, acc_state} = get_or_assign(acc_state, exp)

        acc_state =
          if queue_exposure && !MapSet.member?(acc_state.exposed_experiments, exp.name) do
            exposure = create_exposure(exp, assignment)
            acc_state = %{acc_state | exposures: acc_state.exposures ++ [exposure]}
            acc_state = %{acc_state | exposed_experiments: MapSet.put(acc_state.exposed_experiments, exp.name)}
            emit_event(acc_state, :exposure, exposure)
            acc_state
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
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp parse_variant_config(_), do: nil

  defp do_custom_field_value(state, experiment_name, field_name) do
    experiment = find_experiment(state.data.experiments, experiment_name)

    if experiment && experiment.custom_field_values do
      custom_field = Enum.find(experiment.custom_field_values, fn field ->
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
      custom_field = Enum.find(experiment.custom_field_values, fn field ->
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
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp parse_custom_field(value, _type), do: value

  defp do_track(state, goal_name, properties) do
    filtered_properties =
      case properties do
        map when is_map(map) ->
          map
          |> Enum.filter(fn {_k, v} -> is_number(v) or is_nil(v) end)
          |> Enum.into(%{})

        nil ->
          nil

        _ ->
          nil
      end

    goal = %Types.Goal{
      name: goal_name,
      achieved_at: now_millis(),
      properties: filtered_properties
    }

    state = %{state | goals: state.goals ++ [goal]}
    emit_event(state, :goal, goal)
    state
  end

  defp do_publish(state) do
    if length(state.exposures) > 0 or length(state.goals) > 0 do
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
        exposures: state.exposures,
        goals: state.goals,
        attributes: state.attributes
      }

      emit_event(state, :publish, publish_event)

      {:ok, %{state | exposures: [], goals: []}}
    else
      {:ok, state}
    end
  end

  defp do_refresh(state, new_data) do
    context_data = Types.ContextData.from_map(new_data)

    assignments = invalidate_changed_assignments(state.assignments, state.data.experiments, context_data.experiments)

    exposed_after = Enum.reduce(state.exposed_experiments, MapSet.new(), fn name, acc ->
      if Map.has_key?(assignments, name) || Map.has_key?(state.overrides, name) do
        MapSet.put(acc, name)
      else
        acc
      end
    end)

    state = %{
      state
      | data: context_data,
        assignments: assignments,
        variable_index: build_variable_index(context_data.experiments),
        exposed_experiments: exposed_after
    }

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
            assignment |
            variant: custom,
            custom: true
          }
          {custom_assignment, state}
        else
          {assignment, state}
        end
      end
    end
  end

  defp assign_variant(state, experiment) do
    unit_type = experiment.unit_type || "session_id"
    uid = Map.get(state.units, unit_type)

    if is_nil(uid) do
      %Types.Assignment{
        id: experiment.id,
        iteration: experiment.iteration,
        full_on_variant: experiment.full_on_variant,
        traffic_split: experiment.traffic_split,
        variant: 0,
        assigned: false,
        overridden: false,
        eligible: false,
        full_on: false,
        custom: false,
        audience_mismatch: false
      }
    else
      audience = parse_audience(experiment.audience)
      audience_match = Matcher.evaluate(audience, state.attributes)

      if audience_match == false && experiment.audience_strict do
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
          audience_mismatch: true
        }
      else
        if experiment.full_on_variant != nil && experiment.full_on_variant > 0 do
          %Types.Assignment{
            id: experiment.id,
            iteration: experiment.iteration,
            full_on_variant: experiment.full_on_variant,
            traffic_split: experiment.traffic_split,
            variant: experiment.full_on_variant,
            assigned: true,
            overridden: false,
            eligible: true,
            full_on: true,
            custom: false,
            audience_mismatch: audience_match == false
          }
        else
          hashed_unit = Utils.hash_unit(uid)

          eligible =
            if experiment.traffic_split && length(experiment.traffic_split) > 1 do
              VariantAssigner.assign(
                hashed_unit,
                experiment.traffic_split,
                experiment.traffic_seed_hi || 0,
                experiment.traffic_seed_lo || 0
              ) == 1
            else
              true
            end

          if eligible do
            variant =
              VariantAssigner.assign(
                hashed_unit,
                experiment.split,
                experiment.seed_hi || 0,
                experiment.seed_lo || 0
              )

            %Types.Assignment{
              id: experiment.id,
              iteration: experiment.iteration,
              full_on_variant: experiment.full_on_variant,
              traffic_split: experiment.traffic_split,
              variant: variant,
              assigned: true,
              overridden: false,
              eligible: true,
              full_on: false,
              custom: false,
              audience_mismatch: audience_match == false
            }
          else
            %Types.Assignment{
              id: experiment.id,
              iteration: experiment.iteration,
              full_on_variant: experiment.full_on_variant,
              traffic_split: experiment.traffic_split,
              variant: 0,
              assigned: true,
              overridden: false,
              eligible: false,
              full_on: false,
              custom: false,
              audience_mismatch: audience_match == false
            }
          end
        end
      end
    end
  end

  defp parse_audience(nil), do: nil
  defp parse_audience(""), do: nil
  defp parse_audience("null"), do: nil
  defp parse_audience("{}"), do: %{}

  defp parse_audience(audience) when is_binary(audience) do
    case Jason.decode(audience) do
      {:ok, decoded} -> decoded
      _ -> nil
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
        config = parse_variant_config(variant["config"])
        config = config || %{}

        Enum.reduce(config, inner_index, fn {key, _value}, idx ->
          Map.update(idx, key, [experiment], fn exps -> exps ++ [experiment] end)
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

  defp emit_event(state, event_type, data) do
    if state.event_handler do
      state.event_handler.(event_type, data)
    end

    :ok
  end

  defp now_millis do
    System.system_time(:millisecond)
  end
end
