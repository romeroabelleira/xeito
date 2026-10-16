defmodule Xeito.Effect do
  @moduledoc """
  A side effect as plain data, returned by a machine's entry function and executed by `Xeito.Effects`.

  The result comes back to the run as an event:

  | kind      | result event          | result data                              |
  |-----------|-----------------------|------------------------------------------|
  | `:bash`   | `:ran` (or `:reply`)  | `%{exit_status: integer, output: binary}` |
  | `:read`   | `:read`               | `%{ok: true, content: binary}` or `%{ok: false, error: term}` |
  | `:write`  | `:written`            | `%{ok: true}` or `%{ok: false, error: term}` |
  | `:edit`   | `:edited`             | `%{ok: true}` or `%{ok: false, error: term}` (old text must match once) |
  | `:chat`   | `:chatted`            | `%{content, tool_calls, model, tokens_in, tokens_out}` or `%{error: reason}` |
  | `:machine`| `:child_done`         | `%{run_id, status, state, ctx}` of a child run of another machine |
  | `:decide` | `{:decided, value}`   | `%{value: term}`                         |
  | `:tier`   | `:tier_done`          | a tier result, or `%{tier: t, error: reason}` (escalation) |
  | `:probe`  | `:probed`             | `%{loaded: boolean, swap_allowed: boolean}` (escalation) |
  | `:swap`   | `:swapped`            | `%{ok: boolean, ms: integer}` (escalation) |
  """

  @enforce_keys [:kind, :args, :reply]
  defstruct [:id, :kind, :args, :reply]

  @type kind ::
          :bash | :read | :write | :edit | :chat | :machine | :decide | :tier | :probe | :swap
  @type t :: %__MODULE__{id: String.t() | nil, kind: kind(), args: map(), reply: term()}

  # Result types by kind, as in the table above. Runners may add keys (a shaped output's `ref`,
  # `shaped`), hence `optional(atom())`.
  @type bash_result :: %{required(:exit_status) => integer(), required(:output) => binary(), optional(atom()) => term()}
  @type file_result ::
          %{required(:ok) => true, optional(:content) => binary(), optional(atom()) => term()}
          | %{ok: false, error: term()}
  @type chat_result :: Xeito.Chat.Message.reply() | %{error: term()}
  @type machine_result :: %{run_id: String.t(), status: atom(), state: atom() | nil, ctx: map()}
  @type decide_result :: %{required(:value) => term(), optional(atom()) => term()}
  @type escalation_result :: map()
  @type result ::
          bash_result() | file_result() | chat_result() | machine_result() | decide_result() | escalation_result()

  @doc "Run a shell command. Options: `:cwd`, `:timeout` (ms, default 60 000), `:reply`."
  @spec bash(String.t(), keyword()) :: t()
  def bash(cmd, opts \\ []) do
    %__MODULE__{
      kind: :bash,
      args: %{cmd: cmd, cwd: opts[:cwd], timeout: Keyword.get(opts, :timeout, 60_000)},
      reply: Keyword.get(opts, :reply, :ran)
    }
  end

  @doc """
  Read a file inside the workspace `:cwd`. With `outline: true` the result is the file's outline,
  with `symbol: name` the source of that definition (`Xeito.Source`).
  """
  @spec read(String.t(), keyword()) :: t()
  def read(path, opts \\ []) do
    %__MODULE__{
      kind: :read,
      args:
        Map.merge(
          %{path: path, cwd: opts[:cwd]},
          Map.new(Keyword.take(opts, [:outline, :symbol, :lines, :result]))
        ),
      reply: Keyword.get(opts, :reply, :read)
    }
  end

  @doc "Write a file inside the workspace `:cwd`."
  @spec write(String.t(), iodata(), keyword()) :: t()
  def write(path, content, opts \\ []) do
    %__MODULE__{
      kind: :write,
      args: %{path: path, content: IO.iodata_to_binary(content), cwd: opts[:cwd]},
      reply: Keyword.get(opts, :reply, :written)
    }
  end

  @doc "Replace the single exact occurrence of `old` with `new` in a workspace file."
  @spec edit(String.t(), String.t(), String.t(), keyword()) :: t()
  def edit(path, old, new, opts \\ []) do
    %__MODULE__{
      kind: :edit,
      args: %{path: path, old: old, new: new, cwd: opts[:cwd]},
      reply: Keyword.get(opts, :reply, :edited)
    }
  end

  @doc """
  One chat-model turn over `messages` (`Xeito.Chat`). `:tools` is a list of tool names
  (`Xeito.Tools`), `true` for the core tools (default) or `false` for none. Streamed output is
  published to `Xeito.Events` as it arrives; the complete message is the result.
  """
  @spec chat([map()], keyword()) :: t()
  def chat(messages, opts \\ []) do
    %__MODULE__{
      kind: :chat,
      args: chat_args(messages, opts),
      reply: Keyword.get(opts, :reply, :chatted)
    }
  end

  # `error:` (request does not fit the window): the runner replies with it instead of calling the model.
  # `quiet:` (e.g. a summary): the reply is not streamed to clients.
  defp chat_args(messages, opts) do
    args = Map.merge(%{messages: messages, tools: Keyword.get(opts, :tools, true)}, Map.new(Keyword.take(opts, [:quiet])))
    if Keyword.has_key?(opts, :error), do: Map.put(args, :error, opts[:error]), else: args
  end

  @doc """
  Run another machine to completion as a child run (a delegated sub-task). The child is logged
  in the same log with a `part_of` relation, and its outcome is the result.
  """
  @spec machine(module(), map(), keyword()) :: t()
  def machine(module, input, opts \\ []) do
    %__MODULE__{
      kind: :machine,
      args: %{machine: module, input: input, timeout: Keyword.get(opts, :timeout, 3_600_000)},
      reply: Keyword.get(opts, :reply, :child_done)
    }
  end

  @doc "Request a typed decision of `type` (a `Xeito.Decision` module) over `input`."
  @spec decide(module(), map()) :: t()
  def decide(type, input \\ %{}) do
    %__MODULE__{kind: :decide, args: %{decision: type, input: input}, reply: :decided}
  end

  @doc "Run one decider tier for a decision (used by `Xeito.Machines.Escalation`)."
  @spec tier(atom(), module(), map()) :: t()
  def tier(tier, type, input) do
    %__MODULE__{kind: :tier, args: %{tier: tier, decision: type, input: input}, reply: :tier_done}
  end

  @doc "Ask whether a tier's model is resident (the local tier)."
  @spec probe(atom(), map()) :: t()
  def probe(tier, args), do: %__MODULE__{kind: :probe, args: Map.put(args, :tier, tier), reply: :probed}

  @doc "Load a tier's model (the local tier): a swap."
  @spec swap(atom(), map()) :: t()
  def swap(tier, args), do: %__MODULE__{kind: :swap, args: Map.put(args, :tier, tier), reply: :swapped}

  @doc "Turns a runner result into the `{event_name, event_data}` delivered to the run."
  @spec to_event(t(), term()) :: {term(), term()}
  def to_event(%__MODULE__{kind: :decide}, %{value: value} = result), do: {{:decided, value}, result}

  def to_event(%__MODULE__{reply: reply}, result), do: {reply, result}
end
