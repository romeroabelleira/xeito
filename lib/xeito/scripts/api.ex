defmodule Xeito.Scripts.Api do
  @moduledoc """
  What a script calls to reach the outside, under the short name `Script`: each function is one
  request to the runner (`Xeito.Scripts.Vm.call/2`), which answers it as an effect of its own,
  logged and gated (`Xeito.Effects.Script`), and shaped here as Elixir code expects it.

  A call that can fail gives `{:ok, value}` or `{:error, reason}`; one that only changes
  something gives `:ok` or `{:error, reason}`; the maps have atom keys; a call that cannot fail
  gives its value, and raises only when the script was stopped (a forbidden command, a desync).

  | call | success | failure |
  |---|---|---|
  | `read(path)` | `{:ok, text}` | `{:error, reason}` |
  | `bash(command)` | `{:ok, output}` when the command exits 0 | `{:error, %{exit_status: n, output: text}}`; `{:error, reason}` when it did not run (it would need a review; a forbidden one stops the script) |
  | `write(path, text)`, `edit(path, old, new)` | `:ok` | `{:error, reason}` (the directories the tools refuse); a script's changes are one undo step |
  | `decide(type, input)` | `{:ok, %{value: v, confidence: c, actor: a, model: m, probabilities: %{}}}` for a registered type by name (`"triage"`) | `{:error, reason}` |
  | `classify(questions, state)` | `{:ok, %{"name" => %{value: v, confidence: c, …}}}`, one ad-hoc decision per question (`Xeito.Decisions.AdHoc`) | `{:error, reason}` |
  | `remember(id, attrs)` | `:ok`, the object written to the run's log (`"type"` is its type) | `{:error, reason}` |
  | `mcp(server, tool, args)` | `{:ok, text}`, for a read-only, closed-world tool of the workspace's MCP servers (`Xeito.Mcp`) | `{:error, reason}` |
  | `search_tools(words)` | `[%{server: s, name: n, description: d, schema: %{}}]` | raises |
  | `text(value)` | the line added to the script's output (the last value is output too) | raises |
  | `now()`, `random()` | Unix milliseconds; a float in [0, 1), both from the runner so a replay sees what the first run saw | raises |
  | `parallel(items, fun, max: 4)` | `fun` over `items`, in order here | — |

  The runner answers in JSON, with string keys, and the log keeps each child effect's result as
  the runner gave it; the shaping happens here, after the reply, so a replay feeds the same
  answers. `shapes/0` numbers these shapes for the sandbox fingerprint
  (`Xeito.Scripts.Allowlist.fingerprint/0`): a script written for other shapes is not run again.
  """

  alias Xeito.Scripts.Vm

  @shapes 2
  @keys %{
    "value" => :value,
    "confidence" => :confidence,
    "actor" => :actor,
    "model" => :model,
    "probabilities" => :probabilities,
    "error" => :error,
    "exit_status" => :exit_status,
    "output" => :output,
    "server" => :server,
    "name" => :name,
    "description" => :description,
    "schema" => :schema
  }

  @doc "The version of the shapes this API gives scripts; part of the sandbox fingerprint."
  @spec shapes() :: pos_integer()
  def shapes, do: @shapes

  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(path), do: "read" |> Vm.call([path]) |> content()

  @spec bash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def bash(command), do: "bash" |> Vm.call([command]) |> command()

  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  def write(path, content), do: "write" |> Vm.call([path, content]) |> done()

  @spec edit(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit(path, old, new), do: "edit" |> Vm.call([path, old, new]) |> done()

  @spec decide(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def decide(type, input), do: "decide" |> Vm.call([type, input]) |> verdict()

  @spec classify(map(), map()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def classify(questions, state), do: "classify" |> Vm.call([questions, state]) |> verdicts()

  @spec remember(String.t(), map()) :: :ok | {:error, term()}
  def remember(id, attrs), do: "remember" |> Vm.call([id, attrs]) |> done()

  @spec mcp(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def mcp(server, tool, args), do: "mcp" |> Vm.call([server, tool, args]) |> content()

  @spec search_tools(String.t()) :: [map()]
  def search_tools(query), do: "search_tools" |> Vm.call([query]) |> plain() |> Enum.map(&atom_keys/1)

  @spec text(term()) :: String.t()
  def text(value), do: "text" |> Vm.call([value]) |> plain()

  @spec now() :: integer()
  def now, do: "now" |> Vm.call([]) |> plain()

  @spec random() :: float()
  def random, do: "random" |> Vm.call([]) |> plain()

  @spec parallel(Enumerable.t(), (term() -> term()), keyword()) :: [term()]
  def parallel(items, fun, _opts \\ []), do: Enum.map(items, fun)

  defp content(%{"ok" => true, "content" => content}), do: {:ok, content}
  defp content(reply), do: failed(reply)

  defp command(%{"exit_status" => 0, "output" => output}), do: {:ok, output}
  defp command(%{"exit_status" => status, "output" => output}), do: {:error, %{exit_status: status, output: output}}
  defp command(reply), do: failed(reply)

  defp done(%{"ok" => true}), do: :ok
  defp done(reply), do: failed(reply)

  # A decision that was made has a value and no error; one that was not has the reason.
  defp verdict(%{"value" => _} = verdict) when not is_map_key(verdict, "error"), do: {:ok, atom_keys(verdict)}
  defp verdict(reply), do: failed(reply)

  defp verdicts(%{"ok" => false} = reply), do: failed(reply)
  defp verdicts(answers) when is_map(answers), do: {:ok, Map.new(answers, fn {name, v} -> {name, atom_keys(v)} end)}
  defp verdicts(reply), do: failed(reply)

  defp failed(%{"error" => reason}), do: {:error, reason}
  defp failed(reply), do: {:error, "unexpected answer: " <> inspect(reply)}

  # The calls that cannot fail: the runner refuses one only once the script is stopped.
  defp plain(%{"ok" => false, "error" => reason}), do: raise(RuntimeError, message: reason)
  defp plain(value), do: value

  defp atom_keys(map), do: Map.new(map, fn {k, v} -> {Map.get(@keys, k, k), v} end)
end
