defmodule ABSmartly.HTTP.Client do
  @moduledoc """
  HTTP client for ABSmartly API with retry logic.

  """

  require Logger

  @default_timeout 30_000

  @doc """
  Fetch context data from API endpoint.

  Implements retry logic:
  - Retry on network errors and 5xx status codes
  - Don't retry on 4xx status codes
  - Exponential backoff: 50ms × 2^attempt
  """
  def fetch_context(
        endpoint,
        api_key,
        application,
        environment,
        retries \\ 3,
        timeout \\ @default_timeout
      ) do
    url = "#{endpoint}/context"
    headers = build_headers(api_key, application, environment)

    query_params = %{
      "application" => application,
      "environment" => environment
    }

    request_fn = fn ->
      query_string = URI.encode_query(query_params)
      full_url = "#{url}?#{query_string}"
      HTTPoison.get(full_url, headers, request_options(timeout))
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
  """
  def publish_events(
        endpoint,
        api_key,
        application,
        environment,
        events,
        retries \\ 3,
        timeout \\ @default_timeout
      ) do
    url = "#{endpoint}/context"
    headers = build_headers(api_key, application, environment)

    case Jason.encode(events) do
      {:ok, body} ->
        request_fn = fn ->
          HTTPoison.put(url, body, headers, request_options(timeout))
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

  # Direct (unpooled) connections: the SDK makes few requests, and tasks that are
  # cancelled mid-request (shutdown, publish deadline) must not leak slots in
  # Hackney's shared pool / per-host load regulation, which surfaces as spurious
  # :checkout_timeout errors. Redirects are deliberately not followed (a
  # redirected event PUT must never be acknowledged).
  defp request_options(timeout) do
    [timeout: timeout, recv_timeout: timeout, hackney: [pool: false]]
  end

  defp build_headers(api_key, application, environment) do
    [
      {"X-API-Key", api_key},
      {"X-Application", application},
      {"X-Environment", environment},
      {"X-Application-Version", "0"},
      {"X-Agent", "absmartly-elixir-sdk"},
      {"Content-Type", "application/json"}
    ]
  end

  defp with_retry(request_fn, max_retries, attempt \\ 0)

  defp with_retry(request_fn, max_retries, attempt) when max_retries > 10 do
    with_retry(request_fn, 10, attempt)
  end

  defp with_retry(request_fn, max_retries, attempt) do
    case request_fn.() do
      {:ok, %HTTPoison.Response{status_code: status, body: body}}
      when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 300 and status < 400 ->
        Logger.warning("Redirect received: #{status}")
        {:error, "Redirect received: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 400 and status < 500 ->
        Logger.error("Client error: #{status}")
        {:error, "Client error: #{status}"}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        retry_or_fail(request_fn, max_retries, attempt, "Server error: #{status}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        sanitized_reason = sanitize_error(reason)

        retry_or_fail(
          request_fn,
          max_retries,
          attempt,
          "Network error: #{inspect(sanitized_reason)}"
        )
    end
  end

  @doc false
  def retry_backoff(attempt) do
    Application.get_env(:absmartly, :retry_backoff_base, 50) * Integer.pow(2, attempt)
  end

  @doc false
  def request_deadline(timeout, retries) do
    retries = min(retries, 10)

    backoff =
      if retries > 0,
        do: Enum.sum(for attempt <- 0..(retries - 1), do: round(retry_backoff(attempt))),
        else: 0

    (retries + 1) * 2 * timeout + backoff + 1_000
  end

  defp retry_or_fail(request_fn, max_retries, attempt, error_msg) do
    if attempt < max_retries do
      backoff = retry_backoff(attempt)

      Logger.info(
        "Retrying request after #{round(backoff)}ms (attempt #{attempt + 1}/#{max_retries})"
      )

      Process.sleep(round(backoff))
      with_retry(request_fn, max_retries, attempt + 1)
    else
      Logger.error(error_msg)
      {:error, error_msg}
    end
  end

  defp sanitize_error(%{headers: _headers} = map) do
    Map.drop(map, [:headers])
  end

  defp sanitize_error(other), do: other
end
