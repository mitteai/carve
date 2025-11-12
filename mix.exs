defmodule Carve.MixProject do
  use Mix.Project

  def project do
    [
      app: :carve,
      version: "0.3.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Carve",
      source_url: "https://github.com/azer/carve",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => @source_url
        }
      ],
      docs: [
        # The main page in the docs
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      mod: {Carve, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.6", optional: true},
      {:jason, "~> 1.2"},
      {:hashids, "~> 2.1"},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:ecto, "~> 3.7", only: :test, runtime: false},
      {:cachex, "~> 3.6"},
    ]
  end

  defp description do
    """
    DSL for building JSON APIs fast. Creates endpoint views, renders linked data automatically.
    """
  end

  defp package do
    [
      maintainers: ["Azer Koculu"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/azer/carve"}
    ]
  end


  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test"]
  defp elixirc_paths(_), do: ["lib"]
end
