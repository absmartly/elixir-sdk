defmodule ABSmartly.DefaultContextPublisher do
  @moduledoc """
  Default implementation of ContextPublisher that sends events via HTTP.
  """

  @behaviour ABSmartly.ContextPublisher

  alias ABSmartly.HTTP

  @impl ABSmartly.ContextPublisher
  def publish(endpoint, api_key, application, environment, event_map, retries) do
    HTTP.Client.publish_events(endpoint, api_key, application, environment, event_map, retries)
  end

  @doc """
  Like `publish/6` but also applies the SDK request timeout (ms) to each HTTP request.
  """
  def publish(endpoint, api_key, application, environment, event_map, retries, timeout) do
    HTTP.Client.publish_events(
      endpoint,
      api_key,
      application,
      environment,
      event_map,
      retries,
      timeout
    )
  end
end
