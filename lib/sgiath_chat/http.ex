defmodule SgiathChat.HTTP do
  @moduledoc """
  Shared HTTP connection and request building logic for OpenRouter API.

  This module provides common functionality used by both streaming and
  non-streaming request modules.
  """

  @openrouter_host "openrouter.ai"
  @openrouter_port 443
  @api_path "/api/v1/chat/completions"
  @default_timeout 60_000

  @doc """
  Returns the default request timeout in milliseconds.
  """
  @spec default_timeout() :: non_neg_integer()
  def default_timeout, do: @default_timeout

  @doc """
  Resolves the API key from options or application config.

  Returns `{:ok, api_key}` or `{:error, :missing_api_key}`.
  """
  @spec get_api_key(keyword()) :: {:ok, String.t()} | {:error, :missing_api_key}
  def get_api_key(opts) do
    api_key =
      Keyword.get_lazy(opts, :api_key, fn ->
        Application.get_env(:sgiath_chat, :api_key)
      end)

    case api_key do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  @doc """
  Establishes an HTTPS connection to OpenRouter.

  Returns `{:ok, conn}` or `{:error, {:connect_error, reason}}`.
  """
  @spec connect() :: {:ok, Mint.HTTP.t()} | {:error, {:connect_error, term()}}
  def connect do
    transport_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    case Mint.HTTP.connect(:https, @openrouter_host, @openrouter_port,
           transport_opts: transport_opts
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:connect_error, reason}}
    end
  end

  @doc """
  Sends a chat completion request to OpenRouter.

  ## Options
  - `:stream` - Whether to enable streaming (default: false)
  - `:temperature` - Model temperature parameter
  - `:max_tokens` - Maximum tokens to generate
  - `:top_p` - Top-p sampling parameter
  - `:frequency_penalty` - Frequency penalty parameter
  - `:presence_penalty` - Presence penalty parameter

  Returns `{:ok, conn, request_ref}` or `{:error, {:request_error, reason}}`.
  """
  @spec request(Mint.HTTP.t(), String.t(), [map()], String.t(), keyword()) ::
          {:ok, Mint.HTTP.t(), reference()} | {:error, {:request_error, term()}}
  def request(conn, model, messages, api_key, opts \\ []) do
    stream? = Keyword.get(opts, :stream, false)
    headers = build_headers(api_key, stream?)
    body = build_body(model, messages, opts, stream?)

    case Mint.HTTP.request(conn, "POST", @api_path, headers, body) do
      {:ok, conn, request_ref} -> {:ok, conn, request_ref}
      {:error, _conn, reason} -> {:error, {:request_error, reason}}
    end
  end

  @doc """
  Closes a Mint connection.
  """
  @spec close(Mint.HTTP.t() | nil) :: :ok
  def close(nil), do: :ok

  def close(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  # Private functions

  defp build_headers(api_key, stream?) do
    accept = if stream?, do: "text/event-stream", else: "application/json"

    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", accept}
    ]
  end

  defp build_body(model, messages, opts, stream?) do
    base = %{
      "model" => model,
      "messages" => messages,
      "stream" => stream?
    }

    params =
      opts
      |> Keyword.take([:temperature, :max_tokens, :top_p, :frequency_penalty, :presence_penalty])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Add tools if provided
    tools = Keyword.get(opts, :tools)

    base
    |> Map.merge(params)
    |> maybe_add_tools(tools)
    |> JSON.encode!()
  end

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, "tools", tools)
end

