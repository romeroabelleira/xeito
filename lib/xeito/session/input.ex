defmodule Xeito.Session.Input do
  @moduledoc """
  A turn's input: what each machine is started with, and the system prompt built from the project's AGENTS.md.

  A chat turn gets the history, the system prompt with the repository map and the skills listed
  for this turn, its context window, and the step limit when the session has one. Skills are
  discovered every turn, so an edited SKILL.md applies at once.
  """

  alias Xeito.Machines.Chat
  alias Xeito.Machines.Check
  alias Xeito.Machines.Commit
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Machines.Shell
  alias Xeito.Session
  alias Xeito.Session.ChatModel
  alias Xeito.Session.Router
  alias Xeito.Skills
  alias Xeito.Skills.Examples.Worker
  alias Xeito.Source.RepoMap

  @agents_max_bytes 16_384

  @doc "The input to start `machine` with for `text` (the prompt, or the command for `Shell`)."
  @spec for_machine(module(), String.t(), Session.state()) :: map()
  def for_machine(Chat, text, s), do: chat_input(text, s)

  def for_machine(Commit, text, s), do: %{cwd: s.cwd, request: text}

  def for_machine(Check, _text, s), do: %{cwd: s.cwd, check_cmd: Router.check_command(s.cwd), system: s.system}

  def for_machine(FixFailingTest, _text, s), do: %{cwd: s.cwd, test_cmd: s.test_cmd, delegate: true, system: s.system}

  def for_machine(RunTests, _text, s), do: %{cwd: s.cwd, test_cmd: s.test_cmd}

  def for_machine(Shell, cmd, s), do: %{cwd: s.cwd, cmd: cmd}

  defp chat_input(text, s) do
    skills = Skills.discover(s.cwd)
    # Outside the daemon there is no worker and the cast goes nowhere.
    Worker.wanted(skills)
    %{listed: listed, candidates: candidates} = Skills.for_turn(skills, s.cwd, text)

    then(
      %{
        cwd: s.cwd,
        prompt: text,
        messages: s.history,
        verify: Router.quick_check_command(s.cwd),
        system: s.system <> repo_map(s.cwd) <> Skills.prompt_section(listed),
        context: ChatModel.context(ChatModel.current(s.chat), ChatModel.config(s.chat)),
        skills: Enum.map(skills, &Map.take(&1, [:name, :dir])),
        skill_candidates: Enum.map(candidates, &Map.take(&1, [:name, :description]))
      },
      &if(s.max_steps, do: Map.put(&1, :max_steps, s.max_steps), else: &1)
    )
  end

  defp repo_map(cwd) do
    case RepoMap.build(cwd) do
      nil -> ""
      map -> "\n\n" <> map <> "\n"
    end
  end

  @doc "The default system prompt, followed by the workspace's AGENTS.md (cut at 16 KiB) when there is one."
  @spec system_prompt(Path.t()) :: String.t()
  def system_prompt(cwd) do
    case File.read(Path.join(cwd, "AGENTS.md")) do
      {:ok, text} ->
        Chat.default_system() <> "\nProject context (AGENTS.md):\n\n" <> agents_text(text)

      {:error, _} ->
        Chat.default_system()
    end
  end

  defp agents_text(text) when byte_size(text) <= @agents_max_bytes, do: text

  defp agents_text(text),
    do:
      binary_part(text, 0, @agents_max_bytes) <>
        "\n\n[AGENTS.md continues: cut at #{@agents_max_bytes} bytes here. Read the file for the rest.]"
end
