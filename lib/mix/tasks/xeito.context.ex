defmodule Mix.Tasks.Xeito.Context do
  @shortdoc "Reports what typical tasks on this repository cost an agent to read"
  @moduledoc """
  Reports, per task, the tokens an agent reads to do it and how many of those are prose
  (`Xeito.Source.ReadCost`).

      mix xeito.context [SET]

  The set defaults to `bench/context/tasks.exs`: a map with `always` (files read for every task)
  and `tasks` (each a `name` and its `files`).
  """

  use Mix.Task

  alias Xeito.Source.ReadCost

  @default "bench/context/tasks.exs"

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: report(List.first(args, @default))
  end

  defp report(path) do
    {set, _binding} = Code.eval_file(path)
    Mix.shell().info(String.trim_trailing(ReadCost.format(ReadCost.measure(set))))
  end
end
