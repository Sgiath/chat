defmodule SgiathChat.ToolHandler do
  @moduledoc """
  Behaviour for implementing tool handlers in conversations.

  A tool handler module defines both the available tools (their schemas) and
  how to execute them. The Conversation GenServer will automatically discover
  tools by calling `tools/0` and execute them via `handle_tool_call/2`.

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
        def handle_tool_call("get_weather", %{"location" => location}) do
          # In real implementation, call a weather API
          {:ok, "Weather in \#{location}: 22°C, sunny"}
        end

        def handle_tool_call("calculate", %{"expression" => expr}) do
          # In real implementation, safely evaluate the expression
          {:ok, "Result: 42"}
        end

        def handle_tool_call(name, _args) do
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

  ## Returns

  - `{:ok, result}` - Tool executed successfully, result is a string
  - `{:error, reason}` - Tool execution failed
  """
  @callback handle_tool_call(name :: String.t(), arguments :: map()) ::
              {:ok, result :: String.t()} | {:error, reason :: term()}
end

