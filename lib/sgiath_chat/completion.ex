defmodule SgiathChat.Completion do
  @moduledoc """
  Non-streaming chat completion requests to OpenRouter API.

  This module handles simple request/response interactions without streaming.
  """

  alias SgiathChat.HTTP

  @doc """
  Sends a non-streaming chat completion request and waits for the response.

  Returns `{:ok, response}` with the parsed JSON response, or `{:error, reason}`.
  """
  @spec call(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def call(model, messages, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, HTTP.default_timeout())

    with {:ok, api_key} <- HTTP.get_api_key(opts),
         {:ok, conn} <- HTTP.connect(),
         {:ok, conn, request_ref} <- HTTP.request(conn, model, messages, api_key, opts),
         {:ok, response} <- receive_response(conn, request_ref, timeout) do
      {:ok, response}
    end
  end

  defp receive_response(conn, request_ref, timeout) do
    receive_response(conn, request_ref, timeout, %{status: nil, headers: [], body: ""})
  end

  defp receive_response(conn, request_ref, timeout, acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            receive_response(conn, request_ref, timeout, acc)

          {:ok, conn, responses} ->
            case process_responses(responses, request_ref, acc) do
              {:continue, new_acc} ->
                receive_response(conn, request_ref, timeout, new_acc)

              {:done, response} ->
                HTTP.close(conn)
                response

              {:error, _reason} = error ->
                HTTP.close(conn)
                error
            end

          {:error, conn, error, _responses} ->
            HTTP.close(conn)
            {:error, {:connection_error, error}}
        end
    after
      timeout ->
        HTTP.close(conn)
        {:error, :timeout}
    end
  end

  defp process_responses(responses, request_ref, acc) do
    Enum.reduce_while(responses, {:continue, acc}, fn response, {:continue, acc} ->
      case response do
        {:status, ^request_ref, status} ->
          {:cont, {:continue, %{acc | status: status}}}

        {:headers, ^request_ref, headers} ->
          {:cont, {:continue, %{acc | headers: headers}}}

        {:data, ^request_ref, data} ->
          {:cont, {:continue, %{acc | body: acc.body <> data}}}

        {:done, ^request_ref} ->
          result = finalize_response(acc)
          {:halt, {:done, result}}

        {:error, ^request_ref, reason} ->
          {:halt, {:error, {:stream_error, reason}}}

        _other ->
          {:cont, {:continue, acc}}
      end
    end)
  end

  defp finalize_response(%{status: status, body: body}) when status >= 200 and status < 300 do
    case JSON.decode(body) do
      {:ok, parsed} -> {:ok, format_response(parsed)}
      {:error, reason} -> {:error, {:json_error, reason, body}}
    end
  end

  defp finalize_response(%{status: status, body: body}) do
    error_body =
      case JSON.decode(body) do
        {:ok, parsed} -> parsed
        {:error, _} -> body
      end

    {:error, {:http_error, status, error_body}}
  end

  defp format_response(response) do
    # Extract the content from the response for convenience
    content =
      get_in(response, ["choices", Access.at(0), "message", "content"]) || ""

    Map.put(response, "content", content)
  end
end
