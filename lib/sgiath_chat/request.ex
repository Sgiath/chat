defmodule SgiathChat.Request do
  @moduledoc """
  GenServer managing individual streaming requests to OpenRouter API.

  Each request runs in its own GenServer that:
  1. Connects to `openrouter.ai:443` via Mint
  2. Sends POST to `/api/v1/chat/completions` with `stream: true`
  3. Parses SSE chunks and forwards to caller
  4. Accumulates full response
  5. Terminates after completion or error

  Messages sent to caller:
  - `{:sgiath_chat, pid, {:chunk, delta}}` - Each parsed SSE data chunk
  - `{:sgiath_chat, pid, {:done, full_response}}` - Final accumulated response
  - `{:sgiath_chat, pid, {:error, reason}}` - Any error
  """

  use GenServer

  require Logger

  alias SgiathChat.{HTTP, SSE}

  defstruct [
    :conn,
    :request_ref,
    :caller,
    :timeout_ref,
    buffer: "",
    chunks: [],
    status: nil,
    headers: [],
    done: false
  ]

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t() | nil,
          request_ref: reference() | nil,
          caller: pid(),
          timeout_ref: reference() | nil,
          buffer: binary(),
          chunks: [map()],
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          done: boolean()
        }

  # Client API

  @doc """
  Starts a new streaming request.

  ## Options
  - `:api_key` - OpenRouter API key (required, or from config)
  - `:caller` - PID to receive messages (defaults to caller)
  - `:timeout` - Request timeout in ms (default: 60_000)
  - `:temperature` - Model temperature parameter
  - `:max_tokens` - Maximum tokens to generate
  - `:top_p` - Top-p sampling parameter
  - `:frequency_penalty` - Frequency penalty parameter
  - `:presence_penalty` - Presence penalty parameter
  """
  @spec start_link(String.t(), [map()], keyword()) :: GenServer.on_start()
  def start_link(model, messages, opts \\ []) do
    GenServer.start_link(__MODULE__, {model, messages, opts})
  end

  @doc """
  Cancels an ongoing streaming request.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  # Server callbacks

  @impl true
  def init({model, messages, opts}) do
    caller = Keyword.get(opts, :caller, self())
    timeout = Keyword.get(opts, :timeout, HTTP.default_timeout())

    case HTTP.get_api_key(opts) do
      {:error, :missing_api_key} ->
        {:stop, {:error, :missing_api_key}}

      {:ok, api_key} ->
        state = %__MODULE__{caller: caller}
        {:ok, state, {:continue, {:connect, model, messages, api_key, timeout, opts}}}
    end
  end

  @impl true
  def handle_continue({:connect, model, messages, api_key, timeout, opts}, state) do
    case connect_and_request(model, messages, api_key, timeout, opts) do
      {:ok, conn, request_ref, timeout_ref} ->
        {:noreply, %{state | conn: conn, request_ref: request_ref, timeout_ref: timeout_ref}}

      {:error, reason} ->
        notify_error(state.caller, reason)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    notify_error(state.caller, :timeout)
    HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        Logger.warning("Received unknown message: #{inspect(message)}")
        {:noreply, state}

      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_responses(responses, state)

      {:error, conn, error, _responses} ->
        state = %{state | conn: conn}
        notify_error(state.caller, {:connection_error, error})
        HTTP.close(conn)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    cancel_timeout(state.timeout_ref)
    HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timeout(state.timeout_ref)
    HTTP.close(state.conn)
    :ok
  end

  # Private functions

  defp connect_and_request(model, messages, api_key, timeout, opts) do
    stream_opts = Keyword.put(opts, :stream, true)

    with {:ok, conn} <- HTTP.connect(),
         {:ok, conn, request_ref} <- HTTP.request(conn, model, messages, api_key, stream_opts) do
      timeout_ref = Process.send_after(self(), :timeout, timeout)
      {:ok, conn, request_ref, timeout_ref}
    end
  end

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {_, state} ->
      case handle_response(response, state) do
        {:continue, new_state} ->
          {:cont, {:noreply, new_state}}

        {:done, new_state} ->
          {:halt, {:stop, :normal, new_state}}

        {:error, reason, new_state} ->
          notify_error(new_state.caller, reason)
          {:halt, {:stop, :normal, new_state}}
      end
    end)
  end

  defp handle_response({:status, _ref, status}, state) do
    {:continue, %{state | status: status}}
  end

  defp handle_response({:headers, _ref, headers}, state) do
    state = %{state | headers: headers}

    # Check for non-2xx status after we have headers
    if state.status >= 200 and state.status < 300 do
      {:continue, state}
    else
      # Wait for body to get error details
      {:continue, state}
    end
  end

  defp handle_response({:data, _ref, data}, state) do
    buffer = state.buffer <> data

    # If we got a non-2xx status, accumulate body for error message
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

    # Check for HTTP error response
    if state.status < 200 or state.status >= 300 do
      error_body = parse_error_body(state.buffer)
      notify_error(state.caller, {:http_error, state.status, error_body})
      {:done, state}
    else
      # If we're done but haven't received SSE [DONE], treat remaining buffer
      if state.buffer != "" do
        Logger.warning("Request completed with unparsed buffer: #{inspect(state.buffer)}")
      end

      # If we never got [DONE] but connection closed, send what we have
      unless state.done do
        full_response = build_full_response(state.chunks)
        notify_done(state.caller, full_response)
      end

      {:done, state}
    end
  end

  defp handle_response({:error, _ref, reason}, state) do
    cancel_timeout(state.timeout_ref)
    {:error, {:stream_error, reason}, state}
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
    # Check for mid-stream error from OpenRouter
    if Map.has_key?(data, "error") do
      {:error, {:api_error, data["error"]}, state}
    else
      # Notify caller of chunk
      notify_chunk(state.caller, data)

      # Accumulate chunk
      state = %{state | chunks: [data | state.chunks]}
      {:continue, state}
    end
  end

  defp process_event(:done, state) do
    cancel_timeout(state.timeout_ref)
    full_response = build_full_response(state.chunks)
    notify_done(state.caller, full_response)
    {:done, %{state | done: true}}
  end

  defp process_event({:error, reason}, state) do
    {:error, {:parse_error, reason}, state}
  end

  defp build_full_response(chunks) do
    chunks = Enum.reverse(chunks)

    # Extract and concatenate all content deltas
    content =
      chunks
      |> Enum.map(fn chunk ->
        get_in(chunk, ["choices", Access.at(0), "delta", "content"]) || ""
      end)
      |> Enum.join("")

    # Get the last chunk for metadata (it usually has usage info)
    last_chunk = List.last(chunks) || %{}

    %{
      "content" => content,
      "model" => last_chunk["model"],
      "id" => last_chunk["id"],
      "usage" => last_chunk["usage"],
      "chunks" => chunks
    }
  end

  defp parse_error_body(buffer) do
    case JSON.decode(buffer) do
      {:ok, parsed} -> parsed
      {:error, _} -> buffer
    end
  end

  defp notify_chunk(caller, data) do
    send(caller, {:sgiath_chat, self(), {:chunk, data}})
  end

  defp notify_done(caller, response) do
    send(caller, {:sgiath_chat, self(), {:done, response}})
  end

  defp notify_error(caller, reason) do
    send(caller, {:sgiath_chat, self(), {:error, reason}})
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
    :ok
  end
end
