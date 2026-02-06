defmodule ABSmartly.HTTP.Client do
  @moduledoc """
  HTTP client for ABSmartly API with retry logic.
  """

  @doc """
  Fetch context data from API endpoint.

  Implements retry logic:
  - Retry on network errors and 5xx status codes
  - Don't retry on 4xx status codes
  - Exponential backoff: 50ms × 2^attempt
  """
  def fetch_context(endpoint, api_key, application, environment, retries \\ 3) do
    url = "#{endpoint}/context"

    headers = [
      {"X-API-Key", api_key},
      {"X-Application", application},
      {"X-Environment", environment},
      {"Content-Type", "application/json"}
    ]

    query_params = %{
      "application" => application,
      "environment" => environment
    }

    do_fetch_with_retry(url, headers, query_params, retries, 0)
  end

  defp do_fetch_with_retry(url, headers, params, max_retries, attempt) do
    query_string = URI.encode_query(params)
    full_url = "#{url}?#{query_string}"

    case HTTPoison.get(full_url, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status >= 200 and status < 300 ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 and status < 500 ->
        {:error, "Client error: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        if attempt < max_retries do
          backoff = 50 * :math.pow(2, attempt)
          Process.sleep(round(backoff))
          do_fetch_with_retry(url, headers, params, max_retries, attempt + 1)
        else
          {:error, "Server error: #{status}"}
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        if attempt < max_retries do
          backoff = 50 * :math.pow(2, attempt)
          Process.sleep(round(backoff))
          do_fetch_with_retry(url, headers, params, max_retries, attempt + 1)
        else
          {:error, "Network error: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Publish events to API endpoint.
  """
  def publish_events(endpoint, api_key, application, environment, events, retries \\ 3) do
    url = "#{endpoint}/events"

    headers = [
      {"X-API-Key", api_key},
      {"X-Application", application},
      {"X-Environment", environment},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        "application" => application,
        "environment" => environment,
        "events" => events
      })

    do_post_with_retry(url, headers, body, retries, 0)
  end

  defp do_post_with_retry(url, headers, body, max_retries, attempt) do
    case HTTPoison.post(url, body, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 and status < 500 ->
        {:error, "Client error: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        if attempt < max_retries do
          backoff = 50 * :math.pow(2, attempt)
          Process.sleep(round(backoff))
          do_post_with_retry(url, headers, body, max_retries, attempt + 1)
        else
          {:error, "Server error: #{status}"}
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        if attempt < max_retries do
          backoff = 50 * :math.pow(2, attempt)
          Process.sleep(round(backoff))
          do_post_with_retry(url, headers, body, max_retries, attempt + 1)
        else
          {:error, "Network error: #{inspect(reason)}"}
        end
    end
  end
end
