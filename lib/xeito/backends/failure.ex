defmodule Xeito.Backends.Failure do
  @moduledoc """
  What a failed model call means, so callers retry only what may succeed.

    * `:overflow`: the request is longer than the model's context window; the caller shortens it.
    * `:quota`: a quota or billing refusal; never retried.
    * `{:retry, ms}`: transient (408, 409, 429, 5xx, a transport error); tried again after `ms`,
      as the server's `retry-after`/`retry-after-ms` asks, else 1, 2, 4 s; a server that asks for
      more than a minute fails at once.
    * `:other`: anything else.

  `run/2` makes a call with retries and turns a final failure into an error the caller can show.
  """

  @max_wait_ms 60_000
  @attempts 3

  @type t :: :overflow | :quota | {:retry, non_neg_integer()} | :other
  @type outcome ::
          {:ok, term()}
          | {:failed, non_neg_integer(), String.t(), [{String.t(), String.t()}]}
          | {:error, term()}
          | {:final, term()}

  @doc "What a failure means: `status` is the HTTP status, or `:transport` for a connection error."
  @spec classify(non_neg_integer() | :transport, String.t(), [{String.t(), String.t()}], pos_integer()) :: t()
  def classify(status, body, headers, attempt) do
    cond do
      overflow?(body) -> :overflow
      status == 402 or quota?(body) -> :quota
      transient?(status) -> wait(headers, attempt)
      true -> :other
    end
  end

  defp transient?(:transport), do: true
  defp transient?(status), do: status in [408, 409, 429] or status in 500..599

  defp overflow?(body),
    do:
      Regex.match?(
        ~r/context.{0,20}(length|window|limit)|maximum context|too many tokens|(prompt|input) is too long|reduce the length/i,
        body
      )

  defp quota?(body),
    do:
      Regex.match?(
        ~r/insufficient.?(quota|credits|balance|funds)|quota exceeded|out of (budget|credits)|billing|more credits|key limit/i,
        body
      )

  defp wait(headers, attempt) do
    case retry_after(Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)) || 1_000 * 2 ** (attempt - 1) do
      ms when ms > @max_wait_ms -> :other
      ms -> {:retry, ms}
    end
  end

  defp retry_after(%{"retry-after-ms" => ms}), do: parse(ms, 1)
  defp retry_after(%{"retry-after" => s}), do: parse(s, 1_000)
  defp retry_after(_headers), do: nil

  defp parse(value, scale) do
    case Float.parse(value) do
      {n, _} -> round(n * scale)
      :error -> nil
    end
  end

  @doc "The error for a request longer than the model's window, with what the server said."
  @spec overflow(String.t()) :: {:context_overflow, String.t()}
  def overflow(detail), do: {:context_overflow, "the request is longer than the model's context window: " <> detail}

  @doc """
  Makes `call` (returning `{:ok, value}`, `{:failed, status, body, headers}`, `{:error, reason}`, or
  `{:final, reason}` for a failure not to retry, such as one after output was streamed) with retries. Options: `:attempts` (default #{@attempts}), `:sleep` (`fun(ms)`, for tests).
  """
  @spec run((-> outcome()), keyword()) :: {:ok, term()} | {:error, term()}
  def run(call, opts \\ []),
    do: attempt(call, 1, Keyword.get(opts, :attempts, @attempts), Keyword.get(opts, :sleep, &Process.sleep/1))

  defp attempt(call, n, max, sleep) do
    case call.() do
      {:ok, value} ->
        {:ok, value}

      {:failed, status, body, headers} ->
        failed(classify(status, body, headers, n), {status, body}, {call, n, max, sleep})

      {:error, reason} ->
        failed(classify(:transport, inspect(reason), [], n), reason, {call, n, max, sleep})

      {:final, reason} ->
        {:error, reason}
    end
  end

  defp failed({:retry, ms}, _failure, {call, n, max, sleep}) when n < max do
    sleep.(ms)
    attempt(call, n + 1, max, sleep)
  end

  defp failed(:overflow, {_status, body}, _again), do: {:error, overflow(body)}

  defp failed(:quota, {_status, body}, _again),
    do:
      {:error,
       {:quota,
        "OpenRouter refused the call for quota or billing (#{body}): add credit or raise the key's limit, or /model local"}}

  defp failed(_meaning, {status, body}, _again) when is_integer(status), do: {:error, {:http, status, body}}
  defp failed(_meaning, reason, _again), do: {:error, reason}
end
