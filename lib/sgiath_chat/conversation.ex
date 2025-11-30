defmodule SgiathChat.Conversation do
  @moduledoc """
  GenServer managing a stateful conversation with automatic tool execution.

  A Conversation maintains message history, automatically sends requests to the LLM
  when user messages are added, handles streaming responses, and executes tool calls
  via the provided tool handler modules.

  ## Supervised vs Unsupervised

  Conversations can be started in two modes:

  1. **Unsupervised** (`start_link/1`) - Linked to caller, dies when caller dies
  2. **Supervised** (`start_supervised/1`) - Managed by `SgiathChat.Supervisor`,
     survives caller death, can be looked up by ID

  ## Starting a Supervised Conversation

      # Requires SgiathChat.Supervisor in your supervision tree
      {:ok, pid} = SgiathChat.Conversation.start_supervised(
        id: "conv-123",
        model: "openai/gpt-4",
        messages: [%{"role" => "system", "content" => "You are helpful."}],
        tool_handler: [MyTools, AnotherTools],
        event_handler: [MyApp.Persistence, MyApp.Logger],
        caller: self()
      )

  ## Reconnecting After Caller Death

      # In a new LiveView process
      case SgiathChat.Conversation.whereis("conv-123") do
        nil -> # conversation doesn't exist
        pid -> SgiathChat.Conversation.set_caller(pid, self())
      end

  ## Messages Received by Caller

  The caller receives messages in the format `{:sgiath_chat, pid, event}`:

  - `{:chunk, data}` - Streaming chunk from LLM
  - `{:message, assistant_message}` - Complete assistant message added to history
  - `{:tool_call, name, arguments}` - Tool is being executed
  - `{:tool_result, name, result}` - Tool execution completed
  - `{:error, reason}` - Error occurred (conversation ready for retry)

  ## Event Handlers

  The `event_handler` option accepts a module or list of modules implementing
  `SgiathChat.EventHandler`. All handlers receive callbacks for all events.
  This is useful for composing persistence, logging, and monitoring behaviors.

  ## Tool Handlers

  The `tool_handler` option accepts a module or list of modules implementing
  `SgiathChat.ToolHandler`. Tools from all handlers are aggregated and each
  tool call is routed to the handler that declared that tool.
  See `SgiathChat.ToolHandler` for the behaviour specification.
  """

  use GenServer

  require Logger

  alias SgiathChat.HTTP
  alias SgiathChat.SSE

  defstruct [
    :id,
    :model,
    :caller,
    :api_key,
    :conn,
    :request_ref,
    :timeout_ref,
    tool_handlers: [],
    event_handlers: [],
    tool_routing: %{},
    messages: [],
    tools: nil,
    opts: [],
    buffer: "",
    pending_chunks: [],
    status: nil,
    headers: [],
    busy: false
  ]

  @type t :: %__MODULE__{
          id: term() | nil,
          model: String.t(),
          tool_handlers: [module()],
          event_handlers: [module()],
          tool_routing: %{String.t() => module()},
          caller: pid() | nil,
          api_key: String.t(),
          conn: Mint.HTTP.t() | nil,
          request_ref: reference() | nil,
          timeout_ref: reference() | nil,
          messages: [map()],
          tools: [map()] | nil,
          opts: keyword(),
          buffer: binary(),
          pending_chunks: [map()],
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          busy: boolean()
        }

  # Client API

  @doc """
  Starts a new conversation (linked to caller).

  Use this for conversations that should die when the caller dies.
  For supervised conversations, use `start_supervised/1`.

  ## Options

  - `:model` - Required. The model identifier (e.g., "openai/gpt-4")
  - `:messages` - Optional. Initial message history (default: [])
  - `:tool_handler` - Optional. Module or list of modules implementing `SgiathChat.ToolHandler`
  - `:event_handler` - Optional. Module or list of modules implementing `SgiathChat.EventHandler`
  - `:persist_initial` - Optional. Emit initial messages to event handlers (default: false)
  - `:caller` - Optional. PID to receive messages (default: calling process)
  - `:api_key` - Optional. OpenRouter API key (default: from config)
  - `:timeout` - Optional. Request timeout in ms (default: 60_000)
  - `:temperature` - Optional. Sampling temperature
  - `:max_tokens` - Optional. Maximum tokens to generate
  - `:top_p` - Optional. Top-p sampling parameter
  - `:frequency_penalty` - Optional. Frequency penalty
  - `:presence_penalty` - Optional. Presence penalty
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = extract_gen_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts a supervised conversation.

  Requires `SgiathChat.Supervisor` to be running in your supervision tree.
  The conversation will survive caller death and can be looked up by ID.

  ## Options

  Same as `start_link/1`, plus:

  - `:id` - Required. Unique identifier for the conversation (used for lookup)

  ## Example

      {:ok, pid} = SgiathChat.Conversation.start_supervised(
        id: "conv-123",
        model: "openai/gpt-4",
        event_handler: [MyApp.Persistence, MyApp.Logger]
      )
  """
  @spec start_supervised(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_supervised(opts) do
    unless Keyword.has_key?(opts, :id) do
      raise ArgumentError, "`:id` is required for supervised conversations"
    end

    DynamicSupervisor.start_child(
      SgiathChat.ConversationSupervisor,
      {__MODULE__, opts}
    )
  end

  @doc """
  Looks up a conversation by ID.

  Returns the PID if found, or `nil` if not found.

  ## Example

      case SgiathChat.Conversation.whereis("conv-123") do
        nil -> IO.puts("Not found")
        pid -> IO.puts("Found: \#{inspect(pid)}")
      end
  """
  @spec whereis(term()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(SgiathChat.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Updates the caller PID for a conversation.

  Use this to reconnect to a conversation from a new process
  (e.g., after a LiveView reconnect).

  ## Example

      :ok = SgiathChat.Conversation.set_caller("conv-123", self())
      # or
      :ok = SgiathChat.Conversation.set_caller(pid, self())
  """
  @spec set_caller(pid() | term(), pid() | nil) :: :ok
  def set_caller(pid_or_id, new_caller) when is_pid(pid_or_id) do
    GenServer.call(pid_or_id, {:set_caller, new_caller})
  end

  def set_caller(id, new_caller) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:set_caller, new_caller})
    end
  end

  @doc """
  Sends a user message to the conversation.

  This automatically triggers an LLM request with the full conversation history.
  Returns `:ok` if the message was queued, or `{:error, :busy}` if a request
  is already in progress.
  """
  @spec send_message(pid() | term(), String.t()) :: :ok | {:error, :busy | :not_found}
  def send_message(pid, content) when is_pid(pid) do
    GenServer.call(pid, {:send_message, content})
  end

  def send_message(id, content) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:send_message, content})
    end
  end

  @doc """
  Returns the current conversation history.
  """
  @spec get_messages(pid() | term()) :: [map()] | {:error, :not_found}
  def get_messages(pid) when is_pid(pid) do
    GenServer.call(pid, :get_messages)
  end

  def get_messages(id) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_messages)
    end
  end

  @doc """
  Returns the conversation ID, or nil if not registered.
  """
  @spec get_id(pid()) :: term() | nil
  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  @doc """
  Stops the conversation.
  """
  @spec stop(pid() | term()) :: :ok | {:error, :not_found}
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  def stop(id) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # Child spec for DynamicSupervisor

  def child_spec(opts) do
    id = Keyword.get(opts, :id, make_ref())

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # Server callbacks

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    id = Keyword.get(opts, :id)
    caller = Keyword.get(opts, :caller)
    messages = Keyword.get(opts, :messages, [])
    persist_initial = Keyword.get(opts, :persist_initial, false)

    # Normalize handlers to lists (supports both single module and list)
    tool_handlers = opts |> Keyword.get(:tool_handler) |> List.wrap()
    event_handlers = opts |> Keyword.get(:event_handler) |> List.wrap()

    case HTTP.get_api_key(opts) do
      {:error, :missing_api_key} ->
        {:stop, {:error, :missing_api_key}}

      {:ok, api_key} ->
        # Discover tools from all handlers and build routing map
        {tools, tool_routing} = discover_tools(tool_handlers)

        # Extract model parameters
        model_opts =
          Keyword.take(opts, [
            :timeout,
            :temperature,
            :max_tokens,
            :top_p,
            :frequency_penalty,
            :presence_penalty
          ])

        state = %__MODULE__{
          id: id,
          model: model,
          tool_handlers: tool_handlers,
          event_handlers: event_handlers,
          tool_routing: tool_routing,
          caller: caller,
          api_key: api_key,
          messages: messages,
          tools: tools,
          opts: model_opts
        }

        # Emit initial messages to event handlers if persist_initial is true
        if persist_initial do
          Enum.each(messages, fn msg ->
            Enum.each(event_handlers, &(&1.on_message(id, msg)))
          end)
        end

        {:ok, state}
    end
  end

  @impl true
  def handle_call({:set_caller, new_caller}, _from, state) do
    {:reply, :ok, %{state | caller: new_caller}}
  end

  def handle_call({:send_message, _content}, _from, %{busy: true} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, content}, _from, state) do
    user_message = %{"role" => "user", "content" => content}
    messages = state.messages ++ [user_message]

    # Notify about user message
    emit_message(state, user_message)

    state = %{state | messages: messages, busy: true}

    # Start the LLM request
    send(self(), :start_request)

    {:reply, :ok, state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_id, _from, state) do
    {:reply, state.id, state}
  end

  @impl true
  def handle_info(:start_request, state) do
    case start_streaming_request(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        emit_error(state, reason)
        {:noreply, %{state | busy: false}}
    end
  end

  def handle_info(:timeout, state) do
    emit_error(state, :timeout)
    cleanup_connection(state)
    {:noreply, %{state | busy: false, conn: nil, request_ref: nil, timeout_ref: nil}}
  end

  def handle_info(message, %{conn: nil} = state) do
    # No active connection, ignore message
    Logger.debug("Received message with no active connection: #{inspect(message)}")
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        Logger.debug("Received unknown message: #{inspect(message)}")
        {:noreply, state}

      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_responses(responses, state)

      {:error, conn, error, _responses} ->
        state = %{state | conn: conn}
        emit_error(state, {:connection_error, error})
        cleanup_connection(state)
        {:noreply, %{state | busy: false, conn: nil, request_ref: nil}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_connection(state)
    :ok
  end

  # Private functions

  defp extract_gen_opts(opts) do
    case Keyword.get(opts, :id) do
      nil ->
        {[], opts}

      id ->
        gen_opts = [name: {:via, Registry, {SgiathChat.Registry, id}}]
        {gen_opts, opts}
    end
  end

  defp discover_tools([]), do: {nil, %{}}

  defp discover_tools(handlers) do
    {tools, routing} =
      Enum.reduce(handlers, {[], %{}}, fn handler, {tools_acc, routing_acc} ->
        handler_tools = handler.tools()

        new_routing =
          Enum.reduce(handler_tools, routing_acc, fn tool, acc ->
            name = get_in(tool, ["function", "name"])
            Map.put(acc, name, handler)
          end)

        {tools_acc ++ handler_tools, new_routing}
      end)

    {tools, routing}
  end

  defp start_streaming_request(state) do
    timeout = Keyword.get(state.opts, :timeout, HTTP.default_timeout())

    request_opts =
      state.opts
      |> Keyword.put(:stream, true)
      |> Keyword.put(:tools, state.tools)

    with {:ok, conn} <- HTTP.connect(),
         {:ok, conn, request_ref} <-
           HTTP.request(conn, state.model, state.messages, state.api_key, request_opts) do
      timeout_ref = Process.send_after(self(), :timeout, timeout)

      {:ok,
       %{
         state
         | conn: conn,
           request_ref: request_ref,
           timeout_ref: timeout_ref,
           buffer: "",
           pending_chunks: [],
           status: nil,
           headers: []
       }}
    end
  end

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {_, state} ->
      case handle_response(response, state) do
        {:continue, new_state} ->
          {:cont, {:noreply, new_state}}

        {:done, new_state} ->
          {:halt, {:noreply, new_state}}

        {:error, reason, new_state} ->
          emit_error(new_state, reason)
          {:halt, {:noreply, %{new_state | busy: false}}}
      end
    end)
  end

  defp handle_response({:status, _ref, status}, state) do
    {:continue, %{state | status: status}}
  end

  defp handle_response({:headers, _ref, headers}, state) do
    {:continue, %{state | headers: headers}}
  end

  defp handle_response({:data, _ref, data}, state) do
    buffer = state.buffer <> data

    if state.status < 200 or state.status >= 300 do
      {:continue, %{state | buffer: buffer}}
    else
      {events, remaining} = SSE.parse_lines(buffer)
      state = %{state | buffer: remaining}
      process_events(events, state)
    end
  end

  defp handle_response({:done, _ref}, state) do
    cancel_timeout(state.timeout_ref)

    if state.status < 200 or state.status >= 300 do
      error_body = parse_error_body(state.buffer)
      emit_error(state, {:http_error, state.status, error_body})
      cleanup_connection(state)
      {:done, %{state | busy: false, conn: nil, request_ref: nil, timeout_ref: nil}}
    else
      # Normal completion - finalize the response
      finalize_response(state)
    end
  end

  defp handle_response({:error, _ref, reason}, state) do
    cancel_timeout(state.timeout_ref)
    cleanup_connection(state)
    {:error, {:stream_error, reason}, %{state | conn: nil, request_ref: nil, timeout_ref: nil}}
  end

  defp process_events(events, state) do
    Enum.reduce_while(events, {:continue, state}, fn event, {_, state} ->
      case process_event(event, state) do
        {:continue, new_state} -> {:cont, {:continue, new_state}}
        {:done, new_state} -> {:halt, {:done, new_state}}
        {:error, reason, new_state} -> {:halt, {:error, reason, new_state}}
      end
    end)
  end

  defp process_event({:data, data}, state) do
    if Map.has_key?(data, "error") do
      {:error, {:api_error, data["error"]}, state}
    else
      # Forward chunk
      emit_chunk(state, data)

      # Accumulate chunk
      state = %{state | pending_chunks: [data | state.pending_chunks]}
      {:continue, state}
    end
  end

  defp process_event(:done, state) do
    cancel_timeout(state.timeout_ref)
    finalize_response(state)
  end

  defp process_event({:error, reason}, state) do
    {:error, {:parse_error, reason}, state}
  end

  defp finalize_response(state) do
    cleanup_connection(state)
    chunks = Enum.reverse(state.pending_chunks)

    # Build the assistant message from chunks
    {content, tool_calls} = extract_response(chunks)

    cond do
      # Has tool calls - execute them and continue
      tool_calls != [] and state.tool_handlers != [] ->
        handle_tool_calls(state, content, tool_calls)

      # Regular message
      true ->
        assistant_message = build_assistant_message(content, tool_calls)
        messages = state.messages ++ [assistant_message]

        emit_message(state, assistant_message)

        {:done,
         %{
           state
           | messages: messages,
             busy: false,
             conn: nil,
             request_ref: nil,
             timeout_ref: nil,
             pending_chunks: []
         }}
    end
  end

  defp extract_response(chunks) do
    # Extract content from deltas
    content =
      chunks
      |> Enum.map(fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "content"]) || ""
      end)
      |> Enum.join("")

    # Extract tool calls from deltas
    tool_calls = extract_tool_calls(chunks)

    {content, tool_calls}
  end

  defp extract_tool_calls(chunks) do
    # Tool calls come in pieces across chunks, we need to accumulate them
    chunks
    |> Enum.reduce(%{}, fn chunk, acc ->
      case get_in(chunk, ["choices", Access.at(0), "delta", "tool_calls"]) do
        nil ->
          acc

        tool_calls_delta ->
          Enum.reduce(tool_calls_delta, acc, fn tc, acc ->
            index = tc["index"]

            existing =
              Map.get(acc, index, %{
                "id" => nil,
                "type" => "function",
                "function" => %{"name" => "", "arguments" => ""}
              })

            updated =
              existing
              |> maybe_update("id", tc["id"])
              |> maybe_update_nested(["function", "name"], get_in(tc, ["function", "name"]))
              |> maybe_update_nested(
                ["function", "arguments"],
                get_in(tc, ["function", "arguments"])
              )

            Map.put(acc, index, updated)
          end)
      end
    end)
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
  end

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp maybe_update_nested(map, _path, nil), do: map

  defp maybe_update_nested(map, [key1, key2], value) do
    current = get_in(map, [key1, key2]) || ""
    put_in(map, [key1, key2], current <> value)
  end

  defp build_assistant_message(content, []) do
    %{"role" => "assistant", "content" => content}
  end

  defp build_assistant_message(content, tool_calls) do
    %{"role" => "assistant", "content" => content, "tool_calls" => tool_calls}
  end

  defp handle_tool_calls(state, content, tool_calls) do
    # Add assistant message with tool calls to history
    assistant_message = build_assistant_message(content, tool_calls)
    messages = state.messages ++ [assistant_message]

    emit_message(state, assistant_message)

    # Execute each tool call and collect results
    tool_results =
      Enum.map(tool_calls, fn tc ->
        name = get_in(tc, ["function", "name"])
        args_json = get_in(tc, ["function", "arguments"]) || "{}"

        args =
          case JSON.decode(args_json) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        emit_tool_call(state, name, args)

        handler = Map.get(state.tool_routing, name)

        result =
          case handler.handle_tool_call(name, args) do
            {:ok, result} ->
              emit_tool_result(state, name, result)
              result

            {:error, reason} ->
              error_msg = "Error: #{inspect(reason)}"
              emit_tool_result(state, name, error_msg)
              error_msg
          end

        tool_message = %{
          "role" => "tool",
          "tool_call_id" => tc["id"],
          "content" => result
        }

        emit_message(state, tool_message)

        tool_message
      end)

    # Add tool results to messages
    messages = messages ++ tool_results

    # Continue conversation with tool results
    state = %{
      state
      | messages: messages,
        conn: nil,
        request_ref: nil,
        timeout_ref: nil,
        pending_chunks: []
    }

    # Start new request with tool results
    send(self(), :start_request)

    {:done, state}
  end

  defp parse_error_body(buffer) do
    case JSON.decode(buffer) do
      {:ok, parsed} -> parsed
      {:error, _} -> buffer
    end
  end

  defp cleanup_connection(state) do
    cancel_timeout(state.timeout_ref)
    HTTP.close(state.conn)
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  # Event emission helpers - send to both caller and event_handlers

  defp emit_chunk(state, data) do
    # Send to caller if set
    if state.caller, do: send(state.caller, {:sgiath_chat, self(), {:chunk, data}})

    # Call all event handlers that implement on_chunk
    Enum.each(state.event_handlers, fn handler ->
      if function_exported?(handler, :on_chunk, 2) do
        handler.on_chunk(state.id, data)
      end
    end)
  end

  defp emit_message(state, message) do
    # Send to caller if set
    if state.caller, do: send(state.caller, {:sgiath_chat, self(), {:message, message}})

    # Call all event handlers
    Enum.each(state.event_handlers, &(&1.on_message(state.id, message)))
  end

  defp emit_tool_call(state, name, args) do
    # Send to caller if set
    if state.caller, do: send(state.caller, {:sgiath_chat, self(), {:tool_call, name, args}})

    # Call all event handlers that implement on_tool_call
    Enum.each(state.event_handlers, fn handler ->
      if function_exported?(handler, :on_tool_call, 3) do
        handler.on_tool_call(state.id, name, args)
      end
    end)
  end

  defp emit_tool_result(state, name, result) do
    # Send to caller if set
    if state.caller, do: send(state.caller, {:sgiath_chat, self(), {:tool_result, name, result}})

    # Call all event handlers that implement on_tool_result
    Enum.each(state.event_handlers, fn handler ->
      if function_exported?(handler, :on_tool_result, 3) do
        handler.on_tool_result(state.id, name, result)
      end
    end)
  end

  defp emit_error(state, reason) do
    # Send to caller if set
    if state.caller, do: send(state.caller, {:sgiath_chat, self(), {:error, reason}})

    # Call all event handlers
    Enum.each(state.event_handlers, &(&1.on_error(state.id, reason)))
  end
end
