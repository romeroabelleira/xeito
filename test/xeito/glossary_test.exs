defmodule Xeito.GlossaryTest do
  # GLOSSARY.md is the one document agents are told to read first: it must name modules that
  # exist, and every module directly under `Xeito` (the codebase's top level) must be in it.
  use ExUnit.Case, async: true

  @glossary File.read!("GLOSSARY.md")
  # Plumbing with no concept of its own.
  @unnamed [Xeito, Xeito.Application, Xeito.Case, Xeito.Executables, Xeito.Preload]

  defp named, do: ~r/`(Xeito(?:\.[A-Z]\w*)+)`/ |> Regex.scan(@glossary) |> Enum.map(fn [_, m] -> Module.concat([m]) end)

  test "every module the glossary names exists" do
    for module <- named(),
        do: assert(Code.ensure_loaded?(module), "#{inspect(module)} is in GLOSSARY.md but does not exist")
  end

  test "every top-level module is in the glossary" do
    top =
      for module <- Application.spec(:xeito, :modules),
          match?(["Xeito", _], Module.split(module)),
          module not in @unnamed,
          do: module

    missing = top -- named()
    assert missing == [], "add to GLOSSARY.md: #{Enum.map_join(missing, ", ", &inspect/1)}"
  end

  test "the glossary stays short" do
    assert String.length(@glossary) < 9_000
  end
end
