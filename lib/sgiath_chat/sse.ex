defmodule SgiathChat.SSE do
  @moduledoc """
  Server-Sent Events (SSE) parser for OpenRouter streaming responses.

  Handles parsing of SSE format including:
  - `data: {...}` JSON lines
  - `data: [DONE]` termination signal
  - `: OPENROUTER PROCESSING` comments (ignored)
  - Multi-line buffering for incomplete chunks
  """

  @type event :: {:data, map()} | :done | {:error, term()}

  @doc """
  Parses SSE lines from a buffer, returning parsed events and remaining buffer.

  Returns `{events, remaining_buffer}` where events is a list of parsed events.

  ## Examples

      iex> SgiathChat.SSE.parse_lines("data: {\\"id\\":\\"123\\"}\\n\\n")
      {[{:data, %{"id" => "123"}}], ""}

      iex> SgiathChat.SSE.parse_lines("data: [DONE]\\n\\n")
      {[:done], ""}

      iex> SgiathChat.SSE.parse_lines(": OPENROUTER PROCESSING\\n\\n")
      {[], ""}

      iex> SgiathChat.SSE.parse_lines("data: {\\"partial")
      {[], "data: {\\"partial"}
  """
  @spec parse_lines(binary()) :: {[event()], binary()}
  def parse_lines(buffer) do
    parse_lines(buffer, [])
  end

  defp parse_lines(buffer, events) do
    case extract_event(buffer) do
      {:ok, event, rest} ->
        parse_lines(rest, [event | events])

      {:skip, rest} ->
        # Event block was empty or comment-only, continue processing
        parse_lines(rest, events)

      :incomplete ->
        {Enum.reverse(events), buffer}
    end
  end

  # Extract a single SSE event from the buffer
  # SSE events are terminated by double newline (\n\n)
  defp extract_event(buffer) do
    case :binary.split(buffer, "\n\n") do
      [_incomplete] ->
        :incomplete

      [event_block, rest] ->
        case parse_event_block(event_block) do
          nil -> {:skip, rest}
          event -> {:ok, event, rest}
        end
    end
  end

  # Parse a single event block (lines between double newlines)
  defp parse_event_block(block) do
    block
    |> String.split("\n")
    |> Enum.reduce(nil, &parse_line/2)
  end

  # Parse individual SSE lines
  defp parse_line(":" <> _comment, acc) do
    # SSE comment line - ignore (e.g., ": OPENROUTER PROCESSING")
    acc
  end

  defp parse_line("data: [DONE]", _acc) do
    :done
  end

  defp parse_line("data: " <> json_data, _acc) do
    case JSON.decode(json_data) do
      {:ok, parsed} ->
        {:data, parsed}

      {:error, reason} ->
        {:error, {:json_parse_error, reason, json_data}}
    end
  end

  defp parse_line("event: " <> _event_type, acc) do
    # Event type line - we don't need to handle these specially
    acc
  end

  defp parse_line("id: " <> _id, acc) do
    # Event ID line - we don't need to handle these specially
    acc
  end

  defp parse_line("retry: " <> _retry, acc) do
    # Retry directive - we don't handle reconnection
    acc
  end

  defp parse_line("", acc) do
    # Empty line within event block
    acc
  end

  defp parse_line(_other, acc) do
    # Unknown line format - ignore
    acc
  end
end

