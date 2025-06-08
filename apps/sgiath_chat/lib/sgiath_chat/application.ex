defmodule Chat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Chat.Repo,
      {DNSCluster, query: Application.get_env(:sgiath_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Chat.PubSub}
      # Start a worker by calling: Chat.Worker.start_link(arg)
      # {Chat.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Chat.Supervisor)
  end
end
