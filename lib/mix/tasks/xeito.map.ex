defmodule Mix.Tasks.Xeito.Map do
  @shortdoc "Prints Xeito's modules, or their public functions with specs"
  @moduledoc """
  Prints the codebase's interface (`Xeito.Source.ModuleMap`): a line per module with its file
  and summary. With a module prefix, or `--functions`, each module's public functions follow
  with their specs.

      mix xeito.map                     every module, one line each
      mix xeito.map Xeito.Chat          Xeito.Chat and the modules under it, with functions
      mix xeito.map --functions         everything, with functions
  """

  use Mix.Task

  alias Xeito.Source.ModuleMap

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: print(args)
  end

  defp print(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [functions: :boolean])
    Mix.Task.run("compile")
    prefix = List.first(rest)
    entries = prefix |> ModuleMap.modules() |> Enum.map(&ModuleMap.entry/1)
    Mix.shell().info(ModuleMap.format(entries, functions: opts[:functions] || prefix != nil))
  end
end
