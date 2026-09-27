defmodule Xeito.Effect do
  @moduledoc """
  A description of a side effect, returned by a machine's entry function and executed by an
  effect runner (see `Xeito.Effects`). The result comes back to the run as an event:

  | kind      | result event          | result data                              |
  |-----------|-----------------------|------------------------------------------|
  | `:bash`   | `:ran` (or `:reply`)  | `%{exit_status: integer, output: binary}` |
  | `:read`   | `:read`               | `%{ok: true, content: binary}` or `%{ok: false, error: term}` |
  | `:write`  | `:written`            | `%{ok: true}` or `%{ok: false, error: term}` |
  | `:decide` | `{:decided, value}`   | `%{value: term}`                         |
  | `:tier`   | `:tier_done`          | a tier result, or `%{tier: t, error: reason}` (escalation) |
  | `:probe`  | `:probed`             | `%{loaded: boolean, swap_allowed: boolean}` (escalation) |
  | `:swap`   | `:swapped`            | `%{ok: boolean, ms: integer}` (escalation) |

  Effects are plain data, so they can be logged, replayed from the log, and policy-checked
  at one choke point.
  """

  @enforce_keys [:kind, :args, :reply]
  defstruct [:id, :kind, :args, :reply]

  @type kind :: :bash | :read | :write | :decide | :tier | :probe | :swap
  @type t :: %__MODULE__{id: String.t() | nil, kind: kind(), args: map(), reply: term()}

  @doc "Run a shell command. Options: `:cwd`, `:timeout` (ms, default 60 000), `:reply`."
  @spec bash(String.t(), keyword()) :: t()
  def bash(cmd, opts \\ []) do
    %__MODULE__{
      kind: :bash,
      args: %{cmd: cmd, cwd: opts[:cwd], timeout: Keyword.get(opts, :timeout, 60_000)},
      reply: Keyword.get(opts, :reply, :ran)
    }
  end

  @doc "Read a file inside the workspace `:cwd`."
  @spec read(String.t(), keyword()) :: t()
  def read(path, opts \\ []) do
    %__MODULE__{
      kind: :read,
      args: %{path: path, cwd: opts[:cwd]},
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

  @doc "Ask whether a tier's model is resident (large tier)."
  @spec probe(atom(), map()) :: t()
  def probe(tier, args),
    do: %__MODULE__{kind: :probe, args: Map.put(args, :tier, tier), reply: :probed}

  @doc "Load a tier's model (large tier): a swap."
  @spec swap(atom(), map()) :: t()
  def swap(tier, args),
    do: %__MODULE__{kind: :swap, args: Map.put(args, :tier, tier), reply: :swapped}

  @doc "Turns a runner result into the `{event_name, event_data}` delivered to the run."
  @spec to_event(t(), term()) :: {term(), term()}
  def to_event(%__MODULE__{kind: :decide}, %{value: value} = result),
    do: {{:decided, value}, result}

  def to_event(%__MODULE__{reply: reply}, result), do: {reply, result}
end
