defmodule SgiathChat do
  @moduledoc """
  Opinionated library for communicating with OpenRouter API.

  This library provides a simple interface for chat completions from OpenRouter,
  supporting both streaming and non-streaming requests. It handles connection
  management and error handling, while leaving retry logic to the caller.

  ## Configuration

  Set your OpenRouter API key in your config:

      config :sgiath_chat, :api_key, System.get_env("OPENROUTER_API_KEY")

  Or pass it directly when making a request.

  ## Non-Streaming Usage

      # Simple request/response
      {:ok, response} = SgiathChat.chat(
        "openai/gpt-4",
        [%{"role" => "user", "content" => "Hello!"}],
        temperature: 0.7
      )

      IO.puts(response["content"])

  ## Streaming Usage

      # Start a streaming request
      {:ok, pid} = SgiathChat.stream(
        "openai/gpt-4",
        [%{"role" => "user", "content" => "Hello!"}],
        temperature: 0.7
      )

      # Receive streaming responses in a loop
      defmodule Receiver do
        def loop(pid) do
          receive do
            {:sgiath_chat, ^pid, {:chunk, data}} ->
              content = get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""
              IO.write(content)
              loop(pid)

            {:sgiath_chat, ^pid, {:done, full_response}} ->
              IO.puts("\\nDone: \#{full_response["content"]}")

            {:sgiath_chat, ^pid, {:error, reason}} ->
              IO.inspect(reason)
          end
        end
      end

      Receiver.loop(pid)

  ## Streaming Messages

  The caller receives messages in the format `{:sgiath_chat, pid, event}`:

  - `{:chunk, data}` - Each parsed SSE data chunk from the stream
  - `{:done, full_response}` - Final accumulated response with all content
  - `{:error, reason}` - Error occurred (timeout, connection closed, etc.)

  ## Error Handling

  The library reports errors but never retries automatically. Possible errors:

  - `{:error, :missing_api_key}` - No API key configured or provided
  - `{:error, {:connect_error, reason}}` - Failed to connect to OpenRouter
  - `{:error, {:request_error, reason}}` - Failed to send request
  - `{:error, {:http_error, status, body}}` - Non-2xx HTTP response
  - `{:error, {:api_error, error}}` - OpenRouter returned an error in SSE stream
  - `{:error, {:connection_error, reason}}` - Connection error during streaming
  - `{:error, {:parse_error, reason}}` - Failed to parse SSE data
  - `{:error, :timeout}` - Request exceeded configured timeout
  """

  alias SgiathChat.{Completion, Conversation, Request}

  @type message :: %{required(String.t()) => String.t()}
  @type option ::
          {:api_key, String.t()}
          | {:caller, pid()}
          | {:timeout, non_neg_integer()}
          | {:temperature, float()}
          | {:max_tokens, non_neg_integer()}
          | {:top_p, float()}
          | {:frequency_penalty, float()}
          | {:presence_penalty, float()}

  @doc """
  Sends a non-streaming chat completion request and waits for the response.

  This is a synchronous call that blocks until the full response is received.

  ## Parameters

  - `model` - The model identifier (e.g., "openai/gpt-4", "anthropic/claude-3-opus")
  - `messages` - List of message maps with "role" and "content" keys
  - `opts` - Optional keyword list of options

  ## Options

  - `:api_key` - OpenRouter API key (overrides config)
  - `:timeout` - Request timeout in milliseconds (default: 60_000)
  - `:temperature` - Sampling temperature (0.0 to 2.0)
  - `:max_tokens` - Maximum tokens to generate
  - `:top_p` - Top-p (nucleus) sampling parameter
  - `:frequency_penalty` - Frequency penalty (-2.0 to 2.0)
  - `:presence_penalty` - Presence penalty (-2.0 to 2.0)

  ## Examples

      # Basic usage
      {:ok, response} = SgiathChat.chat(
        "openai/gpt-4",
        [%{"role" => "user", "content" => "Hello!"}]
      )

      IO.puts(response["content"])

      # With options
      {:ok, response} = SgiathChat.chat(
        "anthropic/claude-3-opus",
        [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "Write a haiku about Elixir."}
        ],
        temperature: 0.7,
        max_tokens: 100
      )

  ## Response Format

  The response is a map containing:
  - `"content"` - The assistant's response text (extracted for convenience)
  - `"choices"` - Full choices array from the API
  - `"model"` - The model used
  - `"id"` - Request ID
  - `"usage"` - Token usage information
  """
  @spec chat(String.t(), [message()], [option()]) :: {:ok, map()} | {:error, term()}
  def chat(model, messages, opts \\ []) do
    Completion.call(model, messages, opts)
  end

  @doc """
  Starts a streaming chat completion request.

  Returns `{:ok, pid}` where `pid` is the request process, or `{:error, reason}`
  if the request couldn't be started.

  ## Parameters

  - `model` - The model identifier (e.g., "openai/gpt-4", "anthropic/claude-3-opus")
  - `messages` - List of message maps with "role" and "content" keys
  - `opts` - Optional keyword list of options

  ## Options

  - `:api_key` - OpenRouter API key (overrides config)
  - `:caller` - PID to receive messages (defaults to calling process)
  - `:timeout` - Request timeout in milliseconds (default: 60_000)
  - `:temperature` - Sampling temperature (0.0 to 2.0)
  - `:max_tokens` - Maximum tokens to generate
  - `:top_p` - Top-p (nucleus) sampling parameter
  - `:frequency_penalty` - Frequency penalty (-2.0 to 2.0)
  - `:presence_penalty` - Presence penalty (-2.0 to 2.0)

  ## Examples

      # Basic usage
      {:ok, pid} = SgiathChat.stream(
        "openai/gpt-4",
        [%{"role" => "user", "content" => "Hello!"}]
      )

      # With options
      {:ok, pid} = SgiathChat.stream(
        "anthropic/claude-3-opus",
        [
          %{"role" => "system", "content" => "You are a helpful assistant."},
          %{"role" => "user", "content" => "Write a haiku about Elixir."}
        ],
        temperature: 0.7,
        max_tokens: 100,
        timeout: 30_000
      )

      # With explicit API key
      {:ok, pid} = SgiathChat.stream(
        "openai/gpt-4",
        [%{"role" => "user", "content" => "Hello!"}],
        api_key: "sk-or-..."
      )
  """
  @spec stream(String.t(), [message()], [option()]) :: {:ok, pid()} | {:error, term()}
  def stream(model, messages, opts \\ []) do
    # Ensure caller is set to current process if not specified
    opts = Keyword.put_new(opts, :caller, self())

    case Request.start_link(model, messages, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels an ongoing streaming request.

  The request process will be terminated and no further messages will be sent.

  ## Example

      {:ok, pid} = SgiathChat.stream("openai/gpt-4", messages)
      # ... later ...
      :ok = SgiathChat.cancel(pid)
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    Request.cancel(pid)
  end

  @doc """
  Starts a new conversation (linked to caller).

  A conversation manages message history, automatically sends requests to the LLM
  when user messages are added, and executes tool calls via the provided handlers.

  For supervised conversations that survive caller death, use `conversation_supervised/1`.

  ## Options

  - `:model` - Required. The model identifier (e.g., "openai/gpt-4")
  - `:messages` - Optional. Initial message history (default: [])
  - `:tool_handler` - Optional. Module or list of modules/tuples implementing `SgiathChat.ToolHandler` (e.g., `[MyTools, {WeatherTools, context}]`)
  - `:event_handler` - Optional. Module or list of modules implementing `SgiathChat.EventHandler`
  - `:caller` - Optional. PID to receive messages (default: calling process)
  - `:api_key` - Optional. OpenRouter API key (default: from config)
  - `:timeout` - Optional. Request timeout in ms (default: 60_000)
  - `:temperature`, `:max_tokens`, etc. - Model parameters

  ## Example

      # Start a conversation with multiple handlers
      {:ok, conv} = SgiathChat.conversation(
        model: "openai/gpt-4",
        messages: [%{"role" => "system", "content" => "You are helpful."}],
        tool_handler: [CalendarTools, {WeatherTools, %{api_key: "..."}}],
        event_handler: [MyApp.Logger, MyApp.Persistence]
      )

      # Send a message (triggers LLM request)
      :ok = SgiathChat.Conversation.send_message(conv, "Hello!")

  ## Messages

  The caller receives messages in the format `{:sgiath_chat, pid, event}`:

  - `{:chunk, data}` - Streaming chunk from LLM
  - `{:message, assistant_message}` - Complete assistant message added to history
  - `{:tool_call, name, arguments}` - Tool is being executed
  - `{:tool_result, name, result}` - Tool execution completed
  - `{:error, reason}` - Error occurred (conversation ready for retry)
  """
  @spec conversation(keyword()) :: {:ok, pid()} | {:error, term()}
  def conversation(opts) do
    opts = Keyword.put_new(opts, :caller, self())

    case Conversation.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a supervised conversation.

  Requires `SgiathChat.Supervisor` to be running in your supervision tree.
  The conversation survives caller death and can be looked up by ID.

  ## Options

  Same as `conversation/1`, plus:

  - `:id` - Required. Unique identifier for the conversation

  ## Example

      # In your Application supervisor
      children = [
        SgiathChat.Supervisor,
        # ...
      ]

      # Start a supervised conversation with multiple handlers
      {:ok, conv} = SgiathChat.conversation_supervised(
        id: "conv-123",
        model: "openai/gpt-4",
        event_handler: [MyApp.Persistence, MyApp.Logger],
        caller: self()
      )

      # Later, reconnect from a new process (e.g., after LiveView reconnect)
      pid = SgiathChat.Conversation.whereis("conv-123")
      :ok = SgiathChat.Conversation.set_caller(pid, self())
  """
  @spec conversation_supervised(keyword()) :: {:ok, pid()} | {:error, term()}
  def conversation_supervised(opts) do
    opts = Keyword.put_new(opts, :caller, self())

    case Conversation.start_supervised(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
