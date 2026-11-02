defmodule Xeito.Effect do
  @moduledoc """
  A side effect as plain data, returned by a machine's entry function and executed by `Xeito.Effects`.

  The result comes back to the run as an event:

  | kind      | result event          | result data                              |
  |-----------|-----------------------|------------------------------------------|
  | `:bash`   | `:ran` (or `:reply`)  | `%{exit_status: integer, output: binary}` |
  | `:read`   | `:read`               | `%{ok: true, content: binary}` or `%{ok: false, error: term}` |
  | `:fetch`  | `:fetched`            | `%{ok: true, content: markdown, url, status, title}` or `%{ok: false, error: term}` |
  | `:write`  | `:written`            | `%{ok: true}` or `%{ok: false, error: term}` |
  | `:edit`   | `:edited`             | `%{ok: true}` or `%{ok: false, error: term}` (old text must match once) |
  | `:script` | `:scripted`           | `%{ok: true, content: output}` or `%{ok: false, error: reason}` (`Xeito.Effects.Script`) |
  | `:now`    | `:now`                | `%{value: unix_ms}`: the runner's clock, which a script has no other way to read |
  | `:random` | `:random`             | `%{value: float}`: the runner's randomness, in `[0, 1)` |
  | `:remember` | `:remembered`       | `%{ok: true}` or `%{ok: false, error: term}`: an object written to the run's log by a script |
  | `:chat`   | `:chatted`            | `%{content, tool_calls, model, tokens_in, tokens_out}` or `%{error: reason}` |
  | `:machine`| `:child_done`         | `%{run_id, status, state, ctx}` of a child run of another machine |
  | `:decide` | `{:decided, value}`   | `%{value: term}`                         |
  | `:tier`   | `:tier_done`          | a tier result, or `%{tier: t, error: reason}` (escalation) |
  | `:probe`  | `:probed`             | `%{loaded: boolean, swap_allowed: boolean}` (escalation) |
  | `:swap`   | `:swapped`            | `%{ok: boolean, ms: integer}` (escalation) |

  A script's calls are **child effects** of the script's: numbered under its id (`<id>/c<n>`,
  `child_id/2`), requested and completed by the run like any effect, with the script's effect
  as their parent in the log. A script run again (recovery, `mix xeito.log verify`) is fed their
  logged results (`Xeito.Scripts.Replay`), which is why the clock and randomness are effects too.
  """

  alias Xeito.Decisions.Risk

  @enforce_keys [:kind, :args, :reply]
  defstruct [:id, :kind, :args, :reply]

  @type kind ::
          :bash
          | :read
          | :fetch
          | :write
          | :edit
          | :script
          | :now
          | :random
          | :remember
          | :chat
          | :machine
          | :decide
          | :tier
          | :probe
          | :swap
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

  @doc """
  Whether the effect may run again after a crash (`:safe`), or must end as interrupted
  (`:unsafe`): an edit has replaced its text once already, and a command may run again only when
  `Xeito.Decisions.Risk.repeatable?/1` says so: a read, or a write a second run leaves as the
  first did. A child machine resumes from its own log; a script runs again fed the logged results
  of its calls, so only the calls it had not made run.
  """
  @spec replay(t()) :: :safe | :unsafe
  def replay(%__MODULE__{kind: :edit}), do: :unsafe

  def replay(%__MODULE__{kind: :bash, args: %{cmd: cmd}}), do: if(Risk.repeatable?(cmd), do: :safe, else: :unsafe)

  def replay(%__MODULE__{}), do: :safe

  @doc """
  For a command, whether undo's snapshot would take it back (`Xeito.Decisions.Risk.assess/2`);
  `nil` for a command that writes nothing, and for any other kind of effect. Logged with the request.
  """
  @spec undoable(t()) :: boolean() | nil
  def undoable(%__MODULE__{kind: :bash, args: %{cmd: cmd} = args}), do: Risk.assess(cmd, args[:cwd] || "").undoable
  def undoable(%__MODULE__{}), do: nil

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

  @doc """
  Run a script (`Xeito.Effects.Script`) in the session's sandbox, its calls confined to the
  workspace `:cwd`; `sandbox` is the allow-list's fingerprint (`Xeito.Scripts.Allowlist`), so a
  replay knows the script would see the same. Options: `:timeout` (ms, the whole script, default
  300 000), `:reply`.
  """
  @spec script(String.t(), keyword()) :: t()
  def script(code, opts \\ []) do
    %__MODULE__{
      kind: :script,
      args: %{
        code: code,
        cwd: opts[:cwd],
        timeout: Keyword.get(opts, :timeout, 300_000),
        sandbox: Xeito.Scripts.Allowlist.fingerprint()
      },
      reply: Keyword.get(opts, :reply, :scripted)
    }
  end

  @doc "A reading of the runner's clock (Unix milliseconds), for a script."
  @spec now() :: t()
  def now, do: %__MODULE__{kind: :now, args: %{}, reply: :now}

  @doc "An object `id` of the script's `type` with `attrs`, for the run's log as a `note` object (`Xeito.Log.Schema`)."
  @spec remember(String.t(), String.t(), map()) :: t()
  def remember(id, type, attrs),
    do: %__MODULE__{kind: :remember, args: %{id: id, type: type, attrs: attrs}, reply: :remembered}

  @doc "A reading of the runner's randomness (a float in `[0, 1)`), for a script."
  @spec random() :: t()
  def random, do: %__MODULE__{kind: :random, args: %{}, reply: :random}

  @doc "The id of the `n`th child effect of effect `parent`."
  @spec child_id(String.t(), pos_integer()) :: String.t()
  def child_id(parent, n), do: "#{parent}/c#{n}"

  @doc "The id of the effect a child effect id belongs to, or `nil` for an effect of the run's own."
  @spec parent(String.t()) :: String.t() | nil
  def parent(id) do
    case Regex.run(~r{^(.+)/c\d+$}, id) do
      [_, parent] -> parent
      nil -> nil
    end
  end

  @doc "Whether the effect is a child of another (a script's call)."
  @spec child?(t()) :: boolean()
  def child?(%__MODULE__{id: id}), do: is_binary(id) and parent(id) != nil

  @doc "Fetch a URL (`Xeito.Effects.Fetch`): its body as Markdown. Options: `:reply`."
  @spec fetch(String.t(), keyword()) :: t()
  def fetch(url, opts \\ []), do: %__MODULE__{kind: :fetch, args: %{url: url}, reply: Keyword.get(opts, :reply, :fetched)}

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
  (`Xeito.Tools`), `true` for the core tools (default) or `false` for none; `:format`, a JSON
  Schema the answer must match. Streamed output is published to `Xeito.Events` as it arrives;
  the complete message is the result.
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
    args =
      Map.merge(
        %{messages: messages, tools: Keyword.get(opts, :tools, true)},
        Map.new(Keyword.take(opts, [:quiet, :format]))
      )

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
  @spec decide(module() | Xeito.Decision.Type.t(), map()) :: t()
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
