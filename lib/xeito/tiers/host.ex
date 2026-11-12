defmodule Xeito.Tiers.Host do
  @moduledoc """
  Decides whether a URL's host is this machine, which every `local*` tier's URL must be.

  A host is this machine when it is

    * a loopback address (`127.0.0.0/8`, `::1`) or name (`localhost`, `*.localhost`),
    * one of the machine's own interface addresses (`own_addresses/0`),
    * a name whose every address is one of those, or
    * listed in `:allowed` (`XEITO_LOCAL_HOSTS`, `allowed/1`): a container on this host,
      reached by its name or its bridge address.

  Anything else, a URL without a host and a name that does not resolve included, is not.
  `local?/2` takes `:allowed`, and for tests `:own` and `:resolve`.
  """

  @type address :: :inet.ip_address()

  @doc "Whether the host of `url` is this machine."
  @spec local?(String.t(), keyword()) :: boolean()
  def local?(url, opts \\ []) do
    case URI.parse(url).host do
      nil -> false
      host -> listed_or_here?(String.downcase(host), opts)
    end
  end

  defp listed_or_here?(host, opts) do
    host in Keyword.get(opts, :allowed, []) or
      here?(addresses(host, Keyword.get(opts, :resolve, &resolve/1)), Keyword.get_lazy(opts, :own, &own_addresses/0))
  end

  defp here?([], _own), do: false
  defp here?(addresses, own), do: Enum.all?(addresses, &(loopback?(&1) or &1 in own))

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false

  defp addresses(host, resolve) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> [address]
      {:error, _} -> named(host, resolve)
    end
  end

  defp named(host, resolve) do
    if host == "localhost" or String.ends_with?(host, ".localhost"), do: [{127, 0, 0, 1}], else: resolve.(host)
  end

  @doc "Every address `host` resolves to, IPv4 and IPv6; none for a name that does not resolve."
  @spec resolve(String.t(), (charlist(), :inet | :inet6 -> {:ok, [address()]} | {:error, term()})) :: [address()]
  def resolve(host, getaddrs \\ &:inet.getaddrs/2) do
    for family <- [:inet, :inet6], {:ok, found} <- [getaddrs.(String.to_charlist(host), family)], a <- found, do: a
  end

  @doc "The addresses of this machine's network interfaces."
  @spec own_addresses() :: [address()]
  def own_addresses do
    {:ok, interfaces} = :inet.getifaddrs()
    for {_name, opts} <- interfaces, {:addr, address} <- opts, do: address
  end

  @doc "The hosts a `XEITO_LOCAL_HOSTS` value lists: comma-separated names or addresses."
  @spec allowed(String.t() | nil) :: [String.t()]
  def allowed(nil), do: []

  def allowed(list),
    do: list |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.map(&String.downcase/1)
end
