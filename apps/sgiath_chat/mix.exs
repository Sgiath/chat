defmodule Chat.MixProject do
  use Mix.Project

  def project do
    [
      app: :sgiath_chat,
      version: "0.1.0",
      aliases: aliases(),
      deps: deps(),

      # Elixir
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,

      # umbrella paths
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock"
    ]
  end

  def application do
    [
      mod: {Chat.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:argon2_elixir, "~> 4.1"},
      {:dns_cluster, "~> 0.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:swoosh, "~> 1.19"},
      {:req, "~> 0.5"},
      {:openai_ex, "~> 0.9"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run #{__DIR__}/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
