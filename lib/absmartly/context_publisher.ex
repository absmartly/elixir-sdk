defmodule ABSmartly.ContextPublisher do
  @moduledoc """
  Behaviour for publishing context events to the ABSmartly collector.
  """

  @callback publish(
              endpoint :: String.t(),
              api_key :: String.t(),
              application :: String.t(),
              environment :: String.t(),
              event_map :: map(),
              retries :: non_neg_integer()
            ) :: :ok | {:error, term()}
end
