defmodule ABSmartly do
  @moduledoc """
  ABSmartly SDK for Elixir.

  Official Elixir SDK for the ABSmartly experimentation platform.

  ## Usage

      # Configure SDK with keyword list
      {:ok, sdk} = ABSmartly.new(
        endpoint: "https://your-company.absmartly.io/v1",
        api_key: "YOUR-API-KEY",
        application: "website",
        environment: "development"
      )

      # Create context
      {:ok, context} = ABSmartly.create_context(sdk, %{"session_id" => "abc123"})

      # Get treatment
      variant = ABSmartly.Context.treatment(context, "exp_test")

      # Track goal
      ABSmartly.Context.track(context, "purchase", %{amount: 99.99})

      # Publish events
      ABSmartly.Context.publish(context)

      # Finalize and release the context process
      ABSmartly.Context.dispose(context)

  ## Pipe-friendly API

      {:ok, sdk} = ABSmartly.new(endpoint: "...", api_key: "...", ...)
        |> ABSmartly.with_timeout(5000)
        |> ABSmartly.with_retries(3)
  """

  defdelegate new(opts), to: ABSmartly.SDK
  defdelegate with_timeout(sdk, timeout), to: ABSmartly.SDK
  defdelegate with_retries(sdk, retries), to: ABSmartly.SDK
  defdelegate create_context(sdk, units, options \\ %{}), to: ABSmartly.SDK
  defdelegate create_context_async(sdk, units, options \\ %{}), to: ABSmartly.SDK
  defdelegate create_context_with(sdk, units, data, options \\ %{}), to: ABSmartly.SDK

  @version Mix.Project.config()[:version]

  def version, do: @version
end
