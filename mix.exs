defmodule Chat.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      releases: [
        default: [
          applications: [
            sgiath_chat: :permanent,
            sgiath_chat_web: :permanent
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.0-rc.3", override: true},
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      {:ex_check, "~> 0.16", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["cmd mix setup"]
    ]
  end
end
