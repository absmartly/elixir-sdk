defmodule ABSmartly.HTTPIntegrationTest do
  @moduledoc """
  Hermetic local-HTTP-server integration test.

  Drives the PUBLIC SDK surface (`ABSmartly.SDK.create_context/3` ->
  `Context.treatment/2` -> `Context.track/3` -> `Context.publish/1`) so that the
  REAL HTTPoison-backed `ABSmartly.HTTP.Client` performs an actual
  `GET /context` and `PUT /context` against a local loopback server, and asserts
  the documented ABsmartly collector wire contract:

    GET  <endpoint>/context  with ?application=&environment=  (drives ready)
    PUT  <endpoint>/context  with X-API-Key / X-Application / X-Environment /
                             X-Application-Version / X-Agent / Content-Type and a
                             body containing hashed / units / publishedAt.

  The server is a tiny `:gen_tcp` HTTP/1.1 implementation bound to an ephemeral
  loopback port, so the test stays hermetic with no extra dependency and no live
  backend.
  """
  use ExUnit.Case, async: false

  alias ABSmartly.{Context, SDK}

  # A single valid experiment so `treatment/2` yields an exposure to publish.
  @get_body Jason.encode!(%{
              "experiments" => [
                %{
                  "id" => 1,
                  "name" => "exp_test_ab",
                  "iteration" => 1,
                  "unitType" => "session_id",
                  "seedHi" => 3_603_515,
                  "seedLo" => 233_373_850,
                  "split" => [0.5, 0.5],
                  "trafficSeedHi" => 449_867_249,
                  "trafficSeedLo" => 455_443_629,
                  "trafficSplit" => [0.0, 1.0],
                  "fullOnVariant" => 0,
                  "applications" => [%{"name" => "website"}],
                  "variants" => [
                    %{"name" => "A", "config" => nil},
                    %{"name" => "B", "config" => "{\"banner.border\":1}"}
                  ],
                  "audience" => nil,
                  "customFieldValues" => nil
                }
              ]
            })

  setup do
    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)
    {:ok, server: server}
  end

  test "real HTTP client hits local server with the wire contract", %{server: server} do
    endpoint = "http://127.0.0.1:#{server.port}"

    {:ok, sdk} =
      SDK.new(
        endpoint: endpoint,
        api_key: "test-api-key",
        application: "website",
        environment: "test",
        retries: 0
      )

    # createContext -> blocks on the real GET /context.
    {:ok, ctx} =
      SDK.create_context(sdk, %{
        "session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
      })

    # Queue an exposure + a goal so publish() has something to send.
    assert Context.treatment(ctx, "exp_test_ab") in 0..1
    Context.track(ctx, "payment", %{"amount" => 1000})

    # publish() -> real PUT /context.
    Context.publish(ctx)

    requests = collect_requests(2, [])
    assert length(requests) == 2

    get = Enum.find(requests, &(&1.method == "GET"))
    put = Enum.find(requests, &(&1.method == "PUT"))

    # ---- GET /context (fetch -> ready) ----
    assert get
    assert String.starts_with?(get.path, "/context")
    assert get.query =~ "application=website"
    assert get.query =~ "environment=test"

    # ---- PUT /context (publish) ----
    assert put
    assert String.starts_with?(put.path, "/context")
    refute put.path =~ "?"

    # Required auth / identity headers (exact names per the wire contract).
    assert header(put, "x-api-key") == "test-api-key"
    assert header(put, "x-application") == "website"
    assert header(put, "x-environment") == "test"
    assert header(put, "x-application-version") == "0"
    assert header(put, "x-agent") not in [nil, ""]
    assert header(put, "content-type") =~ "application/json"

    # Body must carry the required publish fields.
    body = Jason.decode!(put.body)
    assert is_boolean(body["hashed"])
    assert is_list(body["units"])
    assert is_integer(body["publishedAt"]) and body["publishedAt"] > 0
    # We tracked a goal, so goals must be present and non-empty.
    assert is_list(body["goals"])
    assert length(body["goals"]) >= 1
    assert hd(body["goals"])["name"] == "payment"
  end

  # ---------------------------------------------------------------------------
  # Tiny hermetic HTTP/1.1 server over :gen_tcp.
  # ---------------------------------------------------------------------------

  defp start_server do
    test_pid = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    acceptor =
      spawn_link(fn -> accept_loop(listen, test_pid) end)

    {:ok, %{listen: listen, port: port, acceptor: acceptor}}
  end

  defp stop_server(%{listen: listen}) do
    :gen_tcp.close(listen)
  end

  defp accept_loop(listen, test_pid) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handle_connection(socket, test_pid)
        accept_loop(listen, test_pid)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        :ok
    end
  end

  defp handle_connection(socket, test_pid) do
    request = read_request(socket, "")
    send(test_pid, {:request, request})

    body =
      case request.method do
        "GET" -> @get_body
        _ -> "{}"
      end

    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  # Read until full headers are present, then read Content-Length bytes of body.
  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {method, path, query, headers} = parse_head(head)
        content_length = header_value(headers, "content-length")
        body = read_body(socket, rest, content_length)
        %{method: method, path: path, query: query, headers: headers, body: body}

      [_partial] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
        read_request(socket, acc <> chunk)
    end
  end

  defp read_body(_socket, rest, 0), do: rest

  defp read_body(socket, rest, content_length) do
    if byte_size(rest) >= content_length do
      rest
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
      read_body(socket, rest <> chunk, content_length)
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, target | _] = String.split(request_line, " ")

    {path, query} =
      case String.split(target, "?", parts: 2) do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    headers =
      header_lines
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> {String.downcase(String.trim(name)), String.trim(value)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {method, path, query, headers}
  end

  defp header_value(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> String.to_integer(value)
      nil -> 0
    end
  end

  defp header(request, name) do
    case List.keyfind(request.headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # Collect up to `n` recorded requests (with a generous timeout).
  defp collect_requests(0, acc), do: Enum.reverse(acc)

  defp collect_requests(n, acc) do
    receive do
      {:request, request} -> collect_requests(n - 1, [request | acc])
    after
      5000 -> Enum.reverse(acc)
    end
  end
end
