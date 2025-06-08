defmodule ChatWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :sgiath_chat_web,
      version: "0.1.0",
      aliases: aliases(),
      deps: deps(),

      # Elixir
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],

      # umbrella paths
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock"
    ]
  end

  def application do
    [
      mod: {ChatWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sgiath_chat, in_umbrella: true},
      {:phoenix, "~> 1.8.0-rc.3", override: true},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.37.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.2"},
      {:gettext, "~> 0.26"},
      {:bandit, "~> 1.7"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind sgiath_chat_web", "esbuild sgiath_chat_web"],
      "assets.deploy": [
        "tailwind sgiath_chat_web --minify",
        "esbuild sgiath_chat_web --minify",
        "phx.digest"
      ]
    ]
  end
end
