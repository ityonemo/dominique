defmodule Dominique.MixProject do
  use Mix.Project

  def project do
    [
      app: :dominique,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/_support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:match_spec, "~> 1.0"},
      {:muontrap, "~> 1.0", only: :test},
      {:protoss, "~> 1.1"}
    ]
  end

  defp aliases do
    [
      credo: "credo --strict"
    ]
  end
end
