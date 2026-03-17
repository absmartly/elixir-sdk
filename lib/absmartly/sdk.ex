defmodule ABSmartly.SDK do
  @moduledoc """
  Main SDK class for ABSmartly.

  Provides context creation methods:
  - `create_context/3`: Synchronous - fetches data from API, blocks until complete
  - `create_context_async/3`: Async - starts context immediately, fetches data in background
  - `create_context_with/4`: Uses pre-fetched data directly
  """

  require Logger

  alias ABSmartly.{Context, HTTP, Types}

  @type t :: %__MODULE__{
          config: Types.SDKConfig.t()
        }

  defstruct [:config]

  @doc """
  Create a new SDK instance using keyword list configuration.

  ## Required Parameters
    * `:endpoint` - The URL to your API endpoint (e.g., "https://your-company.absmartly.io/v1")
    * `:api_key` - Your API key from the Web Console
    * `:application` - The name of your application
    * `:environment` - The environment name (e.g., "production", "development")

  ## Optional Parameters
    * `:timeout` - Connection timeout in milliseconds (default: 3000)
    * `:retries` - Number of retry attempts for failed requests (default: 5)
  """
  def new(opts) when is_list(opts) do
    with :ok <- validate_required_params(opts),
         {:ok, config} <- build_config(opts) do
      {:ok, %__MODULE__{config: config}}
    end
  end

  @doc """
  Set custom timeout for the SDK instance (pipe-friendly).
  """
  def with_timeout({:ok, %__MODULE__{config: config} = sdk}, timeout) when is_integer(timeout) do
    {:ok, %{sdk | config: %{config | timeout: timeout}}}
  end

  def with_timeout({:error, _} = error, _timeout), do: error

  @doc """
  Set custom retry count for the SDK instance (pipe-friendly).
  """
  def with_retries({:ok, %__MODULE__{config: config} = sdk}, retries) when is_integer(retries) do
    {:ok, %{sdk | config: %{config | retries: retries}}}
  end

  def with_retries({:error, _} = error, _retries), do: error

  defp validate_required_params(opts) do
    required = [:endpoint, :api_key, :application, :environment]
    missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

    case missing do
      [] ->
        :ok

      missing_keys ->
        {:error,
         "Missing required parameters: #{Enum.join(missing_keys, ", ")}. " <>
           "Required: endpoint, api_key, application, environment"}
    end
  end

  defp build_config(opts) do
    config = %Types.SDKConfig{
      endpoint: Keyword.fetch!(opts, :endpoint),
      api_key: Keyword.fetch!(opts, :api_key),
      application: Keyword.fetch!(opts, :application),
      environment: Keyword.fetch!(opts, :environment),
      timeout: Keyword.get(opts, :timeout, 3000),
      retries: Keyword.get(opts, :retries, 5)
    }

    {:ok, config}
  rescue
    e in [ArgumentError, KeyError] ->
      {:error, "Failed to build config: #{Exception.message(e)}"}
  end

  @doc """
  Create context with synchronous data fetching (blocks until HTTP fetch completes).

  Use `create_context_async/3` for non-blocking context creation.
  """
  def create_context(sdk_or_result, units, options \\ %{})
  def create_context({:ok, sdk}, units, options), do: create_context(sdk, units, options)

  def create_context(%__MODULE__{} = sdk, units, options) do
    config = sdk.config

    case HTTP.Client.fetch_context(
           config.endpoint,
           config.api_key,
           config.application,
           config.environment,
           config.retries
         ) do
      {:ok, data} ->
        context_data = Types.ContextData.from_map(data)
        create_context_with(sdk, units, context_data, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create context with async data fetching (non-blocking).

  The context is created immediately and data is fetched in the background.
  Use `Context.wait_until_ready/2` to block until data is available.
  """
  def create_context_async(sdk_or_result, units, options \\ %{})
  def create_context_async({:ok, sdk}, units, options), do: create_context_async(sdk, units, options)

  def create_context_async(%__MODULE__{} = sdk, units, options) do
    config = sdk.config

    context_config =
      options
      |> Map.put(:units, units)
      |> Types.ContextConfig.from_options()

    case DynamicSupervisor.start_child(
           ABSmartly.ContextSupervisor,
           {Context, [config, context_config]}
         ) do
      {:ok, ctx} ->
        Task.start_link(fn ->
          case HTTP.Client.fetch_context(
                 config.endpoint,
                 config.api_key,
                 config.application,
                 config.environment,
                 config.retries
               ) do
            {:ok, data} ->
              Context.set_data(ctx, data)

            {:error, reason} ->
              Logger.error("Async context fetch failed: #{inspect(reason)}")
              Context.set_failed(ctx, reason)
          end
        end)

        {:ok, ctx}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create context with pre-fetched data (synchronous).
  """
  def create_context_with(sdk_or_result, units, data, options \\ %{})

  def create_context_with({:ok, sdk}, units, data, options),
    do: create_context_with(sdk, units, data, options)

  def create_context_with(%__MODULE__{} = sdk, units, %Types.ContextData{} = data, options) do
    context_config =
      options
      |> Map.put(:units, units)
      |> Types.ContextConfig.from_options()

    DynamicSupervisor.start_child(
      ABSmartly.ContextSupervisor,
      {Context, [sdk.config, data, context_config]}
    )
  end
end
