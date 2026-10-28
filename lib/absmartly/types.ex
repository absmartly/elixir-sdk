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
      :custom_field_values
    ]

    @doc """
    Create ExperimentData from API JSON.
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
        custom_field_values: map["customFieldValues"]
      }
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

  defmodule ContextData do
    @moduledoc """
    Context data containing experiments.
    """
    defstruct experiments: []

    @doc """
    Create ContextData from API JSON.
    """
    def from_map(map) when is_map(map) do
      experiments =
        (map["experiments"] || [])
        |> Enum.map(&ExperimentData.from_map/1)

      %__MODULE__{experiments: experiments}
    end

    def from_map(other) do
      raise ArgumentError, "Expected context data to be a map, got: #{inspect(other)}"
    end
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
      audience_match_seq: 0
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
      :audience_mismatch
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
        "audienceMismatch" => exposure.audience_mismatch
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
