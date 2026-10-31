defmodule Ally.MixProject do
  use Mix.Project

  def project do
    [
      app: :ally,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh, :crypto, :public_key],
      mod: {Ally.Application, []}
    ]
  end

  defp deps do
    [
      # TUI framework — SSH, terminal, LiveView surfaces
      {:raxol, github: "DROOdotFOO/raxol", branch: "master"},

      # HTTP client for Otari gateway
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile"]
    ]
  end

  defp releases do
    [
      ally: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
