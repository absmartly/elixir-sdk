defmodule ABSmartly.Types do
  @moduledoc """
  Core data structures for ABSmartly SDK.
  """

  defmodule SDKConfig do
    @moduledoc """
    Configuration for SDK initialization.
    """
    @type t :: %__MODULE__{
            endpoint: String.t(),
            api_key: String.t(),
            application: String.t(),
            environment: String.t(),
            retries: non_neg_integer(),
            timeout: non_neg_integer(),
            publisher: module()
          }

    @enforce_keys [:endpoint, :api_key, :application, :environment]
    defstruct [
      :endpoint,
      :api_key,
      :application,
      :environment,
      retries: 5,
      timeout: 3000,
      publisher: ABSmartly.DefaultContextPublisher
    ]
  end

  defimpl Inspect, for: SDKConfig do
    def inspect(config, _opts) do
      "#SDKConfig<endpoint: #{config.endpoint}, app: #{config.application}, env: #{config.environment}>"
    end
  end

  defmodule ExperimentData do
    @moduledoc """
    Experiment configuration from API.
    """
    require Logger

    defstruct [
      :id,
      :name,
      :unit_type,
      :iteration,
      :seed_hi,
      :seed_lo,
      :split,
      :traffic_seed_hi,
      :traffic_seed_lo,
      :traffic_split,
      :full_on_variant,
      :applications,
      :variants,
      :audience_strict,
      :audience,
      :assignment_rules,
      :custom_field_values,
      :holdout_ids,
      :holdout_type,
      :randomization_type,
      :switchback_clusters,
      :switchback_cluster_values,
      :switchback_start_at,
      :switchback_period_ms,
      :switchback_carryover_duration_ms,
      :switchback_burn_in_duration_ms,
      :switchback_burn_out_duration_ms,
      :switchback_design_type,
      :switchback_estimand
    ]

    @doc """
    Create ExperimentData from API JSON.

    `switchbackClusters` is an ordered object, and its order decides which
    unit serves a switchback experiment. It is kept as a `Jason.OrderedObject`
    when it is one (as `ABSmartly.HTTP.Client.fetch_context/6` decodes it) or
    a list of `{unit_type, path}` pairs. A plain map has no order, so one with
    more than one entry cannot be served: the experiment is an ineligible
    control and records no exposure.
    """
    def from_map(map) when is_map(map) do
      required_fields = ["id", "name", "unitType", "split"]
      missing = Enum.filter(required_fields, &is_nil(map[&1]))

      if missing != [] do
        raise ArgumentError, "Missing required experiment fields: #{inspect(missing)}"
      end

      split = map["split"] || []

      if is_list(split) and length(split) > 100 do
        raise ArgumentError,
              "Split array too large (#{length(split)}), maximum 100 variants allowed"
      end

      ABSmartly.Types.ExperimentValidation.validate!(map, split)

      %__MODULE__{
        id: map["id"],
        name: map["name"],
        unit_type: map["unitType"],
        iteration: map["iteration"] || 0,
        seed_hi: map["seedHi"] || 0,
        seed_lo: map["seedLo"] || 0,
        split: split,
        traffic_seed_hi: map["trafficSeedHi"],
        traffic_seed_lo: map["trafficSeedLo"],
        traffic_split: map["trafficSplit"] || [],
        full_on_variant: map["fullOnVariant"],
        applications: map["applications"] || [],
        variants: map["variants"] || [],
        audience_strict: map["audienceStrict"] || false,
        audience: map["audience"],
        assignment_rules: assignment_rules(map),
        custom_field_values: map["customFieldValues"],
        holdout_ids: holdout_ids(map["holdoutIds"]),
        holdout_type: if(is_binary(map["holdoutType"]), do: map["holdoutType"]),
        randomization_type: string_or_nil(map["randomizationType"]),
        switchback_clusters: switchback_clusters(map),
        switchback_cluster_values: switchback_cluster_values(map["switchbackClusterValues"]),
        switchback_start_at: integer_or_nil(map["switchbackStartAt"]),
        switchback_period_ms: integer_or_nil(map["switchbackPeriodMs"]),
        switchback_carryover_duration_ms: integer_or_nil(map["switchbackCarryoverDurationMs"]),
        switchback_burn_in_duration_ms: integer_or_nil(map["switchbackBurnInDurationMs"]),
        switchback_burn_out_duration_ms: integer_or_nil(map["switchbackBurnOutDurationMs"]),
        switchback_design_type: string_or_nil(map["switchbackDesignType"]),
        switchback_estimand: string_or_nil(map["switchbackEstimand"])
      }
    end

    # Like an unknown field, a switchback field of an unexpected type never
    # fails the context: it is nil, which makes a switchback unservable.
    defp string_or_nil(value) when is_binary(value), do: value
    defp string_or_nil(_value), do: nil

    defp integer_or_nil(value), do: ABSmartly.Types.HoldoutData.integer_id(value)

    defp switchback_clusters(map) do
      case map["switchbackClusters"] do
        nil ->
          nil

        %Jason.OrderedObject{} = clusters ->
          clusters

        pairs when is_list(pairs) ->
          if Enum.all?(pairs, &match?({_, _}, &1)), do: %Jason.OrderedObject{values: pairs}

        %{} = clusters when map_size(clusters) <= 1 and not is_struct(clusters) ->
          %Jason.OrderedObject{values: Map.to_list(clusters)}

        %{} = clusters when not is_struct(clusters) ->
          Logger.warning(
            "Ignoring switchbackClusters for experiment #{inspect(map["name"])}: " <>
              "an unordered map of #{map_size(clusters)} entries has no declared order"
          )

          nil

        _other ->
          nil
      end
    end

    # The allow-list. An integer is its base-10 text, as Jackson reads it into
    # the Java SDK's String[]; other non-strings never match a cluster key but
    # keep the list non-empty, so they never widen it to every value.
    defp switchback_cluster_values(values) when is_list(values),
      do: Enum.map(values, &if(is_integer(&1), do: Integer.to_string(&1), else: &1))

    defp switchback_cluster_values(_values), do: nil

    # The ids of the holdouts covering this experiment. Like an unknown field,
    # a value that is not a list of integers never fails the context: anything
    # else in it is ignored. An integral float (`11.0`) is the integer, as in
    # the JavaScript SDK.
    defp holdout_ids(ids) when is_list(ids) do
      case for(id <- ids, id = ABSmartly.Types.HoldoutData.integer_id(id), do: id) do
        [] -> nil
        ids -> ids
      end
    end

    defp holdout_ids(_), do: nil

    # The API sends `assignmentRules` as a JSON string. Anything else (an
    # object, a list, a number) is ignored for this experiment only, like the
    # Java SDK's AssignmentRulesDeserializer. An empty string means no rules.
    defp assignment_rules(map) do
      case map["assignmentRules"] do
        rules when rules in [nil, ""] ->
          nil

        rules when is_binary(rules) ->
          rules

        other ->
          Logger.warning(
            "Ignoring assignmentRules for experiment #{inspect(map["name"])}: " <>
              "expected a JSON string but got #{inspect(other)}"
          )

          nil
      end
    end
  end

  defmodule ExperimentValidation do
    @moduledoc false
    # Shape checks for the fields consumed by assignment, so schema-invalid
    # collector payloads are rejected up front instead of crashing evaluation.
    def validate!(map, split) do
      check!(is_binary(map["name"]), "name must be a string")
      check!(is_binary(map["unitType"]), "unitType must be a string")
      check!(number_list?(split), "split must be a list of numbers")

      traffic = map["trafficSplit"]
      check!(is_nil(traffic) or number_list?(traffic), "trafficSplit must be a list of numbers")

      for key <- [
            "iteration",
            "seedHi",
            "seedLo",
            "trafficSeedHi",
            "trafficSeedLo",
            "fullOnVariant"
          ] do
        value = map[key]
        check!(is_nil(value) or is_integer(value), "#{key} must be an integer")
      end

      for key <- ["variants", "applications"] do
        value = map[key]
        check!(is_nil(value) or is_list(value), "#{key} must be a list")
      end

      cfv = map["customFieldValues"]

      check!(
        is_nil(cfv) or (is_list(cfv) and Enum.all?(cfv, &custom_field?/1)),
        "customFieldValues must be a list of objects with a string name, optional string type and scalar value"
      )

      :ok
    end

    defp custom_field?(%{} = f) do
      is_binary(f["name"]) and (is_nil(f["type"]) or is_binary(f["type"])) and
        (is_nil(f["value"]) or is_binary(f["value"]) or is_number(f["value"]) or
           is_boolean(f["value"]))
    end

    defp custom_field?(_), do: false

    defp number_list?(list), do: is_list(list) and Enum.all?(list, &is_number/1)

    defp check!(true, _msg), do: :ok
    defp check!(_, msg), do: raise(ArgumentError, "Invalid experiment data: " <> msg)
  end

  defmodule HoldoutData do
    @moduledoc """
    A holdout from the API's `holdouts` list.

    An experiment is covered by the holdouts listed in its `holdoutIds`. A
    unit in a holdout's arm 0 is held out of every experiment it covers; with
    a three-arm `split`, arm 1 holds it out of the covered experiments that
    are not full-on.
    """
    defstruct [
      :id,
      :name,
      :unit_type,
      :holdout_type,
      iteration: 0,
      seed_hi: 0,
      seed_lo: 0,
      split: []
    ]

    @doc """
    Create HoldoutData from an entry of the API's `holdouts` list.

    Returns `nil` for an entry that is not an object with an integer `id`.
    Other fields with an unexpected type get their default, and unknown fields
    are ignored, so a malformed holdout never fails the context.
    """
    def from_map(%{"id" => id} = map) do
      case integer_id(id) do
        nil -> nil
        id -> from_map(map, id)
      end
    end

    def from_map(_), do: nil

    defp from_map(map, id) do
      split = map["split"]

      %__MODULE__{
        id: id,
        name: map["name"],
        unit_type: if(is_binary(map["unitType"]), do: map["unitType"]),
        holdout_type: if(is_binary(map["holdoutType"]), do: map["holdoutType"]),
        iteration: integer_or(map["iteration"], 0),
        seed_hi: integer_or(map["seedHi"], 0),
        seed_lo: integer_or(map["seedLo"], 0),
        split: if(is_list(split) and Enum.all?(split, &is_number/1), do: split, else: [])
      }
    end

    # An integer, or an integral float (`11.0`), as the integer; the
    # JavaScript SDK makes no difference between `11.0` and `11`.
    @doc false
    def integer_id(id) when is_integer(id), do: id
    def integer_id(id) when is_float(id) and id == trunc(id), do: trunc(id)
    def integer_id(_id), do: nil

    # An integral float (`13.0`) is the integer, as in the JavaScript SDK.
    defp integer_or(value, default) do
      case integer_id(value) do
        nil -> default
        integer -> integer
      end
    end
  end

  defmodule ContextData do
    @moduledoc """
    Context data containing experiments and the holdouts covering them.
    """
    defstruct experiments: [], holdouts: []

    @doc """
    Create ContextData from API JSON.
    """
    def from_map(map) when is_map(map) do
      experiments =
        (map["experiments"] || [])
        |> Enum.map(&ExperimentData.from_map/1)

      %__MODULE__{experiments: experiments, holdouts: holdouts(map["holdouts"])}
    end

    def from_map(other) do
      raise ArgumentError, "Expected context data to be a map, got: #{inspect(other)}"
    end

    defp holdouts(holdouts) when is_list(holdouts) do
      for entry <- holdouts, holdout = HoldoutData.from_map(entry), do: holdout
    end

    defp holdouts(_), do: []
  end

  defmodule Assignment do
    @moduledoc """
    Cached variant assignment.
    """
    defstruct [
      :id,
      :iteration,
      :full_on_variant,
      :traffic_split,
      :variant,
      assigned: false,
      overridden: false,
      eligible: true,
      full_on: false,
      custom: false,
      audience_mismatch: false,
      rule_override: false,
      rule_variant: nil,
      rule_missing_unit: false,
      rule_key: nil,
      audience_match_seq: 0,
      suppressed: false,
      holdout_arms: nil
    ]
  end

  defmodule Exposure do
    @moduledoc """
    Exposure event for publishing.
    """
    defstruct [
      :id,
      :name,
      :unit,
      :variant,
      :exposed_at,
      :assigned,
      :eligible,
      :overridden,
      :full_on,
      :custom,
      :audience_mismatch,
      :rule_override
    ]

    @doc """
    Convert to map for JSON serialization.
    """
    def to_map(%__MODULE__{} = exposure) do
      %{
        "id" => exposure.id,
        "name" => exposure.name,
        "unit" => exposure.unit,
        "variant" => exposure.variant,
        "exposedAt" => exposure.exposed_at,
        "assigned" => exposure.assigned,
        "eligible" => exposure.eligible,
        "overridden" => exposure.overridden,
        "fullOn" => exposure.full_on,
        "custom" => exposure.custom,
        "audienceMismatch" => exposure.audience_mismatch,
        "ruleOverride" => exposure.rule_override
      }
    end
  end

  defmodule Goal do
    @moduledoc """
    Goal achievement event.
    """
    defstruct [:name, :achieved_at, :properties]

    @doc """
    Convert to map for JSON serialization.
    """
    def to_map(%__MODULE__{} = goal) do
      %{
        "name" => goal.name,
        "achievedAt" => goal.achieved_at,
        "properties" => goal.properties
      }
    end
  end

  defmodule PublishEvent do
    @moduledoc """
    Publish event data.
    """
    defstruct [
      :hashed,
      :published_at,
      :units,
      :exposures,
      :goals,
      :attributes
    ]

    @doc """
    Convert to map for JSON serialization.
    """
    def to_map(%__MODULE__{} = event) do
      %{
        "hashed" => event.hashed,
        "publishedAt" => event.published_at,
        "units" => event.units,
        "exposures" => Enum.map(event.exposures, &Exposure.to_map/1),
        "goals" => Enum.map(event.goals, &Goal.to_map/1),
        "attributes" => event.attributes
      }
    end
  end

  defmodule ContextConfig do
    @moduledoc """
    Configuration for context creation.
    """
    defstruct units: %{},
              attributes: [],
              overrides: %{},
              custom_assignments: %{},
              publish_delay: -1,
              refresh_period: 0,
              event_handler: nil

    @doc """
    Create from options map.
    """
    def from_options(opts) when is_map(opts) do
      %__MODULE__{
        units: get_opt(opts, "units", :units, %{}),
        attributes: get_opt(opts, "attributes", :attributes, []),
        overrides: get_opt(opts, "overrides", :overrides, %{}),
        custom_assignments: get_opt(opts, "customAssignments", :custom_assignments, %{}),
        publish_delay: get_opt(opts, "publishDelay", :publish_delay, -1),
        refresh_period: get_opt(opts, "refreshPeriod", :refresh_period, 0),
        event_handler: get_opt(opts, "eventHandler", :event_handler, nil)
      }
    end

    defp get_opt(opts, string_key, atom_key, default) do
      cond do
        Map.has_key?(opts, string_key) -> Map.get(opts, string_key, default)
        Map.has_key?(opts, atom_key) -> Map.get(opts, atom_key, default)
        true -> default
      end
    end
  end
end
