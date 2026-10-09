defmodule Mix.Tasks.Xeito do
  @shortdoc "Lists Xeito's tasks, and where to read more"
  @moduledoc """
  What Xeito is, and its mix tasks with a line on each:

      mix xeito             (also: --help, -h, help)

  Every `xeito.*` task shows its own documentation for `--help` or `-h`, as `mix help <task>`
  does, and runs nothing. Installing is in `INSTALL.md`, using it in `USAGE.md`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    width = tasks() |> Enum.map(&String.length(Mix.Task.task_name(&1))) |> Enum.max()

    lines =
      for module <- tasks(),
          do: "  mix #{String.pad_trailing(Mix.Task.task_name(module), width)}  #{Mix.Task.shortdoc(module)}"

    Mix.shell().info("""
    Xeito: an agent harness that runs language models inside logged state machines.

    #{Enum.join(lines, "\n")}

    Each task explains itself: mix xeito.tui --help (or mix help xeito.tui).
    Installing: INSTALL.md. Using it: USAGE.md.\
    """)
  end

  @doc "The `xeito.*` tasks, by name; this overview itself is not one of them."
  @spec tasks() :: [module()]
  def tasks do
    Mix.Task.load_all()

    Mix.Task.all_modules()
    |> Enum.filter(&String.starts_with?(Mix.Task.task_name(&1), "xeito."))
    |> Enum.sort_by(&Mix.Task.task_name/1)
  end

  @doc "Whether `args` ask for a task's documentation (`--help` or `-h`) rather than to run it."
  @spec help?([String.t()]) :: boolean()
  def help?(args), do: Enum.any?(args, &(&1 in ["--help", "-h"]))

  @doc "Shows `module`'s documentation, as `mix help` does, with the task's name as its heading."
  @spec help(module()) :: :ok
  def help(module), do: Mix.shell().info("mix #{Mix.Task.task_name(module)}\n\n#{Mix.Task.moduledoc(module)}")
end
