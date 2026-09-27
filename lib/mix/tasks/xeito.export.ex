defmodule Mix.Tasks.Xeito.Export do
  @shortdoc "Exports a machine as Mermaid or SCXML"
  @moduledoc """
  Prints a machine definition as a Mermaid state diagram (default) or as SCXML.

      mix xeito.export Xeito.Machines.FixFailingTest
      mix xeito.export Xeito.Machines.FixFailingTest --format scxml
  """

  use Mix.Task

  alias Xeito.Machine
  alias Xeito.Machine.Export

  @impl true
  def run(args) do
    {opts, [module_name], _} = OptionParser.parse(args, strict: [format: :string])
    Mix.Task.run("compile")

    machine = Machine.fetch!(Module.concat([module_name]))

    case Keyword.get(opts, :format, "mermaid") do
      "mermaid" -> Mix.shell().info(Export.mermaid(machine))
      "scxml" -> Mix.shell().info(Export.scxml(machine))
      other -> Mix.raise("unknown format #{inspect(other)}, expected mermaid or scxml")
    end
  end
end
