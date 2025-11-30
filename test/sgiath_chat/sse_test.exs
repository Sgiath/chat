defmodule SgiathChat.SSETest do
  use ExUnit.Case, async: true

  alias SgiathChat.SSE

  doctest SgiathChat.SSE

  describe "parse_lines/1" do
    test "parses a single JSON data event" do
      input = "data: {\"id\":\"123\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1

      assert {:data, %{"id" => "123", "choices" => [%{"delta" => %{"content" => "Hello"}}]}} =
               hd(events)
    end

    test "parses multiple events" do
      input = """
      data: {"id":"1","content":"Hello"}

      data: {"id":"2","content":"World"}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 2
      assert {:data, %{"id" => "1"}} = Enum.at(events, 0)
      assert {:data, %{"id" => "2"}} = Enum.at(events, 1)
    end

    test "parses [DONE] termination signal" do
      input = "data: [DONE]\n\n"

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert events == [:done]
    end

    test "handles mixed data and [DONE]" do
      input = """
      data: {"id":"1"}

      data: [DONE]

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 2
      assert {:data, %{"id" => "1"}} = Enum.at(events, 0)
      assert :done = Enum.at(events, 1)
    end

    test "ignores comment lines" do
      input = ": OPENROUTER PROCESSING\n\n"

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert events == []
    end

    test "ignores comments mixed with data" do
      input = """
      : OPENROUTER PROCESSING

      data: {"id":"1"}

      : keep-alive

      data: {"id":"2"}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 2
    end

    test "returns incomplete data in remaining buffer" do
      input = "data: {\"partial"

      {events, remaining} = SSE.parse_lines(input)

      assert events == []
      assert remaining == "data: {\"partial"
    end

    test "handles partial event without double newline" do
      input = "data: {\"id\":\"1\"}\n"

      {events, remaining} = SSE.parse_lines(input)

      assert events == []
      assert remaining == "data: {\"id\":\"1\"}\n"
    end

    test "parses complete events and keeps partial" do
      input = """
      data: {"id":"1"}

      data: {"partial
      """

      {events, remaining} = SSE.parse_lines(input)

      assert length(events) == 1
      assert {:data, %{"id" => "1"}} = hd(events)
      assert remaining =~ "partial"
    end

    test "returns error for invalid JSON" do
      input = "data: {invalid json}\n\n"

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1
      assert {:error, {:json_parse_error, _, "{invalid json}"}} = hd(events)
    end

    test "handles empty buffer" do
      {events, remaining} = SSE.parse_lines("")

      assert events == []
      assert remaining == ""
    end

    test "handles only newlines" do
      {events, remaining} = SSE.parse_lines("\n\n\n\n")

      assert events == []
      # Two complete empty events (\n\n each), nothing remaining
      assert remaining == ""
    end

    test "ignores event: lines" do
      input = """
      event: message
      data: {"id":"1"}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1
      assert {:data, %{"id" => "1"}} = hd(events)
    end

    test "ignores id: lines" do
      input = """
      id: 12345
      data: {"id":"1"}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1
    end

    test "ignores retry: lines" do
      input = """
      retry: 3000
      data: {"id":"1"}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1
    end

    test "handles realistic OpenRouter chunk" do
      input = """
      data: {"id":"gen-123","object":"chat.completion.chunk","created":1699000000,"model":"openai/gpt-4","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

      """

      {events, remaining} = SSE.parse_lines(input)

      assert remaining == ""
      assert length(events) == 1
      {:data, data} = hd(events)
      assert data["id"] == "gen-123"
      assert data["model"] == "openai/gpt-4"
      assert get_in(data, ["choices", Access.at(0), "delta", "content"]) == "Hello"
    end

    test "handles streaming scenario with multiple calls" do
      # Simulate receiving data in chunks
      {events1, buffer1} = SSE.parse_lines("data: {\"id\":\"1")
      assert events1 == []

      {events2, buffer2} = SSE.parse_lines(buffer1 <> "\"}\n")
      assert events2 == []

      {events3, buffer3} = SSE.parse_lines(buffer2 <> "\ndata: [DONE]\n\n")
      assert length(events3) == 2
      assert buffer3 == ""
    end
  end
end
