defmodule Xeito.Scripts.Api do
  @moduledoc """
  What a script calls to reach the outside: each function is one request to the runner
  (`Xeito.Scripts.Vm.call/2`), which answers it as an effect of its own, logged and gated
  (`Xeito.Effects.Script`).

  Results are maps with string keys, as JSON carries them: `read/1` gives
  `%{"ok" => true, "content" => text}` or `%{"ok" => false, "error" => reason}`; `bash/1` gives
  `%{"exit_status" => n, "output" => text}` for a command safe by rule, and
  `%{"ok" => false, "error" => reason}` for one that would need a review (a forbidden one stops
  the script). `write/2` and `edit/3` give `%{"ok" => true}` or an error, and refuse the
  directories the tools refuse; a script's changes are one undo step. `decide/2` runs a
  registered decision type by name (`"triage"`) and `classify/2` one ad-hoc decision per
  question (`Xeito.Decisions.AdHoc`), each answered as `%{"value" => v, "confidence" => c,
  "actor" => a, "model" => m, "probabilities" => %{}}`; `remember/2` writes an object to the
  run's log (its `"type"` attribute is the object's type). `mcp/3` calls a tool of one of the
  workspace's MCP servers (`Xeito.Mcp`) and gives `%{"ok" => true, "content" => text}` or an
  error; only a read-only, closed-world tool runs from a script, and `search_tools/1` finds
  tools by words. `text/1` adds a line to the script's
  output for the model (the last value of the script is output, too) and returns it. `now/0`
  (Unix milliseconds) and `random/0` come from the runner as effects of their own, so a replay
  sees what the first run saw. `parallel/3` maps `fun` over `items`, at most `max:` (4) at a
  time by the runner's account; here it is in order.
  """

  alias Xeito.Scripts.Vm

  @spec read(String.t()) :: map()
  def read(path), do: Vm.call("read", [path])

  @spec bash(String.t()) :: map()
  def bash(command), do: Vm.call("bash", [command])

  @spec write(String.t(), String.t()) :: map()
  def write(path, content), do: Vm.call("write", [path, content])

  @spec edit(String.t(), String.t(), String.t()) :: map()
  def edit(path, old, new), do: Vm.call("edit", [path, old, new])

  @spec decide(String.t(), map()) :: map()
  def decide(type, input), do: Vm.call("decide", [type, input])

  @spec classify(map(), map()) :: map()
  def classify(questions, state), do: Vm.call("classify", [questions, state])

  @spec remember(String.t(), map()) :: map()
  def remember(id, attrs), do: Vm.call("remember", [id, attrs])

  @spec mcp(String.t(), String.t(), map()) :: map()
  def mcp(server, tool, args), do: Vm.call("mcp", [server, tool, args])

  @spec search_tools(String.t()) :: [map()]
  def search_tools(query), do: Vm.call("search_tools", [query])

  @spec text(term()) :: term()
  def text(value), do: Vm.call("text", [value])

  @spec now() :: integer()
  def now, do: Vm.call("now", [])

  @spec random() :: float()
  def random, do: Vm.call("random", [])

  @spec parallel(Enumerable.t(), (term() -> term()), keyword()) :: [term()]
  def parallel(items, fun, _opts \\ []), do: Enum.map(items, fun)
end
