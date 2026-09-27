defmodule Xeito.Effects.Fake do
  @moduledoc "Test runner: `opts[:fun].(effect)` returns the result."

  @behaviour Xeito.Effects.Runner

  @impl true
  def run(effect, opts), do: Keyword.fetch!(opts, :fun).(effect)
end
