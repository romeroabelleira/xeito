defmodule Xeito.Allowance do
  @moduledoc """
  Tracks what an OpenRouter key may still spend and gates remote chat calls on their worst-case cost.

    * allowance (`remaining/1`): the smallest of the key's blocking budget or limit and the
      account's credits (`left/2`); fetched at most once a minute per key, lowered by `spent/2`
      in between; `nil` if unknown (a failed fetch is not cached)
    * price (`model_price/1`): the model's dearest endpoint, fetched once per model
    * gate (`verdict/1`): a call goes ahead while the run's off-box budget is not spent and its
      `worst_case/3` fits in a known allowance
  """

  use GenServer

  alias Xeito.Backends

  @fresh_ms 60_000

  # --- pure ---

  @doc "What is left: the key's blocking budget or limit, capped by the account's credits; `nil` if unknown."
  @spec left(map(), map() | nil) :: float() | nil
  def left(key, credits) do
    key_left = get_in(key, ["effective_budget", "remaining_usd"]) || key["limit_remaining"]
    credits_left = if credits, do: credits["total_credits"] - credits["total_usage"]

    case Enum.reject([key_left, credits_left], &is_nil/1) do
      [] -> nil
      amounts -> Enum.min(amounts)
    end
  end

  @doc "A model's price per token (USD) at its dearest endpoint, and its smallest context window."
  @spec price(map()) :: %{prompt: float(), completion: float(), context: pos_integer() | nil} | nil
  def price(%{"endpoints" => [_ | _] = endpoints}) do
    %{
      prompt: endpoints |> Enum.map(&per_token(&1, "prompt")) |> Enum.max(),
      completion: endpoints |> Enum.map(&per_token(&1, "completion")) |> Enum.max(),
      context: endpoints |> Enum.map(& &1["context_length"]) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
    }
  end

  def price(_endpoints), do: nil

  defp per_token(endpoint, kind) do
    {value, _} = Float.parse(get_in(endpoint, ["pricing", kind]) || "0")
    value
  end

  @doc "The most a call can cost: every input token at full price and the answer at its limit."
  @spec worst_case(map() | nil, non_neg_integer(), non_neg_integer()) :: float()
  def worst_case(nil, _tokens_in, _max_tokens), do: 0.0
  def worst_case(price, tokens_in, max_tokens), do: tokens_in * price.prompt + max_tokens * price.completion

  @doc "Whether a call may go ahead, or why not (a message for the user)."
  @spec verdict(%{run_spent: number(), run_max: number(), left: number() | nil, worst: number()}) ::
          :ok | {:error, {:budget | :allowance, String.t()}}
  def verdict(%{run_spent: spent, run_max: max}) when spent >= max,
    do:
      {:error, {:budget, "this turn's off-box budget (#{usd(max)}) is spent: /budget <usd> raises it, then ask to go on"}}

  def verdict(%{left: left, worst: worst}) when is_number(left) and worst > left,
    do:
      {:error,
       {:allowance,
        "the OpenRouter key has #{usd(left)} left, and the next call could cost up to #{usd(worst)}: " <>
          "add credit or raise the key's limit, or /model local"}}

  def verdict(_plan), do: :ok

  defp usd(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)

  # --- cache ---

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "What the tier's key may still spend (fetched at most once a minute); `nil` if unknown."
  @spec remaining(keyword()) :: float() | nil
  def remaining(cfg) do
    k = {cfg[:url], cfg[:api_key]}

    case GenServer.call(__MODULE__, {:remaining, k, now()}) do
      {:ok, left} -> left
      :stale -> GenServer.call(__MODULE__, {:fetched, k, fetch_left(cfg), now()})
    end
  end

  @doc "The last known allowance, without asking OpenRouter; `nil` before the first fetch."
  @spec last(keyword()) :: float() | nil
  def last(cfg), do: GenServer.call(__MODULE__, {:last, {cfg[:url], cfg[:api_key]}})

  @doc "Records money spent with the tier's key."
  @spec spent(keyword(), number()) :: :ok
  def spent(cfg, usd), do: GenServer.cast(__MODULE__, {:spent, {cfg[:url], cfg[:api_key]}, usd})

  @doc "The tier's model's price (`price/1`), fetched once; `nil` if unknown."
  @spec model_price(keyword()) :: map() | nil
  def model_price(cfg) do
    k = {cfg[:url], cfg[:model]}

    case GenServer.call(__MODULE__, {:price, k}) do
      {:ok, price} -> price
      :error -> GenServer.call(__MODULE__, {:priced, k, fetch_price(cfg)})
    end
  end

  defp fetch_left(cfg) do
    with {:ok, key} <- get(cfg, "/v1/key") do
      credits = with {:error, _} <- get(cfg, "/v1/credits"), do: {:ok, nil}
      left(key, elem(credits, 1))
    end
  end

  defp fetch_price(cfg) do
    with {:ok, data} <- get(cfg, "/v1/models/#{cfg[:model]}/endpoints"), do: price(data)
  end

  defp get(cfg, path) do
    case Req.request([method: :get, url: path] ++ Backends.req_options(Keyword.put(cfg, :timeout, 5_000))) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      other -> {:error, other}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(:ok), do: {:ok, %{keys: %{}, prices: %{}}}

  @impl true
  def handle_call({:price, _k} = msg, _from, s), do: price_call(msg, s)
  def handle_call({:priced, _k, _price} = msg, _from, s), do: price_call(msg, s)
  def handle_call(msg, _from, s), do: key_call(msg, s)

  defp key_call({:remaining, k, now}, s), do: {:reply, fresh(s.keys[k], now), s}

  defp key_call({:fetched, _k, {:error, _}, _now}, s), do: {:reply, nil, s}
  defp key_call({:fetched, k, left, now}, s), do: {:reply, left, put_in(s.keys[k], %{at: now, left: left, spent: 0})}

  defp key_call({:last, k}, s), do: {:reply, with(%{left: left, spent: spent} <- s.keys[k], do: minus(left, spent)), s}

  defp price_call({:price, k}, s), do: {:reply, Map.fetch(s.prices, k), s}
  defp price_call({:priced, _k, {:error, _}}, s), do: {:reply, nil, s}
  defp price_call({:priced, k, price}, s), do: {:reply, price, put_in(s.prices[k], price)}

  @impl true
  def handle_cast({:spent, k, usd}, s) do
    {:noreply,
     update_in(s.keys, &Map.update(&1, k, %{at: nil, left: nil, spent: usd}, fn e -> %{e | spent: e.spent + usd} end))}
  end

  defp fresh(%{at: at, left: left, spent: spent}, now) when is_integer(at) and now - at < @fresh_ms,
    do: {:ok, minus(left, spent)}

  defp fresh(_entry, _now), do: :stale

  defp minus(nil, _spent), do: nil
  defp minus(left, spent), do: left - spent
end
