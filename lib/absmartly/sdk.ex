defmodule ABSmartly.SDK do
  @moduledoc """
  Main SDK class for ABSmartly.

  Provides two context creation methods:
  - create_context/3: Async - fetches data from API
  - create_context_with/3: Sync - uses pre-fetched data
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

  ## Examples

      # Basic usage with required parameters
      sdk = ABSmartly.SDK.new(
        endpoint: "https://your-company.absmartly.io/v1",
        api_key: "YOUR-API-KEY",
        application: "website",
        environment: "development"
      )

      # With optional parameters
      sdk = ABSmartly.SDK.new(
        endpoint: "https://your-company.absmartly.io/v1",
        api_key: "YOUR-API-KEY",
        application: "website",
        environment: "production",
        timeout: 5000,
        retries: 3
      )

  ## Returns
    * `{:ok, sdk}` - Successfully created SDK instance
    * `{:error, reason}` - Validation failed
  """
  def new(opts) when is_list(opts) do
    with :ok <- validate_required_params(opts),
         {:ok, config} <- build_config(opts) do
      {:ok, %__MODULE__{config: config}}
    end
  end

  @doc """
  Set custom timeout for the SDK instance (pipe-friendly).

  ## Examples

      sdk = ABSmartly.SDK.new(endpoint: "...", api_key: "...")
        |> ABSmartly.SDK.with_timeout(5000)
  """
  def with_timeout({:ok, %__MODULE__{config: config} = sdk}, timeout) when is_integer(timeout) do
    {:ok, %{sdk | config: %{config | timeout: timeout}}}
  end

  def with_timeout({:error, _} = error, _timeout), do: error

  @doc """
  Set custom retry count for the SDK instance (pipe-friendly).

  ## Examples

      sdk = ABSmartly.SDK.new(endpoint: "...", api_key: "...")
        |> ABSmartly.SDK.with_retries(3)
  """
  def with_retries({:ok, %__MODULE__{config: config} = sdk}, retries) when is_integer(retries) do
    {:ok, %{sdk | config: %{config | retries: retries}}}
  end

  def with_retries({:error, _} = error, _retries), do: error

  defp validate_required_params(opts) do
    required = [:endpoint, :api_key, :application, :environment]
    # Fixes LOW-01: Use Enum.reject instead of negated filter
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

  # Fixes MEDIUM-20, LOW-02: Narrower rescue scope
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
  Create context with async data fetching (calls API endpoint).

  ## Parameters

    * `sdk` - SDK instance (unwrapped if coming from new/1)
    * `units` - Map of unit types to UIDs (e.g., %{"session_id" => "abc123"})
    * `options` - Optional configuration map

  ## Returns

    * `{:ok, context}` - Context successfully created
    * `{:error, reason}` - Failed to fetch data or create context
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
  Create context with pre-fetched data (synchronous).

  ## Parameters

    * `sdk` - SDK instance (unwrapped if coming from new/1)
    * `units` - Map of unit types to UIDs
    * `data` - ContextData struct with experiments
    * `options` - Optional configuration map

  ## Returns

    * `{:ok, context}` - Context successfully created
  """
  def create_context_with(sdk_or_result, units, data, options \\ %{})

  def create_context_with({:ok, sdk}, units, data, options),
    do: create_context_with(sdk, units, data, options)

  def create_context_with(%__MODULE__{} = sdk, units, %Types.ContextData{} = data, options) do
    context_config =
      options
      |> Map.put(:units, units)
      |> Types.ContextConfig.from_options()

    Context.start_link(sdk.config, data, context_config)
  end
end
