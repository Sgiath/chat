defmodule SgiathChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :sgiath_chat,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.7"},
      {:castore, "~> 1.0"}
    ]
  end
end
