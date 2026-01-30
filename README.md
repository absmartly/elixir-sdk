# ABsmartly Elixir SDK

[![Hex.pm](https://img.shields.io/hexpm/v/absmartly.svg)](https://hex.pm/packages/absmartly)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/absmartly)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

The official Elixir SDK for [ABsmartly](https://www.absmartly.com) - A/B testing and feature flagging platform.

## Compatibility

The ABsmartly Elixir SDK is compatible with Elixir 1.14+ and Erlang/OTP 24+. It provides both synchronous and asynchronous context creation for variant assignment and goal tracking.

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

**With optional parameters:**

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

**Using the pipe operator for configuration:**

```elixir
{:ok, sdk} = SDK.new(
  endpoint: "https://your-company.absmartly.io/v1",
  api_key: System.get_env("ABSMARTLY_API_KEY"),
  application: "website",
  environment: "production"
)
|> SDK.with_timeout(5000)
|> SDK.with_retries(3)
```

**SDK Options**

| Config       | Type     | Required? | Default | Description                                                                                                                                                                   |
| :----------- | :------- | :-------: | :-----: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| endpoint     | `String` |  &#9989;  |  `nil`  | The URL to your API endpoint. Most commonly `"your-company.absmartly.io"`                                                                                                    |
| api_key      | `String` |  &#9989;  |  `nil`  | Your API key which can be found on the Web Console.                                                                                                                          |
| environment  | `String` |  &#9989;  |  `nil`  | The environment of the platform where the SDK is installed. Environments are created on the Web Console and should match the available environments in your infrastructure.  |
| application  | `String` |  &#9989;  |  `nil`  | The name of the application where the SDK is installed. Applications are created on the Web Console and should match the applications where your experiments will be running.|
| retries      | Integer  |  &#10060; |   `5`   | Number of retry attempts for failed HTTP requests                                                                                                                            |
| timeout      | Integer  |  &#10060; | `3000` | Connection timeout in milliseconds                                                                                                                                           |

## Basic Usage

### Creating a New Context

```elixir
alias ABSmartly.{SDK, Context}

# Initialize SDK
{:ok, sdk} = SDK.new(
  endpoint: "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "production"
)

# Define units for the context
units = %{"session_id" => "5ebf06d8cb5d8137290c4abb64155584fbdb64d8"}

# Create context (async - fetches data from API)
{:ok, context} = SDK.create_context(sdk, units)

# Context is now ready to use
variant = Context.treatment(context, "exp_test_experiment")
```

### Creating a New Context with Pre-fetched Data

When doing full-stack experimentation with ABsmartly, we recommend creating a context only once on the server-side. Creating a context involves a round-trip to the ABsmartly event collector. We can avoid repeating the round-trip on the client-side by sending the server-side data embedded in the first document.

```elixir
alias ABSmartly.{SDK, Context, Types}

# Define units for the context
units = %{"session_id" => "5ebf06d8cb5d8137290c4abb64155584fbdb64d8"}

# Load context data from your backend API
context_data = %Types.ContextData{
  experiments: [...]  # Pre-fetched experiment data
}

# Create context with pre-fetched data - no network round-trip needed
{:ok, context} = SDK.create_context_with(sdk, units, context_data)

# Context is immediately ready
true = Context.is_ready?(context)
```

### Refreshing the Context with Fresh Experiment Data

For long-running contexts, the context can be refreshed manually to pull updated experiment data:

```elixir
# Fetch fresh data from your API
new_data = %{"experiments" => [...]}

# Refresh the context
:ok = Context.refresh(context, new_data)
```

### Setting Extra Units for a Context

You can add additional units to a context by calling the `set_unit/3` function. This may be used, for example, when a user logs in to your application, and you want to use the new unit type in the context.

**Note:** You cannot override an already set unit type as that would be a change of identity. In this case, you must create a new context instead.

```elixir
# Set a single unit
Context.set_unit(context, "db_user_id", "1000013")

# Or set multiple units at once
Context.set_units(context, %{
  "db_user_id" => "1000013",
  "user_type" => "premium"
})

# Also accepts keyword lists (Elixir-idiomatic)
Context.set_units(context, [
  db_user_id: "1000013",
  user_type: "premium"
])
```

### Setting Context Attributes

Attributes are used for audience targeting. The `set_attribute/3` method can be called before the context is ready. It accepts native Elixir types directly:

```elixir
# Accepts native Elixir types
Context.set_attribute(context, "user_agent", "Mozilla/5.0")
Context.set_attribute(context, "customer_age", "new_customer")
Context.set_attribute(context, "age", 25)
Context.set_attribute(context, "premium", true)

# Or set multiple attributes at once (map or keyword list)
Context.set_attributes(context, %{
  "user_agent" => "Mozilla/5.0",
  "customer_age" => "new_customer",
  "age" => 25
})

# Pipe-friendly API
context
|> Context.set_attribute("country", "US")
|> Context.set_attribute("plan", "premium")
```

### Selecting a Treatment

```elixir
variant = Context.treatment(context, "exp_test_experiment")

case variant do
  0 ->
    # User is in control group (variant 0)
    render_control_experience()
  1 ->
    # User is in treatment variant 1
    render_variant_1_experience()
  2 ->
    # User is in treatment variant 2
    render_variant_2_experience()
end
```

The `treatment/2` function:
- Returns the assigned variant (0 for control, 1+ for treatments)
- **Queues an exposure event** for analytics
- Returns `0` for unknown experiments

### Peeking a Treatment

The `peek/2` function works exactly like `treatment/2` but **does not queue an exposure event**. This is useful when you need to check the variant assignment without recording it as an exposure.

```elixir
# Peek without recording exposure
variant = Context.peek(context, "exp_test_experiment")

# Later, when you actually show the experience, call treatment to record exposure
variant = Context.treatment(context, "exp_test_experiment")
```

### Overriding a Treatment

During development or testing, you may want to force a specific variant. The `set_override/3` function allows you to override the variant assignment:

```elixir
# Force user into variant 1 for testing
Context.set_override(context, "exp_test_experiment", 1)

# Now treatment will always return 1 for this experiment
variant = Context.treatment(context, "exp_test_experiment")
# => 1

# Set multiple overrides at once
Context.set_overrides(context, %{
  "exp_test_experiment" => 1,
  "exp_another_test" => 2
})
```

**Note:** Overrides are cleared when the context is refreshed.

### Custom Assignments

Custom assignments allow you to implement your own assignment logic while still benefiting from ABsmartly's analytics:

```elixir
# Assign based on your custom logic
custom_variant = calculate_custom_variant(user)
Context.set_custom_assignment(context, "exp_test_experiment", custom_variant)

# The assignment will be used but marked as custom in analytics
variant = Context.treatment(context, "exp_test_experiment")
```

## Advanced Usage

### Using Variables

Variables allow you to change experiment parameters without code deployment:

```elixir
# Get a variable value (queues exposure)
button_color = Context.variable_value(context, "button_color", "blue")

# Use default if variable not found
timeout = Context.variable_value(context, "api_timeout", 5000)

# Peek variable without queuing exposure
color = Context.peek_variable_value(context, "button_color", "blue")

# Get all variable keys
keys = Context.variable_keys(context)
# => ["button_color", "api_timeout", ...]
```

**How Variables Work:**
- Variables are defined per-variant in your experiments
- When a user is assigned to a variant, they see that variant's variable values
- Multiple experiments can define the same variable (latest non-control wins)

### Custom Fields

Custom fields allow you to store extra metadata with experiments:

```elixir
# Get a custom field value
countries = Context.custom_field_value(context, "exp_test", "target_countries")
# => "US,CA,UK"

# Get all custom field keys for an experiment
keys = Context.custom_field_keys(context, "exp_test")
# => ["target_countries", "rollout_percentage", ...]
```

Custom fields support multiple types:
- `"string"` - Plain text
- `"number"` - Numeric values
- `"boolean"` - true/false
- `"json"` - Complex objects/arrays

### Tracking Goals and Conversions

Goals are used to measure experiment success. Call `track/3` when a conversion event occurs:

```elixir
# Track a simple goal
Context.track(context, "signup")

# Track with properties (ONLY numeric properties are recorded)
Context.track(context, "purchase", %{
  "amount" => 99.99,
  "items" => 3,
  "currency" => "USD"  # This will be filtered out (not numeric)
})
```

**Important:** Only numeric properties are tracked. String properties are automatically filtered out.

### Publishing Pending Events

The SDK automatically queues exposure and goal events. Call `publish/1` to send them to ABsmartly:

```elixir
# Publish all pending events
Context.publish(context)
```

Pending events are:
- Exposure events (from `treatment/2` and `variable_value/3`)
- Goal events (from `track/2` and `track/3`)

### Finalizing the Context

When you're done with a context, call `finalize/1` to publish remaining events and seal the context:

```elixir
# Finalize publishes remaining events and prevents further operations
Context.finalize(context)

# After finalization, context state checks return:
true = Context.is_finalized?(context)
```

### Checking Context State

```elixir
# Is context ready to use?
Context.is_ready?(context)

# Did context fail to initialize?
Context.is_failed?(context)

# Is context finalized?
Context.is_finalized?(context)

# Is context currently finalizing?
Context.is_finalizing?(context)

# How many events are pending?
count = Context.pending(context)

# Get experiment names
names = Context.experiments(context)
# => ["exp_test_experiment", "exp_another_test", ...]

# Get raw context data
data = Context.data(context)
```

## Patterns & Best Practices

### Phoenix Controller Example

```elixir
defmodule MyAppWeb.PageController do
  use MyAppWeb, :controller

  alias ABSmartly.{SDK, Context}

  def index(conn, _params) do
    # Get SDK from application supervisor
    {:ok, sdk} = MyApp.ABSmartly.get_sdk()

    # Create context with user session
    {:ok, context} = SDK.create_context(sdk, %{
      "session_id" => get_session(conn, :session_id),
      "user_id" => conn.assigns.current_user.id
    })

    # Set targeting attributes
    context
    |> Context.set_attribute("user_agent", get_req_header(conn, "user-agent"))
    |> Context.set_attribute("country", conn.assigns.current_user.country)
    |> Context.set_attribute("plan", conn.assigns.current_user.plan)

    # Get treatment
    variant = Context.treatment(context, "homepage_redesign")

    # Render based on variant
    case variant do
      1 -> render(conn, "index_new.html", context: context)
      _ -> render(conn, "index.html", context: context)
    end
  end

  def purchase(conn, %{"amount" => amount}) do
    context = conn.assigns.absmartly_context

    # Track conversion
    Context.track(context, "purchase", %{"amount" => amount})
    Context.publish(context)

    redirect(conn, to: "/thank-you")
  end
end
```

### Plug for Context Management

```elixir
defmodule MyAppWeb.ABSmartlyPlug do
  import Plug.Conn

  alias ABSmartly.{SDK, Context}

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, sdk} = MyApp.ABSmartly.get_sdk()

    units = %{
      "session_id" => get_session(conn, :session_id)
    }

    case SDK.create_context(sdk, units) do
      {:ok, context} ->
        # Set attributes from conn
        context
        |> Context.set_attribute("user_agent", get_user_agent(conn))
        |> Context.set_attribute("referrer", get_referrer(conn))

        # Store in conn.assigns for controllers
        assign(conn, :absmartly_context, context)

      {:error, _reason} ->
        # Handle error - maybe use cached data or default behavior
        conn
    end
  end

  defp get_user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> "unknown"
    end
  end

  defp get_referrer(conn) do
    case get_req_header(conn, "referer") do
      [ref | _] -> ref
      [] -> nil
    end
  end
end
```

### GenServer for SDK Singleton

```elixir
defmodule MyApp.ABSmartly do
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
```

Add to your application supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.ABSmartly,
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Platform-Specific Examples

### Using with Phoenix Framework

Integrate ABsmartly with Phoenix by creating a singleton GenServer and using it in your controllers.

```elixir
# lib/my_app/absmartly_service.ex
defmodule MyApp.ABSmartlyService do
  use GenServer

  alias ABSmartly.{SDK, Context}

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
         |> assign(:treatment, treatment)
         |> assign(:loading, false)}

      {:error, reason} ->
        IO.puts("Failed to create context: #{inspect(reason)}")

        {:ok,
         socket
         |> assign(:context, nil)
         |> assign(:treatment, 0)
         |> assign(:loading, false)}
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
    <%= if @loading do %>
      <p>Loading experiment...</p>
    <% else %>
      <%= if @treatment == 0 do %>
        <div class="control-group">Control Layout</div>
      <% else %>
        <div class="treatment-group">Treatment Layout</div>
      <% end %>
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

      {:error, reason} ->
        IO.puts("Failed to create ABsmartly context: #{inspect(reason)}")
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

## Advanced Request Configuration

### Request Timeout with Task

Control context creation timeouts using Elixir Tasks.

```elixir
defmodule MyApp.ABSmartlyHelper do
  alias ABSmartly.{SDK, Context}

  @doc """
  Create a context with timeout protection.
  Returns {:ok, context} or {:error, :timeout}
  """
  def create_context_with_timeout(sdk, units, timeout_ms \\ 1500) do
    task =
      Task.async(fn ->
        SDK.create_context(sdk, units)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, context}} ->
        {:ok, context}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :timeout}
    end
  end
end

# Usage in controller
defmodule MyAppWeb.PageController do
  use MyAppWeb, :controller

  alias ABSmartly.Context
  alias MyApp.ABSmartlyHelper

  def index(conn, _params) do
    {:ok, sdk} = MyApp.ABSmartlyService.get_sdk()
    session_id = get_session(conn, :session_id)
    units = %{"session_id" => session_id}

    case ABSmartlyHelper.create_context_with_timeout(sdk, units, 1500) do
      {:ok, context} ->
        treatment = Context.treatment(context, "homepage_redesign")
        Context.finalize(context)

        render(conn, "index.html", treatment: treatment)

      {:error, :timeout} ->
        IO.puts("Context creation timed out, using default")
        render(conn, "index.html", treatment: 0)

      {:error, reason} ->
        IO.puts("Context creation failed: #{inspect(reason)}")
        render(conn, "index.html", treatment: 0)
    end
  end
end
```

### Request Cancellation with Process Monitoring

Implement cancellable context operations using GenServer and Task monitoring.

```elixir
defmodule MyApp.ExperimentManager do
  use GenServer

  alias ABSmartly.{SDK, Context}

  @doc """
  Start the experiment manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load an experiment context asynchronously.
  Returns {:ok, task_ref} that can be used for cancellation.
  """
  def load_experiment(session_id) do
    GenServer.call(__MODULE__, {:load_experiment, session_id})
  end

  @doc """
  Cancel a pending experiment load by task reference.
  """
  def cancel_load(task_ref) do
    GenServer.cast(__MODULE__, {:cancel_load, task_ref})
  end

  @doc """
  Get the result of a completed experiment load.
  """
  def get_result(task_ref) do
    GenServer.call(__MODULE__, {:get_result, task_ref})
  end

  @impl true
  def init(_opts) do
    {:ok, sdk} = MyApp.ABSmartlyService.get_sdk()
    {:ok, %{sdk: sdk, tasks: %{}}}
  end

  @impl true
  def handle_call({:load_experiment, session_id}, _from, state) do
    units = %{"session_id" => session_id}

    task =
      Task.async(fn ->
        case SDK.create_context(state.sdk, units) do
          {:ok, context} ->
            treatment = Context.treatment(context, "exp_product_layout")
            {:ok, context, treatment}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    task_ref = task.ref
    state = put_in(state.tasks[task_ref], task)

    {:reply, {:ok, task_ref}, state}
  end

  @impl true
  def handle_call({:get_result, task_ref}, _from, state) do
    case Map.get(state.tasks, task_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            state = update_in(state.tasks, &Map.delete(&1, task_ref))
            {:reply, {:ok, result}, state}

          nil ->
            {:reply, {:error, :pending}, state}
        end
    end
  end

  @impl true
  def handle_cast({:cancel_load, task_ref}, state) do
    case Map.get(state.tasks, task_ref) do
      nil ->
        {:noreply, state}

      task ->
        Task.shutdown(task, :brutal_kill)
        state = update_in(state.tasks, &Map.delete(&1, task_ref))
        IO.puts("Context loading cancelled for task #{inspect(task_ref)}")
        {:noreply, state}
    end
  end
end

# Usage example
{:ok, _} = MyApp.ExperimentManager.start_link([])

{:ok, task_ref} = MyApp.ExperimentManager.load_experiment("session_123")

# Cancel if user navigates away or request is cancelled
MyApp.ExperimentManager.cancel_load(task_ref)

# Or get the result when ready
case MyApp.ExperimentManager.get_result(task_ref) do
  {:ok, {:ok, context, treatment}} ->
    IO.puts("Treatment: #{treatment}")
    ABSmartly.Context.finalize(context)

  {:ok, {:error, reason}} ->
    IO.puts("Failed: #{inspect(reason)}")

  {:error, :pending} ->
    IO.puts("Still loading...")

  {:error, :not_found} ->
    IO.puts("Task not found")
end
```

## Error Handling

The SDK uses idiomatic Elixir patterns for error handling:

```elixir
# SDK initialization returns {:ok, sdk} or {:error, reason}
case SDK.new(
  endpoint: "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "production"
) do
  {:ok, sdk} ->
    # Use SDK to create contexts
    {:ok, context} = SDK.create_context(sdk, units)

  {:error, reason} ->
    # Handle initialization error
    Logger.error("Failed to initialize ABSmartly SDK: #{inspect(reason)}")
end

# Context creation returns {:ok, context} or {:error, reason}
case SDK.create_context(sdk, units) do
  {:ok, context} ->
    # Use context
    variant = Context.treatment(context, "exp_test")

  {:error, reason} ->
    # Handle error - log, use defaults, etc.
    Logger.error("Failed to create ABSmartly context: #{inspect(reason)}")
    default_variant = 0
end

# Most Context methods return :ok or the requested value
:ok = Context.set_attribute(context, "age", 25)
variant = Context.treatment(context, "exp_test")
```

## Testing Your Integration

### Mocking in Tests

```elixir
# In test_helper.exs or test
defmodule MyApp.MockABSmartly do
  def create_context(_sdk, _units) do
    # Return a mock context with predetermined variants
    {:ok, %{mock: true, overrides: %{"exp_test" => 1}}}
  end

  def treatment(%{mock: true, overrides: overrides}, exp_name) do
    Map.get(overrides, exp_name, 0)
  end
end

# In your tests
test "shows variant 1 of experiment" do
  # Use mock SDK
  context = %{mock: true, overrides: %{"homepage_redesign" => 1}}

  assert MyApp.Homepage.render(context) == :variant_1
end
```

### Using Overrides for E2E Tests

```elixir
# In E2E tests, use real SDK with overrides
test "purchase flow with new checkout" do
  {:ok, sdk} = MyApp.ABSmartly.get_sdk()
  {:ok, context} = SDK.create_context(sdk, %{"session_id" => "test-123"})

  # Force new checkout variant
  Context.set_override(context, "checkout_redesign", 1)

  # Test the new checkout flow
  assert Context.treatment(context, "checkout_redesign") == 1
end
```

## API Reference

For complete API documentation, visit [HexDocs](https://hexdocs.pm/absmartly).

### Main Modules

- `ABSmartly.SDK` - SDK initialization and context creation
- `ABSmartly.Context` - Context operations (treatment, tracking, etc.)
- `ABSmartly.Types` - Data structures (SDKConfig, ContextData, etc.)

## Examples

Check out the `examples/` directory for complete sample applications:

- **Phoenix Web App** - Full integration with Phoenix framework
- **Command Line Tool** - Simple CLI using ABsmartly
- **GenServer Integration** - Managing SDK as part of supervision tree

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/absmartly/context_test.exs
```

## License

This SDK is released under the MIT License. See [LICENSE](LICENSE) file for details.

## Support

- **Documentation**: https://hexdocs.pm/absmartly
- **Issues**: https://github.com/absmartly/elixir-sdk/issues
- **ABsmartly Docs**: https://docs.absmartly.com
- **Web Console**: https://app.absmartly.com

## About ABsmartly

ABsmartly is the leading A/B testing and feature flagging platform for modern engineering teams. It provides:

- **Real-time experimentation** - Instant variant assignment and analytics
- **Feature flags** - Progressive rollouts and kill switches
- **Statistical rigor** - Bayesian and Frequentist analysis
- **Full-stack testing** - Server-side, client-side, and mobile
- **Advanced targeting** - Audience segmentation and personalization

Visit [absmartly.com](https://www.absmartly.com) to learn more.
