defmodule SgiathChat.EventHandler do
  @moduledoc """
  Behaviour for handling conversation events.

  Implement this behaviour to receive callbacks for all conversation events,
  typically used for persisting messages to a database or logging.

  Unlike the `caller` PID which receives Erlang messages, the event handler
  is called synchronously via function callbacks. This ensures events are
  processed even if no caller is set.

  ## Required Callbacks

  - `on_message/2` - Called when a complete message is added to history
  - `on_error/2` - Called when an error occurs

  ## Optional Callbacks

  - `on_chunk/2` - Called for each streaming chunk (can be noisy)
  - `on_tool_call/3` - Called when a tool is about to be executed
  - `on_tool_result/3` - Called when a tool execution completes

  ## Example Implementation

      defmodule MyApp.ConversationPersistence do
        @behaviour SgiathChat.EventHandler
        
        require Logger

        @impl true
        def on_message(conversation_id, message) do
          # Persist message to database
          MyApp.Repo.insert!(%MyApp.Message{
            conversation_id: conversation_id,
            role: message["role"],
            content: message["content"],
            tool_calls: message["tool_calls"]
          })
          :ok
        end

        @impl true
        def on_error(conversation_id, reason) do
          Logger.error("Conversation \#{conversation_id} error: \#{inspect(reason)}")
          :ok
        end

        # Optional: track tool usage
        @impl true
        def on_tool_call(conversation_id, name, args) do
          Logger.info("Conversation \#{conversation_id} calling tool: \#{name}")
          :ok
        end

        @impl true
        def on_tool_result(conversation_id, name, result) do
          Logger.info("Conversation \#{conversation_id} tool \#{name} returned")
          :ok
        end
      end

  ## Usage with Conversation

      {:ok, pid} = SgiathChat.Conversation.start_supervised(
        id: "conv-123",
        model: "openai/gpt-4",
        event_handler: MyApp.ConversationPersistence,
        caller: self()  # Optional: also receive Erlang messages
      )
  """

  @doc """
  Called when a complete message is added to the conversation history.

  This includes user messages, assistant messages, and tool result messages.
  """
  @callback on_message(conversation_id :: term(), message :: map()) :: :ok

  @doc """
  Called when an error occurs during the conversation.

  The conversation remains usable after errors - the next `send_message`
  will attempt a new request.
  """
  @callback on_error(conversation_id :: term(), reason :: term()) :: :ok

  @doc """
  Called for each streaming chunk received from the LLM.

  This can be called many times per response. Implement only if you need
  real-time streaming data (e.g., for live display updates).
  """
  @callback on_chunk(conversation_id :: term(), chunk :: map()) :: :ok

  @doc """
  Called when a tool is about to be executed.
  """
  @callback on_tool_call(conversation_id :: term(), name :: String.t(), args :: map()) :: :ok

  @doc """
  Called when a tool execution completes.
  """
  @callback on_tool_result(conversation_id :: term(), name :: String.t(), result :: String.t()) ::
              :ok

  @optional_callbacks [on_chunk: 2, on_tool_call: 3, on_tool_result: 3]
end

