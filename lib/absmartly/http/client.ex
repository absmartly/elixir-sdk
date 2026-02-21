defmodule ABSmartly.HTTP.Client do
  @moduledoc """
  HTTP client for ABSmartly API with retry logic.

  Fixes:
  - CRITICAL-07: Rescue Jason.encode! errors
  - CRITICAL-08: Handle 3xx redirects
  - CRITICAL-16: Deduplicate HTTP retry logic
  - HIGH-25: Deduplicate header construction
  """

  require Logger

  @doc """
  Fetch context data from API endpoint.

  Implements retry logic:
  - Retry on network errors and 5xx status codes
  - Don't retry on 4xx status codes
  - Exponential backoff: 50ms × 2^attempt
  """
  def fetch_context(endpoint, api_key, application, environment, retries \\ 3) do
    url = "#{endpoint}/context"
    headers = build_headers(api_key, application, environment)

    query_params = %{
      "application" => application,
      "environment" => environment
    }

    request_fn = fn ->
      query_string = URI.encode_query(query_params)
      full_url = "#{url}?#{query_string}"
      HTTPoison.get(full_url, headers, timeout: 30_000, recv_timeout: 30_000, follow_redirect: true)
    end

    case with_retry(request_fn, retries) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      error ->
        error
    end
  end

  @doc """
  Publish events to API endpoint.
  Fixes CRITICAL-07: Rescue Jason.encode! errors.
  """
  def publish_events(endpoint, api_key, application, environment, events, retries \\ 3) do
    url = "#{endpoint}/events"
    headers = build_headers(api_key, application, environment)

    # Fixes CRITICAL-07: Use safe Jason.encode instead of encode!
    body_data = %{
      "application" => application,
      "environment" => environment,
      "events" => events
    }

    case Jason.encode(body_data) do
      {:ok, body} ->
        request_fn = fn ->
          HTTPoison.post(url, body, headers, timeout: 30_000, recv_timeout: 30_000, follow_redirect: true)
        end

        case with_retry(request_fn, retries) do
          {:ok, _body} -> :ok
          error -> error
        end

      {:error, %Jason.EncodeError{} = error} ->
        Logger.error("Failed to encode events: #{Exception.message(error)}")
        {:error, "Failed to encode events: #{Exception.message(error)}"}
    end
  end

  # Fixes HIGH-25: Extract common header construction
  defp build_headers(api_key, application, environment) do
    [
      {"X-API-Key", api_key},
      {"X-Application", application},
      {"X-Environment", environment},
      {"Content-Type", "application/json"}
    ]
  end

  # Fixes CRITICAL-16: Unified retry logic for GET and POST
  # Fixes CRITICAL-08: Handle 3xx redirects
  # Fixes CRITICAL-05: Sanitize HTTPoison errors to prevent API key exposure
  defp with_retry(request_fn, max_retries, attempt \\ 0) do
    case request_fn.() do
      {:ok, %HTTPoison.Response{status_code: status, body: body}}
      when status >= 200 and status < 300 ->
        {:ok, body}

      # Fixes CRITICAL-08: Handle 3xx redirects
      {:ok, %HTTPoison.Response{status_code: status}} when status >= 300 and status < 400 ->
        Logger.warning("Redirect received: #{status}")
        {:error, "Redirect received: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 and status < 500 ->
        Logger.error("Client error: #{status}")
        {:error, "Client error: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        retry_or_fail(request_fn, max_retries, attempt, "Server error: #{status}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        # Fixes CRITICAL-05: Sanitize error to prevent API key exposure
        sanitized_reason = sanitize_error(reason)
        retry_or_fail(request_fn, max_retries, attempt, "Network error: #{inspect(sanitized_reason)}")
    end
  end

  defp retry_or_fail(request_fn, max_retries, attempt, error_msg) do
    if attempt < max_retries do
      backoff = 50 * :math.pow(2, attempt)
      Logger.info("Retrying request after #{round(backoff)}ms (attempt #{attempt + 1}/#{max_retries})")
      Process.sleep(round(backoff))
      with_retry(request_fn, max_retries, attempt + 1)
    else
      Logger.error(error_msg)
      {:error, error_msg}
    end
  end

  # Fixes CRITICAL-05: Sanitize HTTPoison errors to remove headers with API keys
  defp sanitize_error(%{headers: _headers} = map) do
    Map.drop(map, [:headers])
  end

  defp sanitize_error(other), do: other
end
