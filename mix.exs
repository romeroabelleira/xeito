defmodule Xeito.MixProject do
  use Mix.Project

  def project do
    [
      app: :xeito,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      # `mix test --cover` scores every function's CRAP (complexity and coverage) and fails above
      # the maximum (test/support/xeito/crap.ex).
      test_coverage: [tool: Xeito.Crap, crap_max: 30],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        # :tools for :cover (the CRAP gate in test/support, analysed when MIX_ENV=test as in CI).
        plt_add_apps: [:ex_unit, :mix, :term_ui, :tools]
      ]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Xeito.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:exqlite, "~> 0.41"},
      {:req, "~> 0.7"},
      # The TUI client only; not started with the daemon (mix xeito.tui starts it).
      {:term_ui, "~> 1.0", runtime: false},
      {:plug, "~> 1.20", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      # Style: Styler rewrites on `mix format`; pinned to a minor version so new rewrites are a
      # deliberate upgrade. Credo keeps the checks Styler cannot fix (.credo.exs).
      {:styler, "~> 1.12.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        # With coverage: the CRAP gate (test/support/xeito/crap.ex).
        "test --cover"
      ]
    ]
  end
end
