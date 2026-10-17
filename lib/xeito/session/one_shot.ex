defmodule Xeito.Session.OneShot do
  @moduledoc """
  A one-shot turn's machine and input: a skill or a machine named by the caller, its tools chosen, no routing.

  `input/3` takes the turn's text and options and returns `{:ok, machine, input, reason}`, or
  `{:error, message}` for an unknown skill, machine or tool, or a skill and a machine together.

  - `skill: name`: a chat turn running the skill (as `/skill:name`), with the text as its request.
  - `machine: name`: that registered machine (`Xeito.Session.Router.machines/0`) with the input it needs.
  - neither: a chat turn of the text.
  - `tools:` `false` (the default), `true` (all) or a list of names: the chat turn's tools. Without
    `skill` among them, the turn does not pick a skill. A machine other than chat runs its own effects.
  """

  alias Xeito.Machines.Chat
  alias Xeito.Session
  alias Xeito.Session.Input
  alias Xeito.Session.Router
  alias Xeito.Skills
  alias Xeito.Tools

  @tools Tools.names() ++ ["skill"]

  @doc "The machine, its input and the run's reason for a one-shot turn of `text`."
  @spec input(String.t(), keyword(), Session.state()) :: {:ok, module(), map(), String.t()} | {:error, String.t()}
  def input(text, opts, s) do
    with :ok <- check_tools(Keyword.get(opts, :tools, false)) do
      start(opts[:skill], opts[:machine], text, Keyword.get(opts, :tools, false), s)
    end
  end

  @doc "`:ok` when `tools` is `true`, `false` or a list of known tool names, else why not."
  @spec check_tools(boolean() | [String.t()]) :: :ok | {:error, String.t()}
  def check_tools(tools) when is_boolean(tools), do: :ok

  def check_tools(tools) when is_list(tools) do
    case Enum.find(tools, &(&1 not in @tools)) do
      nil -> :ok
      name -> {:error, "unknown tool #{inspect(name)}; the tools are #{Enum.join(@tools, ", ")}"}
    end
  end

  defp start(nil, nil, text, tools, s), do: {:ok, Chat, chat(text, tools, s), "one-shot"}
  defp start(skill, nil, text, tools, s), do: skill(skill, text, tools, s)
  defp start(nil, machine, text, tools, s), do: machine(machine, text, tools, s)
  defp start(_skill, _machine, _text, _tools, _s), do: {:error, "a skill or a machine, not both"}

  defp skill(name, text, tools, s) do
    case Enum.find(Skills.discover(s.cwd), &(&1.name == name)) do
      nil ->
        {:error, "no skill named #{inspect(name)}"}

      skill ->
        input = Map.put(chat(Skills.invocation(skill, text), tools, s), :skill_candidates, [])
        {:ok, Chat, input, "one-shot skill:#{name}"}
    end
  end

  defp machine(name, text, tools, s) do
    case Router.machines() do
      %{^name => Chat} -> {:ok, Chat, chat(text, tools, s), "one-shot machine:#{name}"}
      %{^name => machine} -> {:ok, machine, Input.for_machine(machine, text, s), "one-shot machine:#{name}"}
      machines -> {:error, "unknown machine #{inspect(name)}; available: #{Enum.join(Map.keys(machines), ", ")}"}
    end
  end

  defp chat(text, true, s), do: Input.for_machine(Chat, text, s)

  defp chat(text, tools, s) do
    input = Map.put(Input.for_machine(Chat, text, s), :tools, tools)
    if is_list(tools) and "skill" in tools, do: input, else: %{input | skill_candidates: []}
  end
end
