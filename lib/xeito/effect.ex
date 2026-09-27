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

  Effects are plain data, so they can be logged, replayed from the log, and policy-checked
  at one choke point.
  """

  @enforce_keys [:kind, :args, :reply]
  defstruct [:id, :kind, :args, :reply]

  @type kind :: :bash | :read | :write | :decide
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

  @doc "Request the typed decision `name` over `input`. Deciders arrive in P2; P1 runners stub it."
  @spec decide(atom(), map()) :: t()
  def decide(name, input \\ %{}) do
    %__MODULE__{kind: :decide, args: %{decision: name, input: input}, reply: :decided}
  end

  @doc "Turns a runner result into the `{event_name, event_data}` delivered to the run."
  @spec to_event(t(), term()) :: {term(), term()}
  def to_event(%__MODULE__{kind: :decide}, %{value: value} = result),
    do: {{:decided, value}, result}

  def to_event(%__MODULE__{reply: reply}, result), do: {reply, result}
end
