defmodule Mix.Tasks.XeitoTest do
  # Uses Mix's shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  # Everything the task printed, in order.
  defp printed(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> printed([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  @tasks ~w(xeito.candidates xeito.chat xeito.daemon xeito.eval xeito.export xeito.log xeito.skills.bench
            xeito.skills.examples xeito.tui)

  test "mix xeito, with --help, -h or help, says what Xeito is and lists every xeito task" do
    for args <- [[], ["--help"], ["-h"], ["help"]] do
      Xeito.run(args)
      text = printed()

      assert text =~ "Xeito"
      for task <- @tasks, do: assert(text =~ "mix #{task}", "#{inspect(args)} lists #{task}")
      assert text =~ Mix.Task.shortdoc(Mix.Tasks.Xeito.Tui)
      assert text =~ "mix xeito.tui --help"
      assert text =~ "INSTALL.md"
    end
  end

  test "the tasks listed are found, not written down: a new one shows up by itself" do
    # xeito.mutate, the contributors' mutation testing, is compiled for tests only.
    assert Enum.map(Xeito.tasks(), &Mix.Task.task_name/1) == Enum.sort(["xeito.mutate" | @tasks])
  end

  test "every xeito task shows its documentation for --help or -h, and runs nothing" do
    for module <- Xeito.tasks(), flag <- ["--help", "-h"] do
      name = Mix.Task.task_name(module)
      module.run([flag])
      text = printed()

      assert text =~ "mix #{name}\n", "#{name} #{flag}"
      assert text =~ String.slice(Mix.Task.moduledoc(module), 0, 40), "#{name} #{flag}"
    end
  end
end
