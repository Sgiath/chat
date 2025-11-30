defmodule SgiathChat.Supervisor do
  @moduledoc """
  Supervisor for managed conversations.

  Add this supervisor to your application's supervision tree to enable
  supervised conversations that survive caller process death.

  ## Usage

      # In your Application module
      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            SgiathChat.Supervisor,
            # ... other children
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  Once started, you can use `SgiathChat.Conversation.start_supervised/1` to create
  conversations that are managed by this supervisor and registered by ID for lookup.

  ## Example

      # Start a supervised conversation
      {:ok, pid} = SgiathChat.Conversation.start_supervised(
        id: "conv-123",
        model: "openai/gpt-4",
        event_handler: MyApp.ConversationPersistence,
        caller: self()
      )

      # Later, lookup and reconnect from a new process
      pid = SgiathChat.Conversation.whereis("conv-123")
      :ok = SgiathChat.Conversation.set_caller(pid, self())
  """

  use Supervisor

  @doc """
  Starts the supervisor.

  ## Options

  - `:name` - Name for the supervisor (default: `SgiathChat.Supervisor`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the child specification for this supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SgiathChat.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: SgiathChat.ConversationSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

