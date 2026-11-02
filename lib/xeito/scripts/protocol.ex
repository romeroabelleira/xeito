defmodule Xeito.Scripts.Protocol do
  @moduledoc """
  The messages between the daemon and a script sandbox VM (`Xeito.Scripts.Sandbox`,
  `Xeito.Scripts.Vm`): JSON Lines over the VM's stdin and stdout, one message per line.

  | from | message | fields |
  |---|---|---|
  | VM | `ready` | — |
  | daemon | `run` | `id`, `code`, `limits` (`reductions`, `heap`, `timeout_ms`) |
  | VM | `call` | `id` (the call's number), `name` (`read`, `bash`, …), `args` |
  | daemon | `reply` | `id`, `value` |
  | VM | `done` | `id`, `value` (the script's last value, JSON where it can be, else inspected), `stdio` |
  | VM | `failed` | `id`, `type` (`restricted`, `reductions`, `memory`, `timeout`, `exception`, `parsing`, `call`), `message`, `stdio` |

  `encode/1` and `decode/1` are pure and never raise: a line that is not a message decodes to
  `{:error, line}`. Values that JSON cannot carry (tuples, pids, functions) are inspected.
  """

  @type message :: map()

  @doc "A message as one line, newline included."
  @spec encode(message()) :: String.t()
  def encode(message), do: (message |> Map.new(fn {k, v} -> {to_string(k), jsonable(v)} end) |> JSON.encode!()) <> "\n"

  @doc "A line as a message (string keys), or `{:error, line}`."
  @spec decode(String.t()) :: {:ok, message()} | {:error, String.t()}
  def decode(line) do
    case JSON.decode(String.trim(line)) do
      {:ok, %{"t" => type} = message} when is_binary(type) -> {:ok, message}
      _ -> {:error, line}
    end
  end

  @doc "A term as JSON can carry it: tuples, pids, references and functions are inspected; keys become strings."
  @spec jsonable(term()) :: term()
  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(%_{} = struct), do: inspect(struct)
  def jsonable(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), jsonable(v)} end)
  def jsonable(value), do: scalar(value)

  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
