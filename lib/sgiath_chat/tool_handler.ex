defmodule SgiathChat.ToolHandler do
  @moduledoc """
  Behaviour for implementing tool handlers in conversations.

  A tool handler module defines both the available tools (their schemas) and
  how to execute them. The Conversation GenServer will automatically discover
  tools by calling `tools/0` and execute them via `handle_tool_call/3`.

  ## Tool Handler Configuration

  Tool handlers can be configured with or without context:

      # Without context (context defaults to %{})
      tool_handler: [WeatherTools, CalendarTools]

      # With context
      tool_handler: [{WeatherTools, %{api_key: "..."}}]

      # Mixed
      tool_handler: [CalendarTools, {WeatherTools, %{api_key: "..."}}]

  ## Example Implementation

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
                    "location" => %{
                      "type" => "string",
                      "description" => "City name, e.g. 'London' or 'New York'"
                    }
                  },
                  "required" => ["location"]
                }
              }
            },
            %{
              "type" => "function",
              "function" => %{
                "name" => "calculate",
                "description" => "Perform a mathematical calculation",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{
                    "expression" => %{
                      "type" => "string",
                      "description" => "Mathematical expression to evaluate"
                    }
                  },
                  "required" => ["expression"]
                }
              }
            }
          ]
        end

        @impl true
        def handle_tool_call("get_weather", %{"location" => location}, context) do
          # Context contains any data passed when configuring the handler
          api_key = Map.get(context, :api_key, "default_key")
          # In real implementation, call a weather API
          {:ok, "Weather in \#{location}: 22°C, sunny"}
        end

        def handle_tool_call("calculate", %{"expression" => expr}, _context) do
          # In real implementation, safely evaluate the expression
          {:ok, "Result: 42"}
        end

        def handle_tool_call(name, _args, _context) do
          {:error, "Unknown tool: \#{name}"}
        end
      end
  """

  @doc """
  Returns the list of tool definitions in OpenRouter/OpenAI format.

  Each tool should be a map with "type" => "function" and a "function" key
  containing name, description, and parameters schema.
  """
  @callback tools() :: [map()]

  @doc """
  Executes a tool call and returns the result.

  The result should be a string that will be included in the conversation
  as the tool's response to the LLM.

  ## Parameters

  - `name` - The name of the tool being called
  - `arguments` - Map of arguments passed to the tool
  - `context` - Context data passed when configuring the handler (defaults to `%{}`)

  ## Returns

  - `{:ok, result}` - Tool executed successfully, result is a string
  - `{:error, reason}` - Tool execution failed
  """
  @callback handle_tool_call(name :: String.t(), arguments :: map(), context :: term()) ::
              {:ok, result :: String.t()} | {:error, reason :: term()}

  @optional_callbacks [handle_tool_call: 3]
end
