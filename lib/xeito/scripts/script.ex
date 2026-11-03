defmodule Script do
  @moduledoc """
  The name a script uses for `Xeito.Scripts.Api`: `Script.read("lib/a.ex")`, `Script.bash("ls")`.

  Scripts are evaluated in Dune, which has no `alias`, so the API carries a short top-level name.
  """

  alias Xeito.Scripts.Api

  defdelegate read(path), to: Api
  defdelegate bash(command), to: Api
  defdelegate write(path, content), to: Api
  defdelegate edit(path, old, new), to: Api
  defdelegate decide(type, input), to: Api
  defdelegate classify(questions, state), to: Api
  defdelegate remember(id, attrs), to: Api
  defdelegate mcp(server, tool, args), to: Api
  defdelegate search_tools(query), to: Api
  defdelegate text(value), to: Api
  defdelegate now(), to: Api
  defdelegate random(), to: Api
  defdelegate parallel(items, fun, opts \\ []), to: Api
end
