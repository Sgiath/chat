# SgiathChat

An opinionated Elixir library for communicating with the [OpenRouter API](https://openrouter.ai/). 
Built with [Mint](https://hexdocs.pm/mint/) for efficient HTTP connections.

## Features

- **Streaming & Non-streaming** - Both synchronous and streaming chat completions
- **Conversations** - Stateful conversation management with message history
- **Tool Calling** - Automatic tool discovery and execution via callback modules
- **Supervised Conversations** - Conversations that survive caller death (perfect for LiveView)
- **Event Handlers** - Callbacks for persistence and logging

## Installation

Add `sgiath_chat` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sgiath_chat, github: "sgiath/chat"},
  ]
end
```

## Configuration

Set your OpenRouter API key:

```elixir
# config/config.exs
config :sgiath_chat, :api_key, System.get_env("OPENROUTER_API_KEY")
```

Or pass it directly to any function via the `:api_key` option.

## Quick Start

### Simple Chat (Non-streaming)

```elixir
{:ok, response} = SgiathChat.chat(
  "openai/gpt-4o-mini",
  [%{"role" => "user", "content" => "Hello!"}]
)

IO.puts(response["content"])
# => "Hello! How can I assist you today?"
```

### Streaming

```elixir
{:ok, pid} = SgiathChat.stream(
  "openai/gpt-4o-mini",
  [%{"role" => "user", "content" => "Write a haiku about Elixir"}]
)

# Receive chunks
defmodule Receiver do
  def loop(pid) do
    receive do
      {:sgiath_chat, ^pid, {:chunk, data}} ->
        content = get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""
        IO.write(content)
        loop(pid)

      {:sgiath_chat, ^pid, {:done, response}} ->
        IO.puts("\n\nFull response: #{response["content"]}")

      {:sgiath_chat, ^pid, {:error, reason}} ->
        IO.inspect(reason, label: "Error")
    end
  end
end

Receiver.loop(pid)
```

## Conversations

Conversations maintain message history and automatically handle multi-turn interactions.

```elixir
{:ok, conv} = SgiathChat.conversation(
  model: "openai/gpt-4o-mini",
  messages: [%{"role" => "system", "content" => "You are a helpful assistant."}]
)

# Send messages (auto-triggers LLM request)
:ok = SgiathChat.Conversation.send_message(conv, "What's 2+2?")

# Receive the response
receive do
  {:sgiath_chat, ^conv, {:message, msg}} ->
    IO.puts("Assistant: #{msg["content"]}")
end

# Continue the conversation
:ok = SgiathChat.Conversation.send_message(conv, "Multiply that by 10")
```

## Tool Calling

Define tools by implementing the `SgiathChat.ToolHandler` behaviour:

```elixir
defmodule MyTools do
  @behaviour SgiathChat.ToolHandler

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_weather",
          "description" => "Get the current weather for a location",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["location"]
          }
        }
      }
    ]
  end

  @impl true
  def handle_tool_call("get_weather", %{"location" => location}) do
    # Call your weather API here
    {:ok, "Weather in #{location}: 22°C, sunny"}
  end
end

# Use with a conversation
{:ok, conv} = SgiathChat.conversation(
  model: "openai/gpt-4o-mini",
  tool_handler: MyTools
)

:ok = SgiathChat.Conversation.send_message(conv, "What's the weather in London?")
# Tools are automatically called and results fed back to the LLM
```

### Multiple Tool Handlers

You can compose multiple tool handlers. Tools from all handlers are aggregated and each tool call is routed to the handler that declared it:

```elixir
{:ok, conv} = SgiathChat.conversation(
  model: "openai/gpt-4o-mini",
  tool_handler: [WeatherTools, CalendarTools, DatabaseTools]
)
```

## Supervised Conversations

For applications where conversations should survive process crashes (like LiveView), use supervised conversations.

### Setup

Add the supervisor to your application:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    SgiathChat.Supervisor,
    # ... other children
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

### Usage

```elixir
# Start a supervised conversation with an ID
{:ok, pid} = SgiathChat.conversation_supervised(
  id: "user-123-conv-456",
  model: "openai/gpt-4o-mini",
  event_handler: [MyApp.ChatPersistence, MyApp.ChatLogger],
  caller: self()
)

# Later, reconnect from a new process
pid = SgiathChat.Conversation.whereis("user-123-conv-456")
:ok = SgiathChat.Conversation.set_caller(pid, self())
```

### Event Handler for Persistence

```elixir
defmodule MyApp.ChatPersistence do
  @behaviour SgiathChat.EventHandler

  @impl true
  def on_message(conversation_id, message) do
    # Persist to database - message["role"] tells you the type
    MyApp.Repo.insert!(%MyApp.Message{
      conversation_id: conversation_id,
      role: message["role"],  # "system", "user", "assistant", or "tool"
      content: message["content"]
    })
    :ok
  end

  @impl true
  def on_error(conversation_id, reason) do
    Logger.error("Conversation #{conversation_id} error: #{inspect(reason)}")
    :ok
  end

  # Optional callbacks
  @impl true
  def on_tool_call(conversation_id, name, args) do
    Logger.info("#{conversation_id} calling tool: #{name}")
    :ok
  end
end
```

### Multiple Event Handlers

You can compose multiple event handlers for different concerns (persistence, logging, analytics):

```elixir
{:ok, pid} = SgiathChat.conversation_supervised(
  id: "conv-123",
  model: "openai/gpt-4o-mini",
  event_handler: [MyApp.ChatPersistence, MyApp.ChatLogger, MyApp.Analytics],
  caller: self()
)
```

All handlers receive callbacks for all events, making it easy to separate concerns and enable/disable behaviors independently.

### New vs Restored Conversations

Use `:persist_initial` to control whether initial messages are emitted to the event handler:

```elixir
# NEW conversation - persist the system message
{:ok, pid} = SgiathChat.conversation_supervised(
  id: "conv-123",
  model: "openai/gpt-4o-mini",
  messages: [%{"role" => "system", "content" => "You are helpful."}],
  persist_initial: true,  # System message will be saved to DB
  event_handler: MyApp.ChatPersistence,
  caller: self()
)

# User sends first message - also persisted, triggers API call
:ok = SgiathChat.Conversation.send_message(pid, "Hello!")
```

```elixir
# RESTORE conversation from database - don't re-persist
messages = MyApp.Repo.get_messages("conv-123")

{:ok, pid} = SgiathChat.conversation_supervised(
  id: "conv-123",
  model: "openai/gpt-4o-mini",
  messages: messages,
  persist_initial: false,  # Don't duplicate existing messages (default)
  event_handler: MyApp.ChatPersistence,
  caller: self()
)

# New message - persisted, triggers API call
:ok = SgiathChat.Conversation.send_message(pid, "Continue our conversation")
```

### LiveView Integration

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def mount(%{"id" => conv_id}, _session, socket) do
    if connected?(socket) do
      case SgiathChat.Conversation.whereis(conv_id) do
        nil ->
          {:ok, _} = SgiathChat.conversation_supervised(
            id: conv_id,
            model: "openai/gpt-4o-mini",
            event_handler: MyApp.ChatPersistence,
            caller: self()
          )

        pid ->
          :ok = SgiathChat.Conversation.set_caller(pid, self())
      end
    end

    messages = SgiathChat.Conversation.get_messages(conv_id) || []
    {:ok, assign(socket, conv_id: conv_id, messages: messages)}
  end

  def handle_event("send", %{"message" => text}, socket) do
    :ok = SgiathChat.Conversation.send_message(socket.assigns.conv_id, text)
    {:noreply, socket}
  end

  def handle_info({:sgiath_chat, _pid, {:message, msg}}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg])}
  end

  def handle_info({:sgiath_chat, _pid, {:chunk, _data}}, socket) do
    # Handle streaming chunks for real-time display
    {:noreply, socket}
  end
end
```

## API Reference

### Main Functions

| Function | Description |
|----------|-------------|
| `SgiathChat.chat/3` | Synchronous chat completion |
| `SgiathChat.stream/3` | Streaming chat completion |
| `SgiathChat.conversation/1` | Start a conversation (linked to caller) |
| `SgiathChat.conversation_supervised/1` | Start a supervised conversation |
| `SgiathChat.cancel/1` | Cancel a streaming request |

### Conversation Functions

| Function | Description |
|----------|-------------|
| `Conversation.send_message/2` | Send a user message |
| `Conversation.get_messages/1` | Get conversation history |
| `Conversation.whereis/1` | Lookup supervised conversation by ID |
| `Conversation.set_caller/2` | Update the caller PID |
| `Conversation.stop/1` | Stop a conversation |

### Common Options

- `:model` - Model identifier (e.g., `"openai/gpt-4o-mini"`)
- `:messages` - Initial message history
- `:tool_handler` - Module or list of modules implementing `SgiathChat.ToolHandler`
- `:event_handler` - Module or list of modules implementing `SgiathChat.EventHandler`
- `:api_key` - OpenRouter API key
- `:persist_initial` - Emit initial messages to event handlers (default: false)
- `:timeout` - Request timeout in ms (default: 60,000)
- `:temperature` - Sampling temperature (0.0 to 2.0)
- `:max_tokens` - Maximum tokens to generate
- `:top_p` - Top-p sampling parameter
- `:frequency_penalty` - Frequency penalty (-2.0 to 2.0)
- `:presence_penalty` - Presence penalty (-2.0 to 2.0)

## Error Handling

All errors are returned as `{:error, reason}` tuples. The library never retries automatically.

| Error | Description |
|-------|-------------|
| `:missing_api_key` | No API key configured |
| `{:connect_error, reason}` | Failed to connect |
| `{:http_error, status, body}` | Non-2xx HTTP response |
| `{:api_error, error}` | OpenRouter returned an error |
| `:timeout` | Request timed out |
