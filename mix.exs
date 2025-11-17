defmodule Diffdigest.MixProject do
  use Mix.Project

  def project do
    [
      app: :diffdigest,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:earmark, "~> 1.4"},
      {:dotenvy, "~> 0.8"}
    ]
  end
end
