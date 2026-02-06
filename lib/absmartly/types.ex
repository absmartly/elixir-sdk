defmodule ABSmartly.Types do
  @moduledoc """
  Core data structures for ABSmartly SDK.
  """

  defmodule SDKConfig do
    @moduledoc """
    Configuration for SDK initialization.
    """
    @enforce_keys [:endpoint, :api_key, :application, :environment]
    defstruct [
      :endpoint,
      :api_key,
      :application,
      :environment,
      retries: 5,
      timeout: 3000
    ]
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
      %__MODULE__{
        id: map["id"],
        name: map["name"],
        unit_type: map["unitType"],
        iteration: map["iteration"],
        seed_hi: map["seedHi"],
        seed_lo: map["seedLo"],
        split: map["split"] || [],
        traffic_seed_hi: map["trafficSeedHi"],
        traffic_seed_lo: map["trafficSeedLo"],
        traffic_split: map["trafficSplit"] || [],
        full_on_variant: map["fullOnVariant"],
        applications: map["applications"] || [],
        variants: map["variants"] || [],
        audience_strict: map["audienceStrict"],
        audience: map["audience"],
        custom_field_values: map["customFieldValues"]
      }
    end
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
      audience_mismatch: false
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
    defstruct [
      units: %{},
      attributes: [],
      overrides: %{},
      custom_assignments: %{},
      publish_delay: -1,
      refresh_period: 0
    ]

    @doc """
    Create from options map.
    """
    def from_options(opts) when is_map(opts) do
      %__MODULE__{
        units: opts["units"] || opts[:units] || %{},
        attributes: opts["attributes"] || opts[:attributes] || [],
        overrides: opts["overrides"] || opts[:overrides] || %{},
        custom_assignments: opts["customAssignments"] || opts[:custom_assignments] || %{},
        publish_delay: opts["publishDelay"] || opts[:publish_delay] || -1,
        refresh_period: opts["refreshPeriod"] || opts[:refresh_period] || 0
      }
    end
  end
end
