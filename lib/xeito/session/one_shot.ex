defmodule Xeito.Session.OneShot do
  @moduledoc """
  A one-shot turn: a skill or a machine named by the caller, its tools, answer format and chat options chosen, no routing.

  `prepare/3` takes the turn's text and options and returns `{:ok, %{machine, input, reason,
  chat}}`, `chat` being the session's chat options with the turn's over them, or `{:error,
  message}` for an unknown skill, machine, tool, tier or decision type, or options that exclude
  each other. `request/3` is the first model request the turn would send, for a dry run.

  - `skill: name`: a chat turn running the skill (as `/skill:name`), with the text as its request.
    The skill's own choices fill in what the call leaves open: its `tier` (unless the policy
    keeps local-only input on the machine and the tier is off-box: then a notice says so), its
    `output` as the answer format when the turn has no tools, and its `contexts`. `vars:` fills
    its `{{name}}` variables (`Xeito.Skills.fill/2`); `reason:` names the run (default
    `one-shot skill:NAME`).
  - `contexts: [name]`: named contexts (`Xeito.Skills.context/3`) added after the text.
  - `machine: name`: that registered machine (`Xeito.Session.Router.machines/0`) with the input it needs.
  - neither: a chat turn of the text.
  - `tools:` `false` (the default), `true` (all) or a list of names: the chat turn's tools. Without
    `skill` among them, the turn does not pick a skill. A machine other than chat runs its own effects.
  - `as:` a decision type's name or a JSON Schema: the answer format of a chat turn without tools.
    The model is told the format after the text, and its calls are constrained to it.
  - `tier:`, `model:`, `temperature:`, `think:`: the turn's chat options (`Xeito.Chat`). The tier
    must be a configured chat tier (`Xeito.Session.ChatModel.choose/2`); spend gates still apply.
  """

  alias Xeito.Decision
  alias Xeito.Decision.Prompt
  alias Xeito.Decisions
  alias Xeito.Machines.Chat
  alias Xeito.Policy
  alias Xeito.Session
  alias Xeito.Session.ChatModel
  alias Xeito.Session.Input
  alias Xeito.Session.Router
  alias Xeito.Skills
  alias Xeito.Tiers
  alias Xeito.Tools

  @tools Tools.names() ++ ["skill", "fetch"]

  @type turn :: %{machine: module(), input: map(), reason: String.t(), chat: keyword(), notices: [String.t()]}

  @doc "The machine, its input, the run's reason and the chat options for a one-shot turn of `text`."
  @spec prepare(String.t(), keyword(), Session.state()) :: {:ok, turn()} | {:error, String.t()}
  def prepare(text, opts, s) do
    tools = Keyword.get(opts, :tools, false)

    with :ok <- check_tools(tools),
         {:ok, skill, opts, notices} <- skill_defaults(opts, tools, s),
         {:ok, chat, format} <- chat_and_format(opts, tools, s),
         {:ok, text} <- with_contexts(text, Keyword.get(opts, :contexts, []), s),
         {:ok, machine, input, reason} <- start(skill, opts, text, tools, %{s | chat: chat}) do
      with_format(%{machine: machine, input: input, reason: reason, chat: chat, notices: notices}, format)
    end
  end

  @doc "The first model request of a one-shot chat turn: its messages, tools, answer format and tier."
  @spec request(String.t(), keyword(), Session.state()) :: {:ok, map()} | {:error, String.t()}
  def request(text, opts, s) do
    case prepare(text, opts, s) do
      {:ok, %{machine: Chat, input: input, chat: chat}} ->
        {:ok, first_request(input, chat)}

      {:ok, %{machine: machine}} ->
        {:error, "#{name(machine)} sends no model request of its own; a dry run shows a chat turn's"}

      error ->
        error
    end
  end

  defp first_request(input, chat) do
    [effect] = Chat.ask_model(input)
    tier = ChatModel.current(chat)
    cfg = Tiers.config(tier, Keyword.delete(chat, :tier)) || []

    %{
      messages: effect.args.messages,
      tools: effect.args.tools,
      format: effect.args[:format],
      tier: tier,
      model: cfg[:chat_model] || cfg[:model]
    }
  end

  defp name(machine), do: Enum.find_value(Router.machines(), fn {name, m} -> if m == machine, do: name end)

  @doc "`:ok` when `tools` is `true`, `false` or a list of known tool names, else why not."
  @spec check_tools(boolean() | [String.t()]) :: :ok | {:error, String.t()}
  def check_tools(tools) when is_boolean(tools), do: :ok

  def check_tools(tools) when is_list(tools) do
    case Enum.find(tools, &(&1 not in @tools)) do
      nil -> :ok
      name -> {:error, "unknown tool #{inspect(name)}; the tools are #{Enum.join(@tools, ", ")}"}
    end
  end

  defp chat_and_format(opts, tools, s) do
    with {:ok, chat} <- chat(opts, s.chat),
         {:ok, format} <- format(opts[:as], tools),
         do: {:ok, chat, format}
  end

  defp chat(opts, session_chat) do
    with {:ok, tier} <- tier(opts[:tier]) do
      model = if opts[:model], do: [chat_model: opts[:model], model: opts[:model]], else: []
      sampling = for key <- [:temperature, :think], opts[key] != nil, do: {key, opts[key]}
      {:ok, Keyword.merge(session_chat, tier ++ model ++ sampling)}
    end
  end

  defp tier(nil), do: {:ok, []}

  defp tier(name) do
    configs = Map.new(ChatModel.tiers(), &{&1, Tiers.config(&1)})
    with {:ok, tier} <- ChatModel.choose(name, configs), do: {:ok, [tier: tier]}
  end

  defp format(nil, _tools), do: {:ok, nil}
  defp format(_as, tools) when tools != false, do: {:error, "an answer format takes no tools"}

  defp format(schema, _tools) when is_map(schema),
    do: {:ok, {schema, "Answer with JSON only, matching this JSON Schema:\n" <> JSON.encode!(schema)}}

  defp format(name, _tools) do
    case Enum.find(Decisions.all(), &(Decision.type!(&1).name == name)) do
      nil -> {:error, "unknown decision type #{inspect(name)}; the types are #{type_names()}"}
      module -> {:ok, {Prompt.json_schema(Decision.type!(module)), Prompt.instructions(Decision.type!(module))}}
    end
  end

  defp type_names, do: Enum.map_join(Decisions.all(), ", ", &Decision.type!(&1).name)

  defp with_format(turn, nil), do: {:ok, turn}

  defp with_format(%{machine: Chat, input: input} = turn, {schema, told}),
    do: {:ok, %{turn | input: Map.put(%{input | prompt: input.prompt <> "\n\n" <> told}, :format, schema)}}

  defp with_format(_turn, _format), do: {:error, "only a chat turn has an answer format"}

  # The named skill, if any, and its choices where the call made none: its tier (policy first),
  # output and contexts, plus the notices that explain a refused choice.
  defp skill_defaults(opts, tools, s) do
    case {opts[:skill], opts[:skill] && Enum.find(Skills.discover(s.cwd), &(&1.name == opts[:skill]))} do
      {nil, _} -> {:ok, nil, opts, []}
      {name, nil} -> {:error, "no skill named #{inspect(name)}"}
      {_name, skill} -> defaults(skill, opts, tools, s)
    end
  end

  defp defaults(skill, opts, tools, s) do
    {opts, notices} = skill_tier(skill, opts, s)

    opts =
      opts
      |> put_default(:as, skill_output(skill, tools))
      |> put_default(:contexts, Map.get(skill, :contexts, []))

    {:ok, skill, opts, notices}
  end

  defp put_default(opts, key, value), do: if(opts[key] in [nil, []], do: Keyword.put(opts, key, value), else: opts)

  defp skill_output(skill, false) do
    case Map.get(skill, :output, :text) do
      {:json, type} -> type
      :text -> nil
    end
  end

  defp skill_output(_skill, _tools), do: nil

  defp skill_tier(skill, opts, s) do
    tier = Map.get(skill, :tier)

    cond do
      tier in [nil, ""] or opts[:tier] != nil -> {opts, []}
      off_box?(tier) and Policy.effective().locality != :public -> {opts, [stays_local(skill, tier, s)]}
      true -> {Keyword.put(opts, :tier, tier), []}
    end
  end

  defp off_box?(name), do: Enum.any?(Tiers.off_box(), &(Atom.to_string(&1) == name))

  defp stays_local(skill, tier, s) do
    "the skill #{skill.name} asks for the #{tier} tier, but the policy keeps local-only input on this " <>
      "machine (locality: local_only), so the turn runs on #{ChatModel.current(s.chat)}"
  end

  defp with_contexts(text, [], _s), do: {:ok, text}

  defp with_contexts(text, names, s) do
    case Enum.find(names, &(Skills.context(s.cwd, &1) == :error)) do
      nil ->
        {:ok, Enum.reduce(names, text, &(&2 <> "\n\nContext \"#{&1}\":\n" <> elem(Skills.context(s.cwd, &1), 1)))}

      name ->
        {:error, "no context named #{inspect(name)} in #{Path.join(s.cwd, ".agents/contexts")} or ~/.agents/contexts"}
    end
  end

  defp start(nil, opts, text, tools, s) do
    case opts[:machine] do
      nil -> {:ok, Chat, chat_input(text, tools, s), "one-shot"}
      machine -> machine(machine, text, tools, s)
    end
  end

  defp start(skill, opts, text, tools, s) do
    if opts[:machine] do
      {:error, "a skill or a machine, not both"}
    else
      with {:ok, prompt} <- Skills.invocation(skill, text, Keyword.get(opts, :vars, %{})) do
        input = Map.put(chat_input(prompt, tools, s), :skill_candidates, [])
        {:ok, Chat, input, Keyword.get(opts, :reason, "one-shot skill:#{skill.name}")}
      end
    end
  end

  defp machine(name, text, tools, s) do
    case Router.machines() do
      %{^name => Chat} -> {:ok, Chat, chat_input(text, tools, s), "one-shot machine:#{name}"}
      %{^name => machine} -> {:ok, machine, Input.for_machine(machine, text, s), "one-shot machine:#{name}"}
      machines -> {:error, "unknown machine #{inspect(name)}; available: #{Enum.join(Map.keys(machines), ", ")}"}
    end
  end

  defp chat_input(text, true, s), do: Input.for_machine(Chat, text, s)

  defp chat_input(text, tools, s) do
    input = Map.put(Input.for_machine(Chat, text, s), :tools, tools)
    if is_list(tools) and "skill" in tools, do: input, else: %{input | skill_candidates: []}
  end
end
