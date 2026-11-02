defmodule Xeito.Scripts.Api do
  @moduledoc """
  What a script calls to reach the outside: each function is one request to the runner
  (`Xeito.Scripts.Vm.call/2`), which answers it as an effect of its own, logged and gated
  (`Xeito.Effects.Script`).

  Results are maps with string keys, as JSON carries them: `read/1` gives
  `%{"ok" => true, "content" => text}` or `%{"ok" => false, "error" => reason}`; `bash/1` gives
  `%{"exit_status" => n, "output" => text}` for a command safe by rule, and
  `%{"ok" => false, "error" => reason}` for one that would need a review (a forbidden one stops
  the script). `text/1` adds a line to the script's output for the model (the last value of the
  script is output, too) and returns it. `now/0` (Unix milliseconds) and `random/0` come from
  the runner, so a replay sees what the first run saw. `parallel/3` maps `fun` over `items`, at
  most `max:` (4) at a time by the runner's account; here it is in order.
  """

  alias Xeito.Scripts.Vm

  @spec read(String.t()) :: map()
  def read(path), do: Vm.call("read", [path])

  @spec bash(String.t()) :: map()
  def bash(command), do: Vm.call("bash", [command])

  @spec text(term()) :: term()
  def text(value), do: Vm.call("text", [value])

  @spec now() :: integer()
  def now, do: Vm.call("now", [])

  @spec random() :: float()
  def random, do: Vm.call("random", [])

  @spec parallel(Enumerable.t(), (term() -> term()), keyword()) :: [term()]
  def parallel(items, fun, _opts \\ []), do: Enum.map(items, fun)
end
