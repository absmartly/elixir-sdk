# ABsmartly Elixir SDK

The official Elixir SDK for [ABsmartly](https://www.absmartly.com) - A/B testing and feature flagging platform.

## Compatibility

The ABsmartly Elixir SDK is compatible with Elixir 1.14+ and Erlang/OTP 24+. It provides both synchronous and asynchronous context creation for variant assignment and goal tracking. The Context is implemented as a GenServer process.

## Installation

Add `absmartly` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:absmartly, "~> 1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Getting Started

Please follow the [installation](#installation) instructions before trying the following code.

### Initialization

This example assumes an API Key, an Application, and an Environment have been created in the ABsmartly web console.

```elixir
alias ABSmartly.SDK

{:ok, sdk} = SDK.new(
  endpoint: "https://your-company.absmartly.io/v1",
  api_key: System.get_env("ABSMARTLY_API_KEY"),
  application: "website",
  environment: "production"
)
```

#### With Optional Parameters

```elixir
{:ok, sdk} = SDK.new(
  endpoint: "https://your-company.absmartly.io/v1",
  api_key: System.get_env("ABSMARTLY_API_KEY"),
  application: "website",
  environment: "production",
  timeout: 5000,
  retries: 3
)
```

**SDK Options**

| Config       | Type      | Required? | Default | Description                                                                                                                                                                   |
| :----------- | :-------- | :-------: | :-----: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| endpoint     | `String`  |  &#9989;  |  `nil`  | The URL to your API endpoint. Most commonly `"https://your-company.absmartly.io/v1"`                                                                                         |
| api_key      | `String`  |  &#9989;  |  `nil`  | Your API key which can be found on the Web Console.                                                                                                                           |
| environment  | `String`  |  &#9989;  |  `nil`  | The environment of the platform where the SDK is installed. Environments are created on the Web Console and should match the available environments in your infrastructure.   |
| application  | `String`  |  &#9989;  |  `nil`  | The name of the application where the SDK is installed. Applications are created on the Web Console and should match the applications where your experiments will be running. |
| retries      | `Integer` | &#10060;  |   `5`   | Number of retry attempts for failed HTTP requests                                                                                                                             |
| timeout      | `Integer` | &#10060;  | `3000`  | Connection timeout in milliseconds                                                                                                                                            |

## Creating a New Context

### Synchronously

```elixir
alias ABSmartly.{SDK, Context}

units = %{"session_id" => "5ebf06d8cb5d8137290c4abb64155584fbdb64d8"}

{:ok, context} = SDK.create_context(sdk, units)

true = Context.is_ready?(context)
```

### Asynchronously

```elixir
alias ABSmartly.{SDK, Context}

units = %{"session_id" => "5ebf06d8cb5d8137290c4abb64155584fbdb64d8"}

{:ok, context} = SDK.create_context_async(sdk, units)

Context.wait_until_ready(context)
```

### With Pre-fetched Data

When doing full-stack experimentation with ABsmartly, we recommend creating a context only once on the server-side. Creating a context involves a round-trip to the ABsmartly event collector. We can avoid repeating the round-trip on the client-side by sending the server-side data embedded in the first document.

```elixir
alias ABSmartly.{SDK, Context, Types}

units = %{"session_id" => "5ebf06d8cb5d8137290c4abb64155584fbdb64d8"}

context_data = %Types.ContextData{
  experiments: [...]
}

{:ok, context} = SDK.create_context_with(sdk, units, context_data)

true = Context.is_ready?(context)
```

### Refreshing the Context with Fresh Experiment Data

For long-running contexts, the context can be refreshed manually to pull updated experiment data.

```elixir
new_data = %{"experiments" => [...]}

:ok = Context.refresh(context, new_data)
```

### Setting Extra Units

You can add additional units to a context by calling the `set_unit/3` function. This may be used, for example, when a user logs in to your application, and you want to use the new unit type in the context.

**Note:** You cannot override an already set unit type as that would be a change of identity. In this case, you must create a new context instead. The `set_unit/3` and `set_units/2` functions can be called before the context is ready.

```elixir
Context.set_unit(context, "db_user_id", "1000013")

Context.set_units(context, %{
  "db_user_id" => "1000013",
  "user_type" => "premium"
})
```

## Basic Usage

### Selecting a Treatment

```elixir
variant = Context.treatment(context, "exp_test_experiment")

case variant do
  0 ->
    # User is in control group (variant 0)
    render_control_experience()
  _ ->
    # User is in treatment group
    render_treatment_experience()
end
```

### Treatment Variables

Variables allow you to change experiment parameters without code deployment.

```elixir
button_color = Context.variable_value(context, "button_color", "blue")

timeout = Context.variable_value(context, "api_timeout", 5000)
```

### Peek at Treatment Variants

Although generally not recommended, it is sometimes necessary to peek at a treatment without triggering an exposure. The ABsmartly SDK provides a `peek/2` function for that.

```elixir
variant = Context.peek(context, "exp_test_experiment")

if variant == 0 do
  # User is in control group
else
  # User is in treatment group
end
```

#### Peeking at Variables

```elixir
color = Context.peek_variable_value(context, "button_color", "blue")
```

### Overriding Treatment Variants

During development or testing, you may want to force a specific variant. The `set_override/3` function allows you to override the variant assignment.
The `set_override/3` and `set_overrides/2` functions can be called before the context is ready.

```elixir
Context.set_override(context, "exp_test_experiment", 1)

Context.set_overrides(context, %{
  "exp_test_experiment" => 1,
  "exp_another_test" => 0
})
```

## Advanced

### Context Attributes

Attributes are used for audience targeting. The `set_attribute/3` function can be called before the context is ready. It accepts native Elixir types directly.

```elixir
Context.set_attribute(context, "user_agent", "Mozilla/5.0")
Context.set_attribute(context, "customer_age", "new_customer")
Context.set_attribute(context, "age", 25)

Context.set_attributes(context, %{
  "user_agent" => "Mozilla/5.0",
  "customer_age" => "new_customer",
  "age" => 25
})
```

### Custom Assignments

Custom assignments allow you to implement your own assignment logic while still benefiting from ABsmartly's analytics.

```elixir
Context.set_custom_assignment(context, "exp_test_experiment", 1)

Context.set_custom_assignments(context, %{
  "exp_test_experiment" => 1,
  "exp_another_experiment" => 0
})
```

### Tracking Goals

Goals are created in the ABsmartly web console.

```elixir
Context.track(context, "signup")

Context.track(context, "purchase", %{
  "amount" => 99.99,
  "items" => 3
})
```

### Publishing Pending Data

Sometimes it is necessary to ensure all events have been published to the ABsmartly collector before proceeding. You can explicitly call the `publish/1` function.

```elixir
Context.publish(context)
```

### Finalizing

The `finalize/1` function will ensure all events have been published to the ABsmartly collector, like `publish/1`, and will also "seal" the context, preventing any further events from being tracked.

```elixir
Context.finalize(context)

true = Context.is_finalized?(context)
```

### Custom Event Logger

The ABsmartly SDK supports custom event logging for debugging, analytics, or integrating with other systems. Event loggers can be set at the SDK level or per-context.

**Event Types**

| Event      | When                                         | Data                                 |
|------------|----------------------------------------------|--------------------------------------|
| `error`    | Context receives an error                    | Error details                        |
| `ready`    | Context turns ready                          | ContextData used to initialize       |
| `refresh`  | `refresh/2` succeeds                         | ContextData used to refresh          |
| `publish`  | `publish/1` succeeds                         | Published events data                |
| `exposure` | `treatment/2` succeeds on first exposure     | Exposure enqueued for publishing     |
| `goal`     | `track/2` or `track/3` succeeds              | Goal enqueued for publishing         |
| `close`    | `finalize/1` succeeds the first time         | `nil`                                |

## Platform-Specific Examples

### Using with Phoenix Framework

Integrate ABsmartly with Phoenix by creating a singleton GenServer and using it in your controllers.

```elixir
# lib/my_app/absmartly_service.ex
defmodule MyApp.ABSmartlyService do
  use GenServer

  alias ABSmartly.SDK

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_sdk do
    GenServer.call(__MODULE__, :get_sdk)
  end

  @impl true
  def init(:ok) do
    {:ok, sdk} = SDK.new(
      endpoint: Application.get_env(:my_app, :absmartly_endpoint),
      api_key: Application.get_env(:my_app, :absmartly_api_key),
      environment: Application.get_env(:my_app, :absmartly_environment),
      application: "my_app"
    )

    {:ok, %{sdk: sdk}}
  end

  @impl true
  def handle_call(:get_sdk, _from, state) do
    {:reply, {:ok, state.sdk}, state}
  end
end

# Add to application.ex supervision tree
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyAppWeb.Endpoint,
      MyApp.ABSmartlyService
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# lib/my_app_web/controllers/product_controller.ex
defmodule MyAppWeb.ProductController do
  use MyAppWeb, :controller

  alias ABSmartly.{SDK, Context}

  def show(conn, _params) do
    session_id = get_session(conn, :session_id) || generate_session_id()
    conn = put_session(conn, :session_id, session_id)

    {:ok, sdk} = MyApp.ABSmartlyService.get_sdk()

    units = %{"session_id" => session_id}

    case SDK.create_context(sdk, units) do
      {:ok, context} ->
        Context.set_attribute(context, "user_agent", get_req_header(conn, "user-agent"))

        treatment = Context.treatment(context, "exp_product_layout")

        Context.publish(context)
        Context.finalize(context)

        case treatment do
          0 -> render(conn, "show_control.html")
          _ -> render(conn, "show_treatment.html")
        end

      {:error, _reason} ->
        render(conn, "show_control.html")
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

### Using with Phoenix LiveView

Handle experiments in LiveView with proper lifecycle management.

```elixir
# lib/my_app_web/live/product_live.ex
defmodule MyAppWeb.ProductLive do
  use MyAppWeb, :live_view

  alias ABSmartly.{SDK, Context}

  def mount(_params, session, socket) do
    session_id = session["session_id"] || generate_session_id()

    {:ok, sdk} = MyApp.ABSmartlyService.get_sdk()
    units = %{"session_id" => session_id}

    case SDK.create_context(sdk, units) do
      {:ok, context} ->
        treatment = Context.treatment(context, "exp_product_layout")

        {:ok,
         socket
         |> assign(:context, context)
         |> assign(:treatment, treatment)}

      {:error, _reason} ->
        {:ok,
         socket
         |> assign(:context, nil)
         |> assign(:treatment, 0)}
    end
  end

  def handle_event("purchase", %{"amount" => amount}, socket) do
    if context = socket.assigns.context do
      Context.track(context, "purchase", %{"amount" => String.to_float(amount)})
      Context.publish(context)
    end

    {:noreply, socket}
  end

  def terminate(_reason, socket) do
    if context = socket.assigns.context do
      Context.finalize(context)
    end

    :ok
  end

  def render(assigns) do
    ~H"""
    <%= if @treatment == 0 do %>
      <div class="control-group">Control Layout</div>
    <% else %>
      <div class="treatment-group">Treatment Layout</div>
    <% end %>
    """
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

### Using with Plug

Create a Plug to automatically manage ABsmartly contexts for requests.

```elixir
# lib/my_app_web/plugs/absmartly_context.ex
defmodule MyAppWeb.Plugs.ABSmartlyContext do
  import Plug.Conn

  alias ABSmartly.{SDK, Context}

  def init(opts), do: opts

  def call(conn, _opts) do
    session_id = get_session(conn, :session_id) || generate_session_id()
    conn = put_session(conn, :session_id, session_id)

    {:ok, sdk} = MyApp.ABSmartlyService.get_sdk()
    units = %{"session_id" => session_id}

    case SDK.create_context(sdk, units) do
      {:ok, context} ->
        user_agent =
          case get_req_header(conn, "user-agent") do
            [ua | _] -> ua
            [] -> "unknown"
          end

        Context.set_attribute(context, "user_agent", user_agent)

        conn
        |> assign(:absmartly_context, context)
        |> register_before_send(&finalize_context/1)

      {:error, _reason} ->
        conn
    end
  end

  defp finalize_context(conn) do
    if context = conn.assigns[:absmartly_context] do
      Context.publish(context)
      Context.finalize(context)
    end

    conn
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

# Use in router
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MyAppWeb.Plugs.ABSmartlyContext
  end

  scope "/", MyAppWeb do
    pipe_through :browser

    get "/", PageController, :index
  end
end
```

## About A/B Smartly

**A/B Smartly** is the leading provider of state-of-the-art, on-premises, full-stack experimentation platforms for engineering and product teams that want to confidently deploy features as fast as they can develop them.

A/B Smartly's real-time analytics helps engineering and product teams ensure that new features will improve the customer experience without breaking or degrading performance and/or business metrics.

### Have a look at our growing list of clients and SDKs:

- [JavaScript SDK](https://www.github.com/absmartly/javascript-sdk)
- [Java SDK](https://www.github.com/absmartly/java-sdk)
- [PHP SDK](https://www.github.com/absmartly/php-sdk)
- [Swift SDK](https://www.github.com/absmartly/swift-sdk)
- [Vue2 SDK](https://www.github.com/absmartly/vue2-sdk)
- [Vue3 SDK](https://www.github.com/absmartly/vue3-sdk)
- [React SDK](https://www.github.com/absmartly/react-sdk)
- [Python3 SDK](https://www.github.com/absmartly/python3-sdk)
- [Go SDK](https://www.github.com/absmartly/go-sdk)
- [Ruby SDK](https://www.github.com/absmartly/ruby-sdk)
- [.NET SDK](https://www.github.com/absmartly/dotnet-sdk)
- [Dart SDK](https://www.github.com/absmartly/dart-sdk)
- [Flutter SDK](https://www.github.com/absmartly/flutter-sdk)
- [Elixir SDK](https://www.github.com/absmartly/elixir-sdk) (this package)
