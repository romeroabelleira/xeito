defmodule Xeito.ArchitectureTest do
  @moduledoc """
  The dependency rules the architecture docs state, checked on the compiled code: the remote
  calls each module of `lib/` makes, read from its BEAM file. Dynamic calls (`apply/3`, a
  module held in a variable) and struct literals are not calls, so they are not seen.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  # The client side: separate OS processes that talk to the daemon over its socket (ADR 007).
  @client [Xeito.Tui, Xeito.Client]

  # The calls the client makes into daemon-side modules. None needs a daemon process: they are
  # names for completion and reading the workspace's skill files. Each must still be made.
  @client_may_call [
    # Command names and machine names, for completion and the banner.
    {Xeito.Session, :commands, 0},
    {Xeito.Session.Router, :machines, 0},
    # `/skills` and the banner read the skill files themselves.
    {Xeito.Skills, :discover, 1},
    {Xeito.Skills, :discover, 2},
    {Xeito.Skills, :for_turn, 3},
    {Xeito.Skills.Index, :search, 3}
  ]

  # The edges: the clients, the socket API, sessions, the application and the mix tasks. They
  # depend on the core; the core never depends on them.
  @edges [Xeito.Tui, Xeito.Client, Xeito.Api, Xeito.Session, Xeito.Application, Mix.Tasks]

  # Machines and their engine. Entry functions return effects and the runner performs them;
  # guards and actions are pure (ADR 005), which is what makes runs replayable from the log.
  @machines [Xeito.Machine, Xeito.Machines]

  # What a machine never calls: IO, processes, configuration, randomness, and the runner side.
  @effectful [
    File,
    IO,
    System,
    Port,
    Process,
    GenServer,
    Task,
    Agent,
    Application,
    Node,
    :os,
    :file,
    :rand,
    :ets,
    :persistent_term,
    Req,
    Exqlite,
    Xeito.Effects,
    Xeito.Events,
    Xeito.Log,
    Xeito.Run,
    Xeito.RunSupervisor,
    Xeito.Backends
  ]

  test "the client reaches the daemon only through its socket" do
    calls =
      for module <- modules_in(@client),
          {target, _, _} = call <- calls(module),
          xeito?(target) and not within?(target, @client),
          uniq: true,
          do: call

    assert Enum.sort(calls -- @client_may_call) == []
    assert Enum.sort(@client_may_call -- calls) == [], "no longer called: remove from @client_may_call"
  end

  test "the core never calls the edges" do
    violations =
      for module <- lib_modules(),
          not within?(module, @edges),
          {target, fun, arity} <- calls(module),
          within?(target, @edges),
          uniq: true,
          do: "#{inspect(module)} calls #{inspect(target)}.#{fun}/#{arity}"

    assert violations == []
  end

  test "machines and the machine engine perform no effects themselves" do
    violations =
      for module <- modules_in(@machines),
          {target, fun, arity} <- calls(module),
          within?(target, @effectful),
          uniq: true,
          do: "#{inspect(module)} calls #{inspect(target)}.#{fun}/#{arity}"

    assert violations == []
  end

  # A rule over no modules passes whatever the code does, so a rename must not empty one.
  test "every rule covers modules that exist" do
    for namespace <- @client ++ @machines,
        do: assert(modules_in([namespace]) != [], "no modules under #{inspect(namespace)}")

    for namespace <- @edges, do: assert(modules_in([namespace]) != [], "no modules under #{inspect(namespace)}")
  end

  defp lib_modules do
    {:ok, modules} = :application.get_key(:xeito, :modules)
    Enum.filter(modules, &(&1.module_info(:compile)[:source] |> to_string() |> String.starts_with?(@lib)))
  end

  defp modules_in(namespaces), do: Enum.filter(lib_modules(), &within?(&1, namespaces))

  # From the BEAM file, not the loaded code: coverage and mutation testing replace the latter.
  defp calls(module) do
    beam = :xeito |> Application.app_dir("ebin") |> Path.join("#{module}.beam") |> String.to_charlist()
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end

  defp xeito?(module), do: within?(module, [Xeito])

  defp within?(module, namespaces),
    do: Enum.any?(namespaces, &(module == &1 or String.starts_with?(inspect(module), inspect(&1) <> ".")))
end
